import Foundation

/// Shared non-secret configuration in mail.db. Each operation opens its own
/// connection, so changes from another process are immediately visible.
/// IMAP connection settings remain in the engine-owned accounts table.
public struct AccountConfiguration {
    private let path: String?
    public init(path: String? = nil) { self.path = path }
    public static let shared = AccountConfiguration()

    private func open() throws -> Store {
        let location = try path ?? AppSupport.pigiDirectory().appendingPathComponent("mail.db").path
        if location != ":memory:" { try AppSupport.assertNotRealUserData(URL(fileURLWithPath: location)) }
        let store = try Store(path: location)
        // Use the same schema as the engine; never replace existing rows.
        for sql in LocalEngine.schema { try store.run(sql) }
        try store.run("CREATE TABLE IF NOT EXISTS account_config(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        return store
    }

    public func emails(kind: String) throws -> [String] {
        try open().query("SELECT email FROM accounts WHERE kind=? ORDER BY added_at,email", [.text(kind)])
            .compactMap { $0["email"]?.text }
    }

    public func gmailClientID() throws -> String {
        try open().query("SELECT value FROM account_config WHERE key='gmailClientID'").first?["value"]?.text ?? ""
    }

    public func setGmailClientID(_ value: String) throws {
        try open().run("INSERT INTO account_config VALUES('gmailClientID',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       [.text(value.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    /// Called by the app with its legacy preference domain, before starting sync.
    /// The marker commits with the import. Retrying cannot resurrect a deleted
    /// account or replace a newer client ID. Legacy values and secrets are untouched.
    public func migrateLegacy(defaults: UserDefaults) throws {
        let store = try open()
        try store.run("BEGIN IMMEDIATE")
        do {
            if try store.query("SELECT 1 FROM account_config WHERE key='legacy-v2'").isEmpty {
                let firstImport = try store.query("SELECT 1 FROM account_config WHERE key='legacy-v1'").isEmpty
                try GmailAccountMigration.run(store, legacy: defaults.stringArray(forKey: "gmailAccounts") ?? [], importLegacy: firstImport)
                if let client = defaults.string(forKey: "gmailClientID") {
                    try store.run("INSERT OR IGNORE INTO account_config VALUES('gmailClientID',?)",
                                  [.text(client.trimmingCharacters(in: .whitespacesAndNewlines))])
                }
                // imapAccounts was only a display cache: the authoritative rows,
                // including host/port, already live in this database.
                try store.run("INSERT OR IGNORE INTO account_config VALUES('legacy-v1','1')")
                try store.run("INSERT INTO account_config VALUES('legacy-v2','1')")
            }
            try store.run("COMMIT")
        } catch {
            _ = try? store.run("ROLLBACK")
            throw error
        }
    }

    static func credentialKeys(_ email: String, store: Store) throws -> [String] {
        let canonical = GmailAccountMigration.identity(email)
        let ids = try store.query("SELECT identifier FROM gmail_credential_aliases WHERE account=? ORDER BY priority,identifier", [.text(canonical)])
            .compactMap { $0["identifier"]?.text }
        var keys: [String] = []
        for id in ids + [email, canonical] {
            let key = GmailStore.keychainKey(id)
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    func refreshToken(for email: String, credentials: CredentialStore) throws -> String {
        for key in try Self.credentialKeys(email, store: open()) {
            do { if let token = try credentials.read(key), !token.isEmpty { return token } }
            catch { throw CredentialPersistenceError.readFailed }
        }
        throw CredentialPersistenceError.readFailed
    }

    func replaceRefreshToken(_ token: String, for email: String, credentials: CredentialStore) throws {
        let keys = try Self.credentialKeys(email, store: open())
        for key in keys {
            let old: String?
            do { old = try credentials.read(key) }
            catch { throw CredentialPersistenceError.readFailed }
            if let old, !old.isEmpty { try credentials.save(key, token); return }
        }
        try credentials.save(keys[0], token)
    }

    func removeCredentials(for email: String, credentials: CredentialStore) throws {
        for key in try Self.credentialKeys(email, store: open()) { try credentials.remove(key) }
    }

    func addGmail(_ email: String, refreshToken: String, credentials: CredentialStore) throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { throw SQLError(message: "邮箱不能为空") }
        let store = try open()
        // Hold the write transaction across the credential operation. On SQLite
        // failure restore the previous credential, just as Proton installation does.
        let keys = try Self.credentialKeys(email, store: store)
        try store.run("BEGIN IMMEDIATE")
        var selected = keys[0]
        var previous: String?
        var saved = false
        do {
            if let row = try store.query("SELECT kind FROM accounts WHERE email=?", [.text(email)]).first,
               row["kind"]?.text != "gmail" { throw SQLError(message: "这个邮箱已使用其他连接方式") }
            do {
                for key in keys {
                    if let old = try credentials.read(key), !old.isEmpty { selected = key; previous = old; break }
                }
            }
            catch { throw CredentialPersistenceError.readFailed }
            try credentials.save(selected, refreshToken)
            saved = true
            try store.run("INSERT OR IGNORE INTO accounts(email,added_at,kind) VALUES(?,?,'gmail')",
                          [.text(email), .int(Int(Date().timeIntervalSince1970))])
            try store.run("COMMIT")
        } catch {
            _ = try? store.run("ROLLBACK")
            if saved {
                do { try credentials.save(selected, previous ?? "") }
                catch { throw CredentialPersistenceError.recoveryFailed }
            }
            throw error
        }
    }
}
