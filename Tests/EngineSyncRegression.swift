import Foundation
import Synchronization

// Never access the user's login keychain in this executable.
enum Keychain {
    static let writes = Mutex<[String: String]>([:])
    static func warm() {}
    static func get(_ key: String) -> String? { nil }
    @discardableResult static func set(_ key: String, _ value: String) -> Bool {
        writes.withLock { $0[key] = value }
        return true
    }
    static func translationAPIKey() throws -> String? { nil }
    @discardableResult static func setTranslationAPIKey(_ value: String) -> Bool { true }
}

extension LocalEngine {
    func prepare(_ email: String, kind: String, port: Int) throws {
        store = try Store(path: ":memory:")
        for sql in Self.schema { try db().run(sql) }
        try db().run("INSERT INTO meta VALUES('backfill_days',0)")
        try db().run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES(?,?,?,?)",
                     [.text(email), .text(kind), .text("127.0.0.1"), .int(port)])
    }
    func rows(_ sql: String) throws -> [SQLRow] { try db().query(sql) }
    func install(_ session: GmailSession, email: String) { sessions[email] = session }
}

actor GmailFixture {
    var round = 0
    var requests: [String] = []
    let root: URL
    init(_ root: URL) { self.root = root }
    func advance() { round += 1 }
    func call(_ path: String, _ query: [(String, String)]) throws -> Data {
        requests.append(path)
        let q = Dictionary(uniqueKeysWithValues: query)
        let file: String
        switch path {
        case "profile": file = "profile"
        case "messages":
            precondition(round == 0, "Incremental sync must not backfill")
            file = "list"
        case "history":
            if round == 2 {
                precondition(q["startHistoryId"] == "12")
                file = "history-delete"
            } else {
                precondition(q["startHistoryId"] == "10")
                file = q["pageToken"] == nil ? "history-1" : "history-2"
            }
        case "messages/one": file = q["format"] == "minimal" ? "labels" : "message"
        case "messages/two": file = "message-two"
        default: throw NSError(domain: "Unexpected fixture request", code: 1)
        }
        return try Data(contentsOf: root.appendingPathComponent(file + ".json"))
    }
}

@main struct EngineSyncRegression {
    static func main() async throws {
        let port = Int(CommandLine.arguments[1])!
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let email = "fixture@example.test"
        let imap = LocalEngine()
        try await imap.prepare(email, kind: "imap", port: port)
        for phase in 0..<4 {
            let delay = await imap.syncIMAP(email)
            precondition(delay == 60, "IMAP sync failed")
            let rows = try await imap.rows("SELECT * FROM messages ORDER BY id")
            if phase == 0 {
                precondition(rows.count == 1 && rows[0]["subject"]?.text == "First")
                precondition(rows[0]["unread"]?.int == 1)
            } else if phase == 1 {
                precondition(rows.count == 2 && rows[0]["unread"]?.int == 0)
                precondition(rows[1]["subject"]?.text == "Second")
            } else if phase == 2 {
                precondition(rows.count == 2)
                precondition(rows[0]["subject"]?.text == "Replacement", "UID reuse must replace cached MIME")
                precondition(rows[1]["status"]?.text == "deleted")
                let cursor = try await imap.rows("SELECT history_id FROM accounts")
                precondition(cursor[0]["history_id"]?.text == "200")
            }
            if phase == 3 {
                precondition(rows.count == 2 && rows[1]["status"]?.text == "inbox")
                precondition(rows[1]["subject"]?.text == "Second", "Tombstones must not suppress later backfill")
            }
            let attachments = try await imap.rows("SELECT filename FROM attachments WHERE msg_id='1'")
            precondition(attachments.first?["filename"]?.text == "note.txt")
        }
        print("PASS: IMAP initial, incremental flags/new UID, UIDVALIDITY reuse and MIME attachment")

        // Rotating the password verifies the login against the fixture, then stores it;
        // the accounts row and every synced message stay untouched.
        let kept = try await imap.rows("SELECT COUNT(*) AS c FROM messages").first?["c"]?.int
        try await imap.updateIMAPPassword(email: " Fixture@Example.TEST ", password: "rotated")
        precondition(Keychain.writes.withLock { $0["imap-\(email)"] } == "rotated", "verified password must be stored")
        let after = try await imap.rows("SELECT COUNT(*) AS c FROM messages").first?["c"]?.int
        precondition(after == kept, "updating a password must not touch stored mail")
        let writesBeforeFailures = Keychain.writes.withLock { $0.count }
        for (address, expected) in [("ghost@example.test", "没有这个 IMAP 邮箱"), (email, "密码不能为空")] {
            do {
                try await imap.updateIMAPPassword(email: address, password: expected == "密码不能为空" ? "" : "x")
                preconditionFailure("updateIMAPPassword(\(address)) must fail")
            } catch let error as ArchiveClient.Failure {
                precondition(error.message == expected, error.message)
            }
        }
        print("PASS: IMAP password rotation verifies login, stores key, keeps mail")

        let gmail = LocalEngine()
        try await gmail.prepare(email, kind: "gmail", port: 0)
        // The Gmail row must refuse the IMAP password path before opening any connection.
        do {
            try await gmail.updateIMAPPassword(email: email, password: "x")
            preconditionFailure("a Gmail mailbox must reject updateIMAPPassword")
        } catch let error as ArchiveClient.Failure {
            precondition(error.message == "没有这个 IMAP 邮箱", error.message)
        }
        precondition(Keychain.writes.withLock { $0.count } == writesBeforeFailures, "rejected updates must write nothing")
        let fixture = GmailFixture(root)
        let session = GmailSession(email: email, fixture: { path, query in try await fixture.call(path, query) })
        await gmail.install(session, email: email)
        let gmailDelay = await gmail.syncGmail(email)
        precondition(gmailDelay == 60)
        var rows = try await gmail.rows("SELECT * FROM messages ORDER BY id")
        precondition(rows.count == 1 && rows[0]["subject"]?.text == "Hello ✓")
        let attachments = try await gmail.rows("SELECT filename FROM attachments")
        precondition(attachments.first?["filename"]?.text == "note.txt")
        let fts = try await gmail.rows("SELECT body FROM fts")
        precondition(fts.first?["body"]?.text == "plain body")
        await fixture.advance()
        let incrementalDelay = await gmail.syncGmail(email)
        precondition(incrementalDelay == 60)
        rows = try await gmail.rows("SELECT * FROM messages ORDER BY id")
        precondition(rows.count == 2 && rows[0]["unread"]?.int == 0 && rows[1]["subject"]?.text == "New mail")
        let cursor = try await gmail.rows("SELECT history_id FROM accounts")
        precondition(cursor[0]["history_id"]?.text == "12")
        await fixture.advance()
        let deleteDelay = await gmail.syncGmail(email)
        precondition(deleteDelay == 60)
        rows = try await gmail.rows("SELECT * FROM messages ORDER BY id")
        precondition(rows[1]["status"]?.text == "deleted")
        let finalCursor = try await gmail.rows("SELECT history_id FROM accounts")
        precondition(finalCursor[0]["history_id"]?.text == "13")
        print("PASS: Gmail backfill, paginated incremental, labels/deletion, cursor and nested MIME fixture")

        let cached = await gmail.sessions[email]
        precondition(cached != nil)
        await gmail.resetGmailSession(email)
        let dropped = await gmail.sessions[email]
        precondition(dropped == nil, "resetGmailSession must drop the cached session")
        print("PASS: Gmail session reset drops the cached session")
    }
}
