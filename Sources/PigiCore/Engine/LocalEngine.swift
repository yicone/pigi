import Foundation

/// The mail engine that runs inside the app: syncs Gmail (REST API), IMAP, and read-only Proton
/// mailboxes into a local SQLite database with full-text search. Gmail and IMAP can apply read /
/// star / archive / delete back to the server. Proton never mutates remote state.
public actor LocalEngine {
    public static let shared = LocalEngine()

    let credentials: CredentialStore

    init(credentials: CredentialStore = CredentialStore()) {
        self.credentials = credentials
    }

    var store: Store?
    var translationCache = SQLiteTranslationCache.shared
    #if DEBUG
    // Actor-isolated fixture dependencies for testing the public ArchiveClient/shared-engine path.
    var translationDependencies: TranslationDependencies?
    #endif
    var sessions: [String: GmailSession] = [:]
    var protonSessions: [String: any ProtonSyncRemote] = [:]
    var due: [String: Date] = [:]
    var running: Set<String> = []
    var dirty: Set<String> = []
    var listeners: [UUID: AsyncStream<Int>.Continuation] = [:]
    var loop: Task<Void, Never>?

    let pollSeconds = 60.0
    let slice = 300
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    // MARK: database

    static let schema = [
        "CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v INTEGER)",
        "INSERT OR IGNORE INTO meta VALUES('seq', 0)",
        """
        CREATE TABLE IF NOT EXISTS accounts(
          email TEXT PRIMARY KEY, history_id TEXT, page_token TEXT, backfill_done INTEGER DEFAULT 0,
          total INTEGER DEFAULT 0, last_sync INTEGER, last_error TEXT, last_error_kind TEXT, added_at INTEGER,
          kind TEXT DEFAULT 'gmail', imap_host TEXT, imap_port INTEGER)
        """,
        """
        CREATE TABLE IF NOT EXISTS messages(
          account TEXT NOT NULL, id TEXT NOT NULL, thread_id TEXT, date INTEGER, subject TEXT,
          from_name TEXT, from_email TEXT, to_addr TEXT, snippet TEXT, labels TEXT,
          unread INTEGER, starred INTEGER, status TEXT, has_att INTEGER, size INTEGER,
          signature_status TEXT, html BLOB, seq INTEGER, code TEXT, unsub_kind TEXT, unsub TEXT, PRIMARY KEY(account, id))
        """,
        "CREATE INDEX IF NOT EXISTS msg_seq ON messages(seq)",
        "CREATE INDEX IF NOT EXISTS msg_date ON messages(account, date)",
        """
        CREATE TABLE IF NOT EXISTS attachments(
          account TEXT, msg_id TEXT, part_id TEXT, filename TEXT, mime TEXT, size INTEGER, att_id TEXT,
          PRIMARY KEY(account, msg_id, part_id))
        """,
        "CREATE TABLE IF NOT EXISTS account_labels(account TEXT, id TEXT, name TEXT, parent TEXT, type INTEGER, PRIMARY KEY(account,id))",
        "CREATE TABLE IF NOT EXISTS proton_snapshot(account TEXT, id TEXT, PRIMARY KEY(account,id))",
        "CREATE TABLE IF NOT EXISTS muted(account TEXT, sender TEXT, PRIMARY KEY(account, sender))",
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(subject, sender, body, tokenize='trigram')",
    ]

    func db() throws -> Store {
        if let store { return store }
        let dir = try AppSupport.pigiDirectory()
        let opened = try Store(path: dir.appendingPathComponent("mail.db").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("mail.db").path)
        for statement in Self.schema { try opened.run(statement) }
        if !((try opened.query("PRAGMA table_info(messages)")).contains { $0["name"]?.text == "signature_status" }) {
            try opened.run("ALTER TABLE messages ADD COLUMN signature_status TEXT")
        }
        try Self.migrate(opened)
        store = opened
        return opened
    }

    /// Adds `accounts.last_error_kind` to databases created before it existed
    /// and classifies stored error texts into the new buckets. Idempotent.
    static func migrate(_ store: Store) throws {
        if (try store.query("PRAGMA table_info(accounts)")).contains(where: { $0["name"]?.text == "last_error_kind" }) { return }
        try store.run("ALTER TABLE accounts ADD COLUMN last_error_kind TEXT")
        for row in try store.query("SELECT email,last_error FROM accounts WHERE last_error IS NOT NULL") {
            guard let email = row["email"]?.text, let message = row["last_error"]?.text else { continue }
            try store.run("UPDATE accounts SET last_error_kind=? WHERE email=?",
                          [.text(legacyErrorKind(message).rawValue), .text(email)])
        }
    }

    /// Classifies an error text stored by an older build that had no kind column.
    static func legacyErrorKind(_ message: String) -> AccountErrorKind {
        let keychain = [CredentialPersistenceError.writeFailed.localizedDescription,
                        CredentialPersistenceError.recoveryFailed.localizedDescription,
                        CredentialPersistenceError.readFailed.localizedDescription]
        if keychain.contains(message) { return .keychain }
        if ["无法连接 Proton", "请求超时", "请求过于频繁", "代理需要认证", "将重试"].contains(where: message.contains) { return .network }
        if ["会话失效", "账号、密码或验证码", "请重新登录"].contains(where: message.contains) { return .auth }
        return .other
    }

    /// Classifies a live sync error. Only credential-store failures are keychain.
    static func syncErrorKind(_ error: Error) -> AccountErrorKind {
        if error is CredentialPersistenceError { return .keychain }
        if let error = error as? ProtonHelperError { return error.kind }
        if error is GmailRevoked { return .auth }
        if let error = error as? ImapError {
            if error.message.hasPrefix("登录失败") { return .auth }
            if ["连接", "读取失败", "发送失败", "服务器关闭"].contains(where: error.message.hasPrefix) { return .network }
            return .other
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed:
                return .network
            default: return .other
            }
        }
        return .other
    }

    func nextSeq() throws -> Int {
        let s = try db()
        try s.run("UPDATE meta SET v=v+1 WHERE k='seq'")
        return try currentSeq()
    }

    func currentSeq() throws -> Int {
        try db().query("SELECT v FROM meta WHERE k='seq'").first?["v"]?.int ?? 0
    }

    // MARK: lifecycle

    public func start() throws {
        guard loop == nil else { return }
        // One keychain read before per-account sync, so startup does not prompt once per mailbox.
        try Keychain.warm()
        try? ensureGmailAccounts()
        loop = Task { await runLoop() }
    }

    func ensureGmailAccounts() throws {
        let s = try db()
        for email in GmailStore.emails {
            try s.run("INSERT OR IGNORE INTO accounts(email, added_at, kind) VALUES(?,?,'gmail')", [.text(email.lowercased()), .int(now())])
        }
    }

    func now() -> Int { Int(Date().timeIntervalSince1970) }

    func runLoop() async {
        while !Task.isCancelled {
            let emails = ((try? db().query("SELECT email FROM accounts")) ?? []).compactMap { $0["email"]?.text }
            for email in emails where !running.contains(email) && (due[email] ?? .distantPast) <= Date() {
                running.insert(email)
                Task { await self.sync(email) }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func sync(_ email: String) async {
        dirty.remove(email)
        let before = (try? currentSeq()) ?? 0
        let kind = (try? account(email)?["kind"]?.text) ?? "gmail"
        let delay: Double
        switch kind {
        case "proton": delay = await syncProton(email)
        case "imap": delay = await syncIMAP(email)
        default: delay = await syncGmail(email)
        }
        due[email] = dirty.contains(email) ? .distantPast : Date().addingTimeInterval(delay)
        running.remove(email)
        if (try? currentSeq()) != before { announce() }
    }

    func trigger(_ email: String) {
        dirty.insert(email)
        due[email] = .distantPast
    }

    func account(_ email: String) throws -> SQLRow? {
        try db().query("SELECT * FROM accounts WHERE email=?", [.text(email)]).first
    }

    func setError(_ email: String, _ text: String?, kind: AccountErrorKind?) {
        _ = try? db().run("UPDATE accounts SET last_error=?,last_error_kind=? WHERE email=?",
                          [.opt(text), .opt(text == nil ? nil : kind?.rawValue), .text(email)])
    }

    func announce() {
        guard let seq = try? currentSeq() else { return }
        for continuation in listeners.values { continuation.yield(seq) }
    }

    // MARK: saving

    static func statusOf(_ labels: [String]) -> String {
        if labels.contains("TRASH") { return "trash" }
        if labels.contains("SPAM") { return "spam" }
        if labels.contains("INBOX") { return "inbox" }
        return "archived"
    }

    func labelsJSON(_ labels: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: labels)) ?? Data("[]".utf8), as: UTF8.self)
    }

    func compress(_ html: String) -> SQLValue {
        guard !html.isEmpty, let packed = try? (Data(html.utf8) as NSData).compressed(using: .zlib) else { return .null }
        return .blob(packed as Data)
    }

    func inflate(_ data: Data) -> String? {
        (try? (data as NSData).decompressed(using: .zlib)).map { String(decoding: $0 as Data, as: UTF8.self) }
    }

    struct Draft {
        var account: String
        var id: String
        var threadID: String?
        var date: Int
        var subject: String
        var name: String
        var address: String
        var to: String
        var snippet: String
        var labels: [String]
        var attachments: [(part: String, name: String, mime: String, size: Int, ref: String)]
        var size: Int
        var html: String
        var text: String
        var headers: [String: String]
        var signatureStatus: String? = nil
    }

    func save(_ d: Draft) throws {
        let s = try db()
        let unsub = Detect.unsubInfo(headers: d.headers, html: d.html)
        let unsubJSON = unsub.flatMap { try? String(decoding: JSONEncoder().encode($0.info), as: UTF8.self) }
        let code = Detect.extractCode(subject: d.subject, text: d.text)
        try s.transaction {
            let existing = try s.query("SELECT rowid FROM messages WHERE account=? AND id=?", [.text(d.account), .text(d.id)]).first
            let seq = try nextSeq()
            let values: [SQLValue] = [
                .opt(d.threadID), .int(d.date), .text(d.subject), .text(d.name), .text(d.address), .text(d.to),
                .text(d.snippet), .text(labelsJSON(d.labels)), .int(d.labels.contains("UNREAD") ? 1 : 0),
                .int(d.labels.contains("STARRED") ? 1 : 0), .text(Self.statusOf(d.labels)),
                .int(d.attachments.isEmpty ? 0 : 1), .int(d.size), compress(d.html), .int(seq),
                .opt(code), .opt(unsub?.kind), .opt(unsubJSON), .opt(d.signatureStatus),
            ]
            if let existing {
                try s.run("DELETE FROM fts WHERE rowid=?", [existing["rowid"] ?? .null])
                try s.run("INSERT INTO fts(rowid,subject,sender,body) VALUES(?,?,?,?)",
                          [existing["rowid"] ?? .null, .text(d.subject), .text("\(d.name) \(d.address)"), .text(d.text)])
                try s.run("""
                    UPDATE messages SET thread_id=?,date=?,subject=?,from_name=?,from_email=?,to_addr=?,snippet=?,labels=?,
                    unread=?,starred=?,status=?,has_att=?,size=?,html=?,seq=?,code=?,unsub_kind=?,unsub=?,signature_status=? WHERE account=? AND id=?
                    """, values + [.text(d.account), .text(d.id)])
            } else {
                let rowid = try s.run("""
                    INSERT INTO messages(thread_id,date,subject,from_name,from_email,to_addr,snippet,labels,unread,starred,
                    status,has_att,size,html,seq,code,unsub_kind,unsub,signature_status,account,id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, values + [.text(d.account), .text(d.id)])
                try s.run("INSERT INTO fts(rowid,subject,sender,body) VALUES(?,?,?,?)",
                          [.int(Int(rowid)), .text(d.subject), .text("\(d.name) \(d.address)"), .text(d.text)])
            }
            try s.run("DELETE FROM attachments WHERE account=? AND msg_id=?", [.text(d.account), .text(d.id)])
            for a in d.attachments {
                try s.run("INSERT OR REPLACE INTO attachments VALUES(?,?,?,?,?,?,?)",
                          [.text(d.account), .text(d.id), .text(a.part), .text(a.name), .text(a.mime), .int(a.size), .text(a.ref)])
            }
        }
    }

    func updateLabels(_ account: String, _ id: String, _ labels: [String]) {
        guard let seq = try? nextSeq() else { return }
        _ = try? db().run("UPDATE messages SET labels=?,unread=?,starred=?,status=?,seq=? WHERE account=? AND id=?",
                      [.text(labelsJSON(labels)), .int(labels.contains("UNREAD") ? 1 : 0), .int(labels.contains("STARRED") ? 1 : 0),
                       .text(Self.statusOf(labels)), .int(seq), .text(account), .text(id)])
    }

    func markDeleted(_ account: String, _ id: String) {
        guard let seq = try? nextSeq() else { return }
        _ = try? db().run("UPDATE messages SET status='deleted',seq=? WHERE account=? AND id=?", [.int(seq), .text(account), .text(id)])
    }

    func has(_ account: String, _ id: String) -> Bool {
        ((try? db().query("SELECT 1 FROM messages WHERE account=? AND id=?", [.text(account), .text(id)])) ?? []).isEmpty == false
    }

    func storedLabels(_ account: String, _ id: String) -> [String] {
        guard let json = (try? db().query("SELECT labels FROM messages WHERE account=? AND id=?", [.text(account), .text(id)]))?.first?["labels"]?.text,
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String] else { return ["INBOX"] }
        return list
    }

    func isMuted(_ account: String, _ sender: String) -> Bool {
        ((try? db().query("SELECT 1 FROM muted WHERE account=? AND sender=?", [.text(account), .text(sender)])) ?? []).isEmpty == false
    }

    // MARK: Gmail sync

    func session(_ email: String) -> GmailSession {
        if let existing = sessions[email] { return existing }
        let created = GmailSession(email: email)
        sessions[email] = created
        return created
    }

    func backfillDaysValue() -> Int {
        (try? db().query("SELECT v FROM meta WHERE k='backfill_days'").first?["v"]?.int) ?? 30
    }

    func syncGmail(_ email: String) async -> Double {
        let gm = session(email)
        do {
            let profile = try await gm.json("profile")
            guard var acct = try account(email) else { return pollSeconds }
            let s = try db()
            let restart = {
                try s.run("UPDATE accounts SET history_id=?,page_token=NULL,backfill_done=0 WHERE email=?",
                          [.opt(profile["historyId"] as? String), .text(email)])
            }
            if acct["history_id"]?.text == nil {
                _ = try restart()
            } else if try await !incremental(gm, email, startHistory: acct["history_id"]?.text ?? "") {
                _ = try restart()
            }
            acct = try account(email) ?? acct
            if (acct["backfill_done"]?.int ?? 0) == 0 {
                try await backfill(gm, email, pageToken: acct["page_token"]?.text)
            }
            try s.run("UPDATE accounts SET total=?,last_sync=?,last_error=NULL,last_error_kind=NULL WHERE email=?",
                      [.int(profile["messagesTotal"] as? Int ?? 0), .int(now()), .text(email)])
            let done = try account(email)?["backfill_done"]?.int ?? 0
            return done == 1 ? pollSeconds : 2
        } catch is GmailRevoked {
            setError(email, GmailRevoked().errorDescription, kind: .auth)
            return 3600
        } catch {
            setError(email, error.localizedDescription, kind: Self.syncErrorKind(error))
            return 120
        }
    }

    func incremental(_ gm: GmailSession, _ email: String, startHistory: String) async throws -> Bool {
        var added = Set<String>(), changed = Set<String>(), deleted = Set<String>()
        var token: String?
        var newest = startHistory
        repeat {
            var query = [("startHistoryId", startHistory), ("maxResults", "500")]
            if let token { query.append(("pageToken", token)) }
            let reply: [String: Any]
            do { reply = try await gm.json("history", query: query) }
            catch let error as GmailFailure where error.status == 404 { return false }
            for h in reply["history"] as? [[String: Any]] ?? [] {
                for x in h["messagesAdded"] as? [[String: Any]] ?? [] { if let id = (x["message"] as? [String: Any])?["id"] as? String { added.insert(id) } }
                for key in ["labelsAdded", "labelsRemoved"] {
                    for x in h[key] as? [[String: Any]] ?? [] { if let id = (x["message"] as? [String: Any])?["id"] as? String { changed.insert(id) } }
                }
                for x in h["messagesDeleted"] as? [[String: Any]] ?? [] { if let id = (x["message"] as? [String: Any])?["id"] as? String { deleted.insert(id) } }
            }
            newest = reply["historyId"] as? String ?? newest
            token = reply["nextPageToken"] as? String
        } while token != nil
        try await fetchMany(gm, email, added.filter { !deleted.contains($0) && !has(email, $0) })
        for id in changed.subtracting(added).subtracting(deleted) {
            if has(email, id) {
                do {
                    let msg = try await gm.json("messages/\(id)", query: [("format", "minimal")])
                    updateLabels(email, id, msg["labelIds"] as? [String] ?? [])
                } catch let error as GmailFailure where error.status == 404 {}
            } else {
                try await fetchMany(gm, email, [id])
            }
        }
        for id in deleted { markDeleted(email, id) }
        try db().run("UPDATE accounts SET history_id=? WHERE email=?", [.text(newest), .text(email)])
        return true
    }

    func backfill(_ gm: GmailSession, _ email: String, pageToken: String?) async throws {
        var token = pageToken
        var done = 0
        let days = backfillDaysValue()
        while done < slice {
            var query = [("maxResults", "500"), ("includeSpamTrash", "true")]
            if days > 0 { query.append(("q", "newer_than:\(days)d")) }
            if let token { query.append(("pageToken", token)) }
            let reply = try await gm.json("messages", query: query)
            let ids = (reply["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.filter { !has(email, $0) }
            try await fetchMany(gm, email, ids)
            done += ids.count
            token = reply["nextPageToken"] as? String
            try db().run("UPDATE accounts SET page_token=?, backfill_done=? WHERE email=?",
                         [.opt(token), .int(token == nil ? 1 : 0), .text(email)])
            if token == nil { return }
        }
    }

    func fetchMany(_ gm: GmailSession, _ email: String, _ ids: [String]) async throws {
        for start in stride(from: 0, to: ids.count, by: 24) {
            let chunk = Array(ids[start..<min(start + 24, ids.count)])
            let fetched: [(String, Data?)] = try await withThrowingTaskGroup(of: (String, Data?).self) { group in
                for id in chunk {
                    group.addTask {
                        do { return (id, try await gm.call("messages/\(id)", query: [("format", "full")])) }
                        catch let error as GmailFailure where error.status == 404 { return (id, nil) }
                    }
                }
                var out: [(String, Data?)] = []
                for try await item in group { out.append(item) }
                return out
            }
            for (id, data) in fetched {
                guard let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                try storeGmail(email, msg)
                await muteIfNeeded(gm, email, id)
            }
        }
    }

    func muteIfNeeded(_ gm: GmailSession, _ email: String, _ id: String) async {
        guard let row = try? db().query("SELECT from_email,status FROM messages WHERE account=? AND id=?", [.text(email), .text(id)]).first,
              row["status"]?.text == "inbox", let sender = row["from_email"]?.text, isMuted(email, sender) else { return }
        if let reply = try? await gm.json("messages/\(id)/modify", body: ["removeLabelIds": ["INBOX"]]) {
            updateLabels(email, id, reply["labelIds"] as? [String] ?? [])
        }
    }

    struct Parts {
        var text: [String] = []
        var html: [String] = []
        var attachments: [(part: String, name: String, mime: String, size: Int, ref: String)] = []
    }

    func decodeBase64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    func walk(_ part: [String: Any], _ out: inout Parts) {
        let mime = part["mimeType"] as? String ?? ""
        let body = part["body"] as? [String: Any] ?? [:]
        if let name = part["filename"] as? String, !name.isEmpty, let ref = body["attachmentId"] as? String {
            out.attachments.append((part["partId"] as? String ?? "", name, mime, body["size"] as? Int ?? 0, ref))
        } else if mime == "text/plain" || mime == "text/html", let data = (body["data"] as? String).flatMap(decodeBase64URL) {
            var charset: String?
            for h in part["headers"] as? [[String: Any]] ?? [] where (h["name"] as? String)?.lowercased() == "content-type" {
                if let value = h["value"] as? String, let r = value.range(of: #"charset="?([\w-]+)"#, options: [.regularExpression, .caseInsensitive]) {
                    charset = String(value[r]).replacingOccurrences(of: "charset=", with: "", options: .caseInsensitive).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            let text = MIME.string(data, charset: charset)
            if mime == "text/html" { out.html.append(text) } else { out.text.append(text) }
        }
        for sub in part["parts"] as? [[String: Any]] ?? [] { walk(sub, &out) }
    }

    func storeGmail(_ email: String, _ msg: [String: Any]) throws {
        guard let id = msg["id"] as? String else { return }
        let payload = msg["payload"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        for h in payload["headers"] as? [[String: Any]] ?? [] {
            if let n = (h["name"] as? String)?.lowercased(), let v = h["value"] as? String, headers[n] == nil { headers[n] = v }
        }
        var parts = Parts()
        walk(payload, &parts)
        let html = parts.html.joined(separator: "\n")
        let text = parts.text.isEmpty ? Detect.stripTags(html) : parts.text.joined(separator: "\n")
        let (name, addr) = Detect.parseAddress(MIME.decodeWords(headers["from"] ?? ""))
        try save(Draft(
            account: email, id: id, threadID: msg["threadId"] as? String,
            date: Int(msg["internalDate"] as? String ?? "") ?? 0,
            subject: MIME.decodeWords(headers["subject"] ?? ""), name: name, address: addr,
            to: MIME.decodeWords(headers["to"] ?? ""), snippet: msg["snippet"] as? String ?? "",
            labels: msg["labelIds"] as? [String] ?? [], attachments: parts.attachments,
            size: msg["sizeEstimate"] as? Int ?? 0, html: html, text: text, headers: headers))
    }
}
