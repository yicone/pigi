import Foundation
import PigiCore

// Configuration inspection; no credentials, keychain or network access.
struct Snapshot: Encodable {
    let gmail: [String]
    let imap: [String]
    let gmailClientID: String
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.isEmpty || (args.count == 2 && args[0] == "--database") else {
        throw NSError(domain: "usage", code: 1)
    }
    let config = AccountConfiguration(path: args.isEmpty ? nil : args[1])
    let snapshot = try Snapshot(gmail: config.emails(kind: "gmail"), imap: config.emails(kind: "imap"),
                                gmailClientID: config.gmailClientID())
    let data = try JSONEncoder().encode(snapshot)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    // Database errors may contain private values. Keep diagnostics fixed.
    FileHandle.standardError.write(Data("无法读取账号配置。用法: pigi-config [--database PATH]\n".utf8))
    exit(1)
}
