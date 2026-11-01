import Foundation

/// Local mail window: how far back mail is kept on this Mac, and the sync cursor into the engine.
enum ArchiveSettings {
    /// How far back mail is kept on this Mac.
    static var windowDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "archiveWindowDays")
            return stored > 0 ? stored : 30
        }
        set { UserDefaults.standard.set(max(newValue, 1), forKey: "archiveWindowDays") }
    }
    /// Last change number pulled, and the window it was pulled for.
    static var cursor: Int {
        get { UserDefaults.standard.integer(forKey: "archiveCursor") }
        set { UserDefaults.standard.set(newValue, forKey: "archiveCursor") }
    }
    static var cursorWindow: Int {
        get { UserDefaults.standard.integer(forKey: "archiveCursorWindow") }
        set { UserDefaults.standard.set(newValue, forKey: "archiveCursorWindow") }
    }
    /// Bumped when the archive items gain fields, so one full pull refreshes what is cached.
    static let schema = 3
    static var cursorSchema: Int {
        get { UserDefaults.standard.integer(forKey: "archiveCursorSchema") }
        set { UserDefaults.standard.set(newValue, forKey: "archiveCursorSchema") }
    }
    static var isConfigured: Bool { true }
}

struct ArchiveAccount: Identifiable {
    let email: String
    let backfillDone: Int
    let total: Int
    let lastSync: Int?
    let lastError: String?
    let stored: Int
    let kind: String?
    var id: String { email }
}

struct ArchiveItem {
    let account: String
    let id: String
    let date: Int
    let subject: String?
    let fromName: String?
    let fromEmail: String?
    let snippet: String?
    let unread: Int
    let starred: Int
    let status: String
    let seq: Int
    let code: String?
    let unsubKind: String?
    var labels: String? = nil

    var mail: Mail {
        let name = (fromName?.isEmpty == false ? fromName : fromEmail) ?? ""
        return Mail(
            id: "\(account)#\(id)",
            accountID: account,
            remoteID: id,
            senderName: name,
            senderEmail: fromEmail ?? "",
            subject: (subject?.isEmpty == false ? subject : nil) ?? "(无主题)",
            snippet: RemoteMapping.plainText(snippet ?? ""),
            body: "",
            date: Date(timeIntervalSince1970: Double(date) / 1000),
            isUnread: unread != 0,
            isStarred: starred != 0,
            bodyLoaded: false,
            isHTML: false,
            code: code,
            unsubKind: unsubKind,
            labels: labels.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        )
    }
}

struct ArchiveChanges {
    let items: [ArchiveItem]
    let next: Int
    let more: Bool
}

/// Front for the in-app mail engine; the rest of the app talks to this.
struct ArchiveClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Body {
        let html: String?
        let text: String
    }

    enum UnsubscribeResult {
        case done
        case manual(URL?)
    }

    private var engine: LocalEngine { .shared }

    func accounts() async throws -> [ArchiveAccount] { try await engine.accounts() }

    func changes(after: Int, since: Date) async throws -> ArchiveChanges {
        try await engine.changes(after: after, since: since, limit: 1000)
    }

    /// Registers the signed-in Gmail accounts with the engine so it starts syncing them.
    func ensureGmail(_ emails: [String] = GmailStore.emails) async {
        for email in emails { try? await engine.addGmail(email) }
    }

    func addIMAP(email: String, password: String, host: String, port: Int) async throws {
        try await engine.addIMAP(email: email, password: password, host: host, port: port)
    }

    func addProton(username: String, password: String, mailboxPassword: String, otp: String) async throws {
        try await engine.addProton(username: username, password: password, mailboxPassword: mailboxPassword, otp: otp)
    }
    func protonLabels(_ email: String) async throws -> [ProtonLabel] { try await engine.protonLabels(email) }

    func deleteAccount(_ email: String) async throws { try await engine.deleteAccount(email) }

    func body(account: String, id: String) async throws -> Body { try await engine.body(account: account, id: id) }

    func search(_ term: String, account: String?) async throws -> [ArchiveItem] { try await engine.search(term, account: account) }

    func modify(account: String, id: String, add: [String], remove: [String]) async throws {
        try await engine.modify(account: account, ids: [id], add: add, remove: remove)
    }

    func modify(account: String, ids: [String], add: [String], remove: [String]) async throws {
        try await engine.modify(account: account, ids: ids, add: add, remove: remove)
    }

    func unsubscribe(account: String, id: String) async throws -> UnsubscribeResult {
        try await engine.unsubscribe(account: account, id: id)
    }

    func mute(account: String, sender: String, id: String) async throws {
        try await engine.mute(account: account, sender: sender, id: id)
    }

    func trash(account: String, id: String) async throws {
        try await engine.modify(account: account, ids: [id], add: [], remove: [], trash: true)
    }

    /// Asks the engine to sync every mailbox right now.
    func poke() async throws { try await engine.poke() }

    /// Change numbers as the engine announces them; the first one arrives on subscribe.
    func events() -> AsyncThrowingStream<Int, Error> { engine.events() }

    /// How many days back each mailbox is synced (0 = everything).
    func backfillDays() async throws -> Int { await engine.backfillDays() }

    func setBackfillDays(_ days: Int) async throws { try await engine.setBackfillDays(days) }
}
