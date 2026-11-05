import Foundation

public struct ArchiveAccount: Identifiable {
    public let email: String
    public let backfillDone: Int
    public let total: Int
    public let lastSync: Int?
    public let lastError: String?
    public let stored: Int
    public let kind: String?
    public var id: String { email }

    public init(email: String, backfillDone: Int, total: Int, lastSync: Int?, lastError: String?, stored: Int, kind: String?) {
        self.email = email
        self.backfillDone = backfillDone
        self.total = total
        self.lastSync = lastSync
        self.lastError = lastError
        self.stored = stored
        self.kind = kind
    }
}

public struct ArchiveItem {
    public let account: String
    public let id: String
    public let date: Int
    public let subject: String?
    public let fromName: String?
    public let fromEmail: String?
    public let snippet: String?
    public let unread: Int
    public let starred: Int
    public let status: String
    public let seq: Int
    public let code: String?
    public let unsubKind: String?
    public let labels: String?

    public init(account: String, id: String, date: Int, subject: String?, fromName: String?, fromEmail: String?, snippet: String?, unread: Int, starred: Int, status: String, seq: Int, code: String?, unsubKind: String?, labels: String? = nil) {
        self.account = account
        self.id = id
        self.date = date
        self.subject = subject
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.snippet = snippet
        self.unread = unread
        self.starred = starred
        self.status = status
        self.seq = seq
        self.code = code
        self.unsubKind = unsubKind
        self.labels = labels
    }
}

public struct ArchiveChanges {
    public let items: [ArchiveItem]
    public let next: Int
    public let more: Bool

    public init(items: [ArchiveItem], next: Int, more: Bool) {
        self.items = items
        self.next = next
        self.more = more
    }
}

/// Front for the in-app mail engine; the rest of the app talks to this.
public struct ArchiveClient {
    public struct Failure: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Body {
        public let html: String?
        public let text: String
        public let signatureStatus: String?
        public init(html: String?, text: String, signatureStatus: String? = nil) {
            self.signatureStatus = signatureStatus
            self.html = html
            self.text = text
        }
    }

    public enum UnsubscribeResult {
        case done
        case manual(URL?)
    }

    private var engine: LocalEngine { .shared }

    public init() {}

    public func accounts() async throws -> [ArchiveAccount] { try await engine.accounts() }

    public func changes(after: Int, since: Date) async throws -> ArchiveChanges {
        try await engine.changes(after: after, since: since, limit: 1000)
    }

    /// Registers the signed-in Gmail accounts with the engine so it starts syncing them.
    public func ensureGmail(_ emails: [String] = GmailStore.emails) async {
        for email in emails { try? await engine.addGmail(email) }
    }

    public func addIMAP(email: String, password: String, host: String, port: Int) async throws {
        try await engine.addIMAP(email: email, password: password, host: host, port: port)
    }

    /// Verifies a new IMAP password against the server, then replaces the stored one.
    public func updateIMAPPassword(email: String, password: String) async throws {
        try await engine.updateIMAPPassword(email: email, password: password)
    }

    /// Drops the cached Gmail session so the next sync re-reads the refresh token.
    public func resetGmailSession(_ email: String) async {
        await engine.resetGmailSession(email)
    }

    public func addProton(username: String, password: String, mailboxPassword: String, otp: String, interaction: ProtonLoginInteraction? = nil) async throws {
        try await engine.addProton(username: username, password: password, mailboxPassword: mailboxPassword, otp: otp, interaction: interaction)
    }

    public func protonLabels(_ email: String) async throws -> [ProtonLabel] {
        try await engine.protonLabels(email)
    }

    public func deleteAccount(_ email: String) async throws { try await engine.deleteAccount(email) }

    public func body(account: String, id: String) async throws -> Body { try await engine.body(account: account, id: id) }

    /// Translate an original stored mail for reading; never modifies mail.db or agent.sock results.
    public func translateMail(account: String, id: String) async throws -> CachedTranslation {
        try await engine.translateMail(account: account, id: id)
    }

    public func search(_ term: String, account: String?) async throws -> [ArchiveItem] { try await engine.search(term, account: account) }

    public func modify(account: String, id: String, add: [String], remove: [String]) async throws {
        try await engine.modify(account: account, ids: [id], add: add, remove: remove)
    }

    public func modify(account: String, ids: [String], add: [String], remove: [String]) async throws {
        try await engine.modify(account: account, ids: ids, add: add, remove: remove)
    }

    public func unsubscribe(account: String, id: String) async throws -> UnsubscribeResult {
        try await engine.unsubscribe(account: account, id: id)
    }

    public func mute(account: String, sender: String, id: String) async throws {
        try await engine.mute(account: account, sender: sender, id: id)
    }

    public func trash(account: String, id: String) async throws {
        try await engine.modify(account: account, ids: [id], add: [], remove: [], trash: true)
    }

    /// Asks the engine to sync every mailbox right now.
    public func poke() async throws { try await engine.poke() }

    /// Change numbers as the engine announces them; the first one arrives on subscribe.
    public func events() -> AsyncThrowingStream<Int, Error> { engine.events() }

    /// How many days back each mailbox is synced (0 = everything).
    public func backfillDays() async throws -> Int { await engine.backfillDays() }

    public func setBackfillDays(_ days: Int) async throws { try await engine.setBackfillDays(days) }
}
