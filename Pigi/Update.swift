import AppKit
import CryptoKit
import Foundation

/// What this build is, for the About page and the update check.
enum AppVersion {
    static var marketing: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var display: String { "\(marketing) (\(String(build)))" }
}

struct UpdateInfo: Decodable, Equatable {
    let version: String
    let build: Int
    let notes: String
    let size: Int
    let sha256: String
    let date: String?
    /// File name of the zip next to latest.json; versioned so old releases stay downloadable.
    let file: String?
}

/// Checks an optional download host for a newer build. This fork leaves the host unset, so checks and installs never contact a server.
@Observable @MainActor
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading
        case installing
        case failed(String)
        /// No update host is configured, so nothing is checked or downloaded.
        case disabled
    }

    private(set) var phase: Phase = Updater.downloadHost == nil ? .disabled : .idle
    private(set) var lastChecked: Date?

    var available: UpdateInfo? { if case .available(let info) = phase { return info } else { return nil } }
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// `nil` closes online updates. Set a host owned by this fork to turn them back on.
    static let downloadHost: String? = nil

    private func request(_ path: String) throws -> URLRequest {
        guard let host = Self.downloadHost, let url = URL(string: host + path) else { throw UpdateError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        return request
    }

    func check() async {
        guard !isBusy else { return }
        guard Self.downloadHost != nil else {
            phase = .disabled
            return
        }
        phase = .checking
        do {
            let (data, response) = try await URLSession.shared.data(for: request("/latest.json"))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { phase = .upToDate; lastChecked = .now; return }
            guard status == 200 else { throw UpdateError.message("服务器返回 \(status)") }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            lastChecked = .now
            phase = info.build > AppVersion.build ? .available(info) : .upToDate
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func install() async {
        guard Self.downloadHost != nil else {
            phase = .disabled
            return
        }
        guard let info = available else { return }
        do {
            phase = .downloading
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("pigi-update-\(info.build)")
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("pigi.zip")

            let (downloaded, response) = try await URLSession.shared.download(for: request("/" + (info.file ?? "pigi.zip")))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("下载失败") }
            try FileManager.default.moveItem(at: downloaded, to: zip)
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == info.sha256 else { throw UpdateError.message("安装包校验失败,请重试") }

            phase = .installing
            let staged = work.appendingPathComponent("staged")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path])
            let app = staged.appendingPathComponent("pigi.app")
            guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.message("安装包里没有 pigi.app") }
            try Self.relaunch(into: app, work: work)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// A helper shell waits for this process to exit, swaps the bundle and opens the new one.
    private static func relaunch(into staged: URL, work: URL) throws {
        let target = Bundle.main.bundleURL
        let script = work.appendingPathComponent("swap.sh")
        let text = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target.path).old"
        mv "\(target.path)" "\(target.path).old" || exit 1
        if ditto "\(staged.path)" "\(target.path)"; then
          xattr -cr "\(target.path)"
          rm -rf "\(target.path).old"
        else
          rm -rf "\(target.path)"; mv "\(target.path).old" "\(target.path)"
        fi
        open "\(target.path)"
        rm -rf "\(work.path)"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        NSApp.terminate(nil)
        // An open sheet can hold termination back; the helper is already waiting for us to go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: UpdateError.message("解压安装包失败")) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.notConfigured: "更新地址无效"
        case UpdateError.message(let text): text
        case is URLError: "无法连接更新服务器"
        default: error.localizedDescription
        }
    }
}

private enum UpdateError: Error {
    case notConfigured
    case message(String)
}
