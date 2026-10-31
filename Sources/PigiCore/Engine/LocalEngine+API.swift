import Foundation

extension LocalEngine {
    private static let listColumns = "account,id,date,subject,from_name,from_email,snippet,unread,starred,status,seq,code,unsub_kind"

    private func item(_ r: SQLRow) -> ArchiveItem {
        ArchiveItem(
            account: r["account"]?.text ?? "", id: r["id"]?.text ?? "", date: r["date"]?.int ?? 0,
            subject: r["subject"]?.text, fromName: r["from_name"]?.text, fromEmail: r["from_email"]?.text,
            snippet: r["snippet"]?.text, unread: r["unread"]?.int ?? 0, starred: r["starred"]?.int ?? 0,
            status: r["status"]?.text ?? "inbox", seq: r["seq"]?.int ?? 0, code: r["code"]?.text, unsubKind: r["unsub_kind"]?.text)
    }

    // MARK: reading

    func accounts() throws -> [ArchiveAccount] {
        try db().query("""
            SELECT a.email,a.kind,a.backfill_done,a.total,a.last_sync,a.last_error,
            (SELECT count(*) FROM messages m WHERE m.account=a.email) AS stored FROM accounts a ORDER BY a.email
            """).map { r in
            ArchiveAccount(
                email: r["email"]?.text ?? "", backfillDone: r["backfill_done"]?.int ?? 0, total: r["total"]?.int ?? 0,
                lastSync: r["last_sync"]?.int, lastError: r["last_error"]?.text, stored: r["stored"]?.int ?? 0, kind: r["kind"]?.text)
        }
    }

    func changes(after: Int, since: Date, limit: Int) throws -> ArchiveChanges {
        let rows = try db().query(
            "SELECT \(Self.listColumns) FROM messages WHERE seq>? AND date>=? ORDER BY seq LIMIT ?",
            [.int(after), .int(Int(since.timeIntervalSince1970 * 1000)), .int(limit)])
        let items = rows.map(item)
        return ArchiveChanges(items: items, next: items.last?.seq ?? after, more: items.count == limit)
    }

    func body(account: String, id: String) throws -> ArchiveClient.Body {
        guard let row = try db().query("SELECT rowid,html FROM messages WHERE account=? AND id=?", [.text(account), .text(id)]).first else {
            throw ArchiveClient.Failure(message: "邮件不存在")
        }
        let text = try db().query("SELECT body FROM fts WHERE rowid=?", [row["rowid"] ?? .null]).first?["body"]?.text ?? ""
        return ArchiveClient.Body(html: row["html"]?.blob.flatMap(inflate), text: text)
    }

    func search(_ term: String, account: String?) throws -> [ArchiveItem] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        var rows: [SQLRow]
        if trimmed.count < 3 {
            rows = try db().query(
                "SELECT \(Self.listColumns) FROM messages WHERE (subject LIKE ? OR from_email LIKE ?)"
                + (account != nil ? " AND account=?" : "") + " ORDER BY date DESC LIMIT 50",
                [.text("%\(trimmed)%"), .text("%\(trimmed)%")] + (account.map { [.text($0)] } ?? []))
        } else {
            let query = trimmed.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            let columns = Self.listColumns.split(separator: ",").map { "m." + $0 }.joined(separator: ",")
            rows = try db().query(
                "SELECT \(columns) FROM fts JOIN messages m ON m.rowid=fts.rowid WHERE fts MATCH ?"
                + (account != nil ? " AND m.account=?" : "") + " ORDER BY m.date DESC LIMIT 50",
                [.text(query)] + (account.map { [.text($0)] } ?? []))
        }
        return rows.map(item)
    }

    func backfillDays() -> Int { backfillDaysValue() }

    func setBackfillDays(_ days: Int) throws {
        guard days != backfillDaysValue() else { return }
        let s = try db()
        try s.run("INSERT OR REPLACE INTO meta VALUES('backfill_days', ?)", [.int(days)])
        try s.run("UPDATE accounts SET page_token=NULL, backfill_done=0")
        for key in due.keys { due[key] = .distantPast }
    }

    func poke() throws {
        for key in try db().query("SELECT email FROM accounts").compactMap({ $0["email"]?.text }) { trigger(key) }
    }

    nonisolated func events() -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task {
                await self.register(id, continuation)
            }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }

    private func register(_ id: UUID, _ continuation: AsyncThrowingStream<Int, Error>.Continuation) {
        let bridge = AsyncStream<Int>.makeStream()
        listeners[id] = bridge.continuation
        if let seq = try? currentSeq() { continuation.yield(seq) }
        Task {
            for await seq in bridge.stream { continuation.yield(seq) }
        }
    }

    private func unregister(_ id: UUID) {
        listeners[id]?.finish()
        listeners[id] = nil
    }

    // MARK: accounts

    func addGmail(_ email: String) throws {
        try db().run("INSERT OR IGNORE INTO accounts(email, added_at, kind) VALUES(?,?,'gmail')", [.text(email.lowercased()), .int(now())])
        trigger(email.lowercased())
    }

    func addIMAP(email: String, password: String, host: String, port: Int) async throws {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard address.contains("@"), !password.isEmpty, !host.isEmpty else { throw ArchiveClient.Failure(message: "邮箱、密码和服务器都要填") }
        guard try account(address) == nil else { throw ArchiveClient.Failure(message: "这个邮箱已经添加过了") }
        let probe = ImapConnection(host: host, port: port)
        try await probe.open()
        do { try await probe.login(user: address, password: password) } catch { probe.close(); throw error }
        await probe.logout()
        Keychain.set("imap-\(address)", password)
        try db().run("INSERT INTO accounts(email, added_at, kind, imap_host, imap_port) VALUES(?,?,'imap',?,?)",
                     [.text(address), .int(now()), .text(host), .int(port)])
        trigger(address)
    }

    func deleteAccount(_ email: String) throws {
        let s = try db()
        try s.transaction {
            try s.run("DELETE FROM fts WHERE rowid IN (SELECT rowid FROM messages WHERE account=?)", [.text(email)])
            try s.run("DELETE FROM attachments WHERE account=?", [.text(email)])
            try s.run("DELETE FROM messages WHERE account=?", [.text(email)])
            try s.run("DELETE FROM muted WHERE account=?", [.text(email)])
            try s.run("DELETE FROM accounts WHERE email=?", [.text(email)])
        }
        Keychain.set("imap-\(email)", "")
        sessions[email] = nil
        due[email] = nil
        announce()
    }

    // MARK: actions

    private func kind(_ email: String) -> String { (try? account(email)?["kind"]?.text) ?? "gmail" }

    /// Changes labels (Gmail vocabulary) on the server, then records the result locally.
    func modify(account: String, ids: [String], add: [String], remove: [String], trash: Bool = false) async throws {
        guard !ids.isEmpty, try self.account(account) != nil else { throw ArchiveClient.Failure(message: "未知的邮箱") }
        var results: [String: [String]] = [:]
        if kind(account) == "imap" {
            results = try await imapApply(account, ids: ids, add: add, remove: remove, trash: trash)
        } else {
            let gm = session(account)
            if trash {
                for id in ids {
                    let reply = try await gm.json("messages/\(id)/trash", body: [:])
                    results[id] = reply["labelIds"] as? [String] ?? []
                }
            } else {
                for start in stride(from: 0, to: ids.count, by: 1000) {
                    let chunk = Array(ids[start..<min(start + 1000, ids.count)])
                    _ = try await gm.call("messages/batchModify", body: ["ids": chunk, "addLabelIds": add, "removeLabelIds": remove])
                }
                for id in ids { results[id] = Array(Set(storedLabels(account, id)).union(add).subtracting(remove)).sorted() }
            }
        }
        for (id, labels) in results { updateLabels(account, id, labels) }
        announce()
    }

    func unsubscribe(account: String, id: String) async throws -> ArchiveClient.UnsubscribeResult {
        guard let row = try db().query("SELECT unsub_kind,unsub FROM messages WHERE account=? AND id=?", [.text(account), .text(id)]).first,
              let json = row["unsub"]?.text, let info = try? JSONDecoder().decode(Detect.Unsub.self, from: Data(json.utf8)) else {
            throw ArchiveClient.Failure(message: "这封邮件没有退订信息")
        }
        guard row["unsub_kind"]?.text == "one_click", let link = info.url.flatMap(URL.init(string:)) else {
            return .manual(info.url.flatMap(URL.init(string:)))
        }
        guard Detect.isPublicURL(link) else { throw ArchiveClient.Failure(message: "退订地址不安全,已拒绝") }
        var request = URLRequest(url: link, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("pigi", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(status) else { throw ArchiveClient.Failure(message: "对方返回 \(status)") }
        try await modify(account: account, ids: [id], add: [], remove: ["INBOX"])
        return .done
    }

    func mute(account: String, sender: String, id: String) async throws {
        guard !sender.isEmpty else { return }
        try db().run("INSERT OR IGNORE INTO muted VALUES(?,?)", [.text(account), .text(sender.lowercased())])
        if !id.isEmpty { try await modify(account: account, ids: [id], add: [], remove: ["INBOX"]) }
    }
}
