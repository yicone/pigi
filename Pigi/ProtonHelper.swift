import Foundation
import Darwin

/// Stable wire codes only; no API error messages, credentials or mail content.
enum ProtonHelperError: String, Error, Codable {
    case invalidRequest = "invalid_request"
    case invalidParams = "invalid_params"
    case unsupportedVersion = "unsupported_version"
    case handshakeRequired = "handshake_required"
    case frameTooLarge = "frame_too_large"
    case unknownMethod = "unknown_method"
    case network, timeout, credentials, key, upstream
    case humanVerificationRequired = "human_verification_required"
    case secondFactorRequired = "second_factor_required"
    case rateLimited = "rate_limited"
    case notAuthenticated = "not_authenticated"
    case alreadyAuthenticated = "already_authenticated"
    case cleanupFailed = "cleanup_failed"
    case unavailable, transport, protocolViolation = "protocol_violation"
}

struct ProtonHelperInfo: Decodable, Sendable {
    let `protocol`: Int
    let helperVersion: String
    let maxFrameBytes: Int
    let methods: [String]
    enum CodingKeys: String, CodingKey {
        case `protocol`, methods
        case helperVersion = "helper_version", maxFrameBytes = "max_frame_bytes"
    }
}

struct ProtonMessageMetadata: Decodable, Sendable {
    let id: String
    let subject: String
    let time: Int64
    let unread: Bool
}

struct ProtonMessageBody: Decodable, Sendable {
    let body: String
    let mimeType: String
    enum CodingKeys: String, CodingKey { case body; case mimeType = "mime_type" }
}

/// Each instance owns one account session in a private child. Blocking pipe IO
/// runs on a dedicated queue, never the UI or Swift cooperative executor.
final class ProtonHelperClient: @unchecked Sendable {
    static let maxFrame = 8 * 1024 * 1024
    private let queue = DispatchQueue(label: "one.yic.pigi.proton-helper")
    private let executable: URL
    private let timeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var nextID: UInt64 = 0
    private var info: ProtonHelperInfo?

    init(executable: URL, timeout: TimeInterval = 75) {
        self.executable = executable
        self.timeout = timeout
    }

    static func bundled(in bundle: Bundle = .main) throws -> ProtonHelperClient {
        guard let root = bundle.executableURL?.deletingLastPathComponent().deletingLastPathComponent() else {
            throw ProtonHelperError.unavailable
        }
        let path = root.appendingPathComponent("Helpers/pigi-proton-helper")
        guard FileManager.default.isExecutableFile(atPath: path.path) else { throw ProtonHelperError.unavailable }
        return ProtonHelperClient(executable: path)
    }

    func negotiate() async throws -> ProtonHelperInfo {
        try await perform { try self.start() }
    }

    func login(username: String, password: String, mailboxPassword: String = "", otp: String = "") async throws {
        struct Params: Encodable {
            let username: String; let password: String; let mailbox_password: String; let otp: String
        }
        struct Result: Decodable { let authenticated: Bool }
        let result: Result = try await perform {
            _ = try self.start()
            return try self.exchange("login", Params(username: username, password: password, mailbox_password: mailboxPassword, otp: otp))
        }
        guard result.authenticated else { throw ProtonHelperError.protocolViolation }
    }

    func list(page: Int = 0, limit: Int = 50) async throws -> [ProtonMessageMetadata] {
        struct Params: Encodable { let page: Int; let limit: Int }
        return try await perform {
            _ = try self.start()
            return try self.exchange("list", Params(page: page, limit: limit))
        }
    }

    func decrypt(id: String) async throws -> ProtonMessageBody {
        struct Params: Encodable { let id: String }
        return try await perform {
            _ = try self.start()
            return try self.exchange("decrypt", Params(id: id))
        }
    }

    func logout() async throws {
        struct Result: Decodable { let logged_out: Bool }
        try await perform {
            guard self.process != nil else { return }
            let result: Result = try self.exchange("logout", Empty())
            guard result.logged_out else { throw ProtonHelperError.protocolViolation }
            self.stop()
        }
    }

    private struct Empty: Encodable {}
    private struct Request<P: Encodable>: Encodable {
        let version = 1
        let id: UInt64
        let method: String
        let params: P
    }
    private struct Response<R: Decodable>: Decodable {
        struct Fault: Decodable { let code: String }
        let version: Int
        let id: UInt64
        let result: R?
        let error: Fault?
    }

    private func perform<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch let error as ProtonHelperError { continuation.resume(throwing: error) }
                catch { continuation.resume(throwing: ProtonHelperError.transport) }
            }
        }
    }

    private func start() throws -> ProtonHelperInfo {
        if let info, process?.isRunning == true { return info }
        stop()
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = []
        child.environment = [:]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw ProtonHelperError.unavailable }
        // Parent must release its copies of the child's ends so EOF is visible.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // A child that exits between frames must throw, never signal the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let hello: ProtonHelperInfo = try exchange("hello", Empty())
        guard hello.protocol == 1, hello.maxFrameBytes == Self.maxFrame,
              Set(["login", "list", "decrypt", "logout"]).isSubset(of: Set(hello.methods)) else {
            stop(); throw ProtonHelperError.protocolViolation
        }
        info = hello
        return hello
    }

    private func exchange<P: Encodable, R: Decodable>(_ method: String, _ params: P) throws -> R {
        guard let process, let input, let output else { throw ProtonHelperError.unavailable }
        nextID += 1
        let id = nextID
        var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count <= Self.maxFrame else { throw ProtonHelperError.frameTooLarge }
        data.append(10)
        // A per-call watchdog terminates only this child; EOF unblocks read/write.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let began = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try input.write(contentsOf: data)
            var complete = false
            while !complete {
                // FileHandle.read(upToCount:) can wait to fill its requested
                // length on a pipe. POSIX read returns each available fragment.
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw Date().timeIntervalSince(began) >= timeout ? ProtonHelperError.timeout : ProtonHelperError.transport
                }
                pending.append(contentsOf: bytes.prefix(count))
                complete = bytes.prefix(count).contains(10)
                _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                guard pending.count <= Self.maxFrame + 1 else { throw ProtonHelperError.frameTooLarge }
            }
            guard let end = pending.firstIndex(of: 10) else { throw ProtonHelperError.protocolViolation }
            guard end == pending.index(before: pending.endIndex) else { throw ProtonHelperError.protocolViolation }
            var frame = Data(pending[..<end])
            pending.resetBytes(in: 0..<pending.count)
            pending.removeAll(keepingCapacity: false)
            defer { frame.resetBytes(in: 0..<frame.count) }
            let response = try JSONDecoder().decode(Response<R>.self, from: frame)
            guard response.version == 1, response.id == id,
                  (response.result != nil) != (response.error != nil) else { throw ProtonHelperError.protocolViolation }
            if let fault = response.error {
                guard let code = ProtonHelperError(rawValue: fault.code) else { throw ProtonHelperError.protocolViolation }
                throw code
            }
            guard let result = response.result else { throw ProtonHelperError.protocolViolation }
            return result
        } catch {
            // Any transport/protocol failure invalidates this session. Known
            // operation faults leave it usable (e.g. logout can retry cleanup).
            if let code = error as? ProtonHelperError,
               ![.transport, .timeout, .protocolViolation, .frameTooLarge].contains(code) { throw code }
            stop()
            throw (error as? ProtonHelperError) ?? ProtonHelperError.protocolViolation
        }
    }

    private func stop() {
        try? input?.close()
        try? output?.close()
        input = nil; output = nil; info = nil
        pending.resetBytes(in: 0..<pending.count)
        pending.removeAll(keepingCapacity: false)
        // EOF lets the helper revoke its session; it exits after bounded cleanup.
        if let child = process {
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                if child.isRunning { child.terminate() }
            }
        }
        process = nil
    }

    deinit { stop() }
}
