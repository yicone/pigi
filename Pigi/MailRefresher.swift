import Foundation
#if canImport(PigiCore)
import PigiCore
#endif

/// /poke only queues work. Watch the local engine account status while pulling changes,
/// so a refresh never reports success after merely reading the old archive.
@MainActor
struct MailRefresher {
    var accounts: () async throws -> [ArchiveAccount]
    var poke: () async throws -> Void
    var pull: () async throws -> Void
    var pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    var attempts = 30

    func run() async throws {
        let before = try await accounts()
        let baseline = Dictionary(before.map { ($0.id, $0.lastSync) }, uniquingKeysWith: { first, _ in first })
        var pending = Set(before.map(\.id))
        try await pull()
        // last_sync has second precision. Separate the request from the baseline
        // by one tick, otherwise a fast sync can finish with the same timestamp.
        try await pause()
        try await poke()
        var failures: [String: String] = [:]
        for _ in 0..<attempts {
            try Task.checkCancellation()
            try await pause()
            let latest = try await accounts()
            let existing = Set(latest.map(\.id))
            pending.formIntersection(existing)
            for account in latest where pending.contains(account.id) {
                if let error = account.lastError, !error.isEmpty {
                    failures[account.id] = error
                    pending.remove(account.id)
                } else if account.lastSync != nil, account.lastSync != (baseline[account.id] ?? nil) {
                    pending.remove(account.id)
                }
            }
            try await pull()
            if pending.isEmpty {
                if !failures.isEmpty {
                    throw ArchiveClient.Failure(message: failures.sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value)" }.joined(separator: "；"))
                }
                return
            }
        }
        throw ArchiveClient.Failure(message: "邮箱仍在同步,已获取当前归档。尚未完成:\(pending.sorted().joined(separator: "、"))")
    }
}
