import CryptoKit
import Foundation

extension TranslationCacheKey {
    /// Fold editable generation settings into the prompt version. A provider, prompt or
    /// temperature edit must not reuse results from the previous configuration.
    public static func promptFingerprint(version: Int, systemPrompt: String, temperature: Double?, endpoint: String) -> Int {
        let fields = [String(version), systemPrompt, temperature.map(String.init(describing:)) ?? "",
                      endpoint.trimmingCharacters(in: .whitespacesAndNewlines)]
        let hash = digest((try? JSONEncoder().encode(fields)) ?? Data())
        return Int(UInt64(hash.prefix(15), radix: 16) ?? 0)
    }
    /// Include the subject and rendering mode: either changing must invalidate the whole translation.
    public static func sourceHash(subject: String, body: String, isHTML: Bool) -> String {
        digest((try? JSONEncoder().encode([subject, body, isHTML ? "html" : "text"])) ?? Data())
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate var arguments: [SQLValue] {
        [.text(accountID.lowercased()), .text(mailID), .text(bodyHash), .text(model), .int(promptVersion), .text(targetLanguage)]
    }
}

/// Only validated display data belongs here. Neither mail.db nor agent.sock uses this type.
public struct CachedTranslation: Codable, Equatable, Sendable {
    public let subject: String
    public let body: String
    public init(subject: String, body: String) { self.subject = subject; self.body = body }
}

public actor SQLiteTranslationCache: TranslationCache {
    public static let shared = SQLiteTranslationCache()

    /// A request must obtain a ticket before starting work. Clear/purge invalidates outstanding tickets.
    public struct Ticket: Sendable {
        fileprivate let owner: UUID
        fileprivate let key: TranslationCacheKey
        fileprivate let generation: UUID
        fileprivate let accountGeneration: UUID
    }

    public enum Failure: Error { case invalidated, invalidResult }
    private let path: String?
    private var store: Store?
    private let owner = UUID()
    private var generation = UUID()
    private var accountGenerations: [String: UUID] = [:]

    /// nil uses Application Support/pigi/translations.db. Tests pass an isolated path.
    /// With no path, regression binaries and XCTest refuse the real user directory.
    public init(path: String? = nil) { self.path = path }

    private func db() throws -> Store {
        if let store { return store }
        let resolved: String
        if let path { resolved = path } else {
            resolved = try AppSupport.pigiDirectory().appendingPathComponent("translations.db").path
        }
        let opened = try Store(path: resolved)
        try opened.run("""
            CREATE TABLE IF NOT EXISTS translations(
              account TEXT NOT NULL, mail_id TEXT NOT NULL, body_hash TEXT NOT NULL,
              model TEXT NOT NULL, prompt_version TEXT NOT NULL, language TEXT NOT NULL,
              value BLOB NOT NULL,
              PRIMARY KEY(account,mail_id,body_hash,model,prompt_version,language))
            """)
        store = opened
        return opened
    }

    private static let match = "account=? AND mail_id=? AND body_hash=? AND model=? AND prompt_version=? AND language=?"

    public func get(_ key: TranslationCacheKey) throws -> CachedTranslation? {
        try Task.checkCancellation()
        guard let data = try db().query("SELECT value FROM translations WHERE \(Self.match)", key.arguments).first?["value"]?.blob else { return nil }
        // A corrupt entry is a miss, never a partial translation.
        return try? JSONDecoder().decode(CachedTranslation.self, from: data)
    }

    public func begin(_ key: TranslationCacheKey) throws -> Ticket {
        try Task.checkCancellation()
        let accountGeneration = accountGenerations[key.accountID.lowercased()] ?? UUID()
        accountGenerations[key.accountID.lowercased()] = accountGeneration
        return Ticket(owner: owner, key: key, generation: generation, accountGeneration: accountGeneration)
    }

    /// Call only after *all* chunks passed count/id validation. No incremental cache writes.
    public func put(_ value: CachedTranslation, for ticket: Ticket, validated: Bool) throws {
        try Task.checkCancellation()
        guard validated else { throw Failure.invalidResult }
        guard ticket.owner == owner, ticket.generation == generation,
              ticket.accountGeneration == accountGenerations[ticket.key.accountID.lowercased()] else { throw Failure.invalidated }
        let s = try db()
        let data = try JSONEncoder().encode(value)
        try s.transaction {
            try Task.checkCancellation()
            // Keep one source revision per mail; model/prompt/language variants remain separately keyed.
            try s.run("DELETE FROM translations WHERE account=? AND mail_id=? AND body_hash!=?",
                [.text(ticket.key.accountID.lowercased()), .text(ticket.key.mailID), .text(ticket.key.bodyHash)])
            try s.run("INSERT OR REPLACE INTO translations VALUES(?,?,?,?,?,?,?)", ticket.key.arguments + [.blob(data)])
            try Task.checkCancellation()
        }
    }

    public func clear() throws {
        generation = UUID()
        try db().run("DELETE FROM translations")
        try db().run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func purge(accountID: String) throws {
        let account = accountID.lowercased()
        accountGenerations[account] = UUID()
        try db().run("DELETE FROM translations WHERE account=?", [.text(account)])
        try db().run("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
