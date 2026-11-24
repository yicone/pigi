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
            if try store.query("SELECT 1 FROM account_config WHERE key='legacy-v1'").isEmpty {
                for email in defaults.stringArray(forKey: "gmailAccounts") ?? [] {
                    try Self.insertGmail(email, store: store)
                }
                if let client = defaults.string(forKey: "gmailClientID") {
                    try store.run("INSERT OR IGNORE INTO account_config VALUES('gmailClientID',?)",
                                  [.text(client.trimmingCharacters(in: .whitespacesAndNewlines))])
                }
                // imapAccounts was only a display cache: the authoritative rows,
                // including host/port, already live in this database.
                try store.run("INSERT INTO account_config VALUES('legacy-v1','1')")
            }
            try store.run("COMMIT")
        } catch {
            _ = try? store.run("ROLLBACK")
            throw error
        }
    }

    private static func insertGmail(_ email: String, store: Store) throws {
        // Legacy identifiers are also credential lookup keys. Preserve them
        // verbatim; new registrations are normalized before reaching this helper.
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try store.run("INSERT OR IGNORE INTO accounts(email,added_at,kind) VALUES(?,?,'gmail')",
                      [.text(email), .int(Int(Date().timeIntervalSince1970))])
    }

    func addGmail(_ email: String, refreshToken: String, credentials: CredentialStore) throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { throw SQLError(message: "邮箱不能为空") }
        let store = try open()
        // Hold the write transaction across the credential operation. On SQLite
        // failure restore the previous credential, just as Proton installation does.
        try store.run("BEGIN IMMEDIATE")
        var previous: String?
        var saved = false
        do {
            if let row = try store.query("SELECT kind FROM accounts WHERE email=?", [.text(email)]).first,
               row["kind"]?.text != "gmail" { throw SQLError(message: "这个邮箱已使用其他连接方式") }
            do { previous = try credentials.read(GmailStore.keychainKey(email)) }
            catch { throw CredentialPersistenceError.readFailed }
            try credentials.save(GmailStore.keychainKey(email), refreshToken)
            saved = true
            try Self.insertGmail(email, store: store)
            try store.run("COMMIT")
        } catch {
            _ = try? store.run("ROLLBACK")
            if saved {
                do { try credentials.save(GmailStore.keychainKey(email), previous ?? "") }
                catch { throw CredentialPersistenceError.recoveryFailed }
            }
            throw error
        }
    }
}

