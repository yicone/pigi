import Foundation
import Network

struct ImapError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One untagged server line; literals ({n} blocks) are pulled out and kept in order.
struct ImapResponse {
    var line: String
    var literals: [Data]
}

/// A minimal IMAP4rev1 client over TLS: tagged commands, literals, no pipelining.
final class ImapConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var tagNumber = 0
    private(set) var capabilities: Set<String> = []

    init(host: String, port: Int) {
        var parameters = NWParameters.tls
        #if DEBUG
        // Test servers use self-signed certificates; only debug builds started with PIGI_INSECURE_TLS=1 accept them.
        if ProcessInfo.processInfo.environment["PIGI_INSECURE_TLS"] == "1" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
            parameters = NWParameters(tls: tls)
        }
        #endif
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 993, using: parameters)
    }

    // MARK: transport

    func open() async throws {
        try await withTimeout(25, onTimeout: { [connection] in connection.cancel() }) { [connection] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                connection.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; cont.resume()
                    case .failed(let e): resumed = true; cont.resume(throwing: ImapError(message: "连接失败:\(e.localizedDescription)"))
                    case .waiting(let e): resumed = true; connection.cancel(); cont.resume(throwing: ImapError(message: "无法连接服务器:\(e.localizedDescription)"))
                    case .cancelled: resumed = true; cont.resume(throwing: ImapError(message: "连接已取消"))
                    default: break
                    }
                }
                connection.start(queue: .global())
            }
        }
        _ = try await readLine()  // greeting
    }

    func close() {
        connection.cancel()
    }

    private func fill() async throws {
        let chunk: Data = try await withTimeout(60, onTimeout: { [connection] in connection.cancel() }) { [connection] in
            try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error { cont.resume(throwing: ImapError(message: "读取失败:\(error.localizedDescription)")) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if isComplete { cont.resume(throwing: ImapError(message: "服务器关闭了连接")) }
                    else { cont.resume(returning: Data()) }
                }
            }
        }
        buffer.append(chunk)
    }

    private func readLine() async throws -> String {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                var line = buffer[buffer.startIndex..<end]
                buffer = Data(buffer[(end + 1)...])
                if line.last == 13 { line = line.dropLast() }
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }

    private func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: ImapError(message: "发送失败:\(error.localizedDescription)")) }
                else { cont.resume() }
            })
        }
    }

    // MARK: commands

    /// Runs one command and returns its untagged responses. Throws unless the server says OK.
    @discardableResult
    func command(_ text: String, allowNO: Bool = false) async throws -> [ImapResponse] {
        tagNumber += 1
        let tag = "A\(tagNumber)"
        try await send("\(tag) \(text)")
        var responses: [ImapResponse] = []
        while true {
            var line = try await readLine()
            if line.hasPrefix("\(tag) ") {
                let status = line.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") { return responses }
                if allowNO && status.uppercased().hasPrefix("NO") { return responses }
                throw ImapError(message: String(status.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)))
            }
            var literals: [Data] = []
            while let open = line.range(of: #"\{(\d+)\}$"#, options: .regularExpression) {
                let size = Int(line[open].dropFirst().dropLast()) ?? 0
                literals.append(try await readBytes(size))
                line = String(line[..<open.lowerBound]) + "<literal>" + (try await readLine())
            }
            responses.append(ImapResponse(line: line, literals: literals))
        }
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func login(user: String, password: String) async throws {
        do {
            try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        } catch let error as ImapError {
            throw ImapError(message: "登录失败:\(error.message)")
        }
        let caps = try await command("CAPABILITY")
        capabilities = Set(caps.flatMap { $0.line.uppercased().split(separator: " ").map(String.init) })
        // NetEase/Coremail requires client identification before mailbox commands.
        // Keep it here so probes, sync and flag changes all identify each new session.
        if capabilities.contains("ID") {
            try await identify()
        }
    }

    private func identify() async throws {
        // Release builds set this from VERSION via release.sh. Standalone tools
        // have no app bundle version; do not claim a fabricated version for them.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let fields = ["name", "pigi", "version", version, "vendor", "pigi"]
        try await command("ID (\(fields.map(Self.quote).joined(separator: " ")))")
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        close()
    }

    /// Selects a folder and returns its UIDVALIDITY.
    func select(_ folder: String) async throws -> String {
        let replies = try await command("SELECT \(Self.quote(folder))")
        for reply in replies {
            if let r = reply.line.range(of: #"UIDVALIDITY (\d+)"#, options: .regularExpression) {
                return String(reply.line[r].dropFirst("UIDVALIDITY ".count))
            }
        }
        return ""
    }

    func search(_ criteria: String) async throws -> [Int] {
        let replies = try await command("UID SEARCH \(criteria)")
        return replies.filter { $0.line.hasPrefix("* SEARCH") }
            .flatMap { $0.line.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) } }
    }

    struct Fetched {
        var uid: Int
        var flags: Set<String>
        var internalDate: Date?
        var raw: Data?
    }

    func fetch(_ uids: [Int], items: String) async throws -> [Fetched] {
        guard !uids.isEmpty else { return [] }
        let replies = try await command("UID FETCH \(uids.map(String.init).joined(separator: ",")) (\(items))")
        return replies.compactMap { reply in
            guard let uidRange = reply.line.range(of: #"UID (\d+)"#, options: .regularExpression),
                  let uid = Int(reply.line[uidRange].dropFirst(4)) else { return nil }
            var flags: Set<String> = []
            if let r = reply.line.range(of: #"FLAGS \(([^)]*)\)"#, options: .regularExpression) {
                let inner = reply.line[r].dropFirst(7).dropLast()
                flags = Set(inner.split(separator: " ").map { $0.lowercased() })
            }
            var date: Date?
            if let r = reply.line.range(of: #"INTERNALDATE "([^"]+)""#, options: .regularExpression) {
                let text = String(reply.line[r].dropFirst(14).dropLast())
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
                date = f.date(from: text.trimmingCharacters(in: .whitespaces))
            }
            return Fetched(uid: uid, flags: flags, internalDate: date, raw: reply.literals.first)
        }
    }

    struct Folder {
        var attributes: Set<String>
        var name: String
    }

    func folders() async throws -> [Folder] {
        let replies = try await command("LIST \"\" \"*\"")
        return replies.compactMap { reply in
            guard reply.line.hasPrefix("* LIST"),
                  let m = try? NSRegularExpression(pattern: #"\(([^)]*)\)\s+(?:"[^"]*"|NIL)\s+(.+)$"#)
                    .firstMatch(in: reply.line, range: NSRange(location: 0, length: reply.line.utf16.count)) else { return nil }
            let ns = reply.line as NSString
            var name = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            let attrs = Set(ns.substring(with: m.range(at: 1)).lowercased().split(separator: " ").map(String.init))
            return Folder(attributes: attrs, name: name)
        }
    }
}

/// Runs an async body, failing with a timeout error if it takes too long.
func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: @escaping @Sendable () -> Void = {}, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            onTimeout()
            throw ImapError(message: "连接超时")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
