import Foundation

extension LocalEngine {
    // MARK: connection

    func imapConnect(_ email: String) async throws -> ImapConnection {
        guard let row = try account(email), let host = row["imap_host"]?.text else { throw ImapError(message: "没有这个邮箱") }
        let port = row["imap_port"]?.int ?? 993
        let connection = ImapConnection(host: host, port: port)
        try await connection.open()
        do {
            try await connection.login(user: email, password: Keychain.get("imap-\(email)") ?? "")
        } catch {
            connection.close()
            throw error
        }
        return connection
    }

    static func imapLabels(_ flags: Set<String>) -> [String] {
        ["INBOX"] + (flags.contains("\\seen") ? [] : ["UNREAD"]) + (flags.contains("\\flagged") ? ["STARRED"] : [])
    }

    static func parseDate(_ text: String?) -> Date? {
        guard var text = text else { return nil }
        text = text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: sync

    func syncIMAP(_ email: String) async -> Double {
        do {
            let s = try db()
            let days = backfillDaysValue()
            let cutoff = days > 0 ? Int(Date().timeIntervalSince1970 * 1000) - days * 86_400_000 : 0
            let c = try await imapConnect(email)
            defer { Task { await c.logout() } }
            let validity = try await c.select("INBOX")
            let known = try account(email)?["history_id"]?.text
            if let known, known != validity {  // the server renumbered the mailbox: old ids mean nothing now
                for row in try s.query("SELECT id FROM messages WHERE account=?", [.text(email)]) {
                    if let id = row["id"]?.text { markDeleted(email, id) }
                }
            }
            try s.run("UPDATE accounts SET history_id=? WHERE email=?", [.text(validity), .text(email)])

            var criteria = "ALL"
            if days > 0 {
                let since = Date(timeIntervalSince1970: Double(cutoff) / 1000)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                let p = calendar.dateComponents([.day, .month, .year], from: since)
                criteria = "SINCE \(String(format: "%02d", p.day!))-\(Self.months[p.month! - 1])-\(p.year!)"
            }
            let uids = Set(try await c.search(criteria))
            var flags: [Int: Set<String>] = [:]
            let ordered = uids.sorted()
            for start in stride(from: 0, to: ordered.count, by: 400) {
                for item in try await c.fetch(Array(ordered[start..<min(start + 400, ordered.count)]), items: "FLAGS") {
                    flags[item.uid] = item.flags
                }
            }
            var stored: [String: SQLRow] = [:]
            for row in try s.query("SELECT id,unread,starred,status,date,labels FROM messages WHERE account=?", [.text(email)]) {
                if let id = row["id"]?.text { stored[id] = row }
            }
            for (uid, f) in flags {
                guard let row = stored[String(uid)] else { continue }
                let want = Self.imapLabels(f)
                if row["status"]?.text != "inbox" || (row["unread"]?.int == 1) != want.contains("UNREAD") || (row["starred"]?.int == 1) != want.contains("STARRED") {
                    updateLabels(email, String(uid), want)
                }
            }
            for (id, row) in stored where row["status"]?.text == "inbox" && (row["date"]?.int ?? 0) >= cutoff {
                if let uid = Int(id), !uids.contains(uid) {
                    updateLabels(email, id, storedLabels(email, id).filter { $0 != "INBOX" })
                }
            }
            let fresh = uids.filter { stored[String($0)] == nil }.sorted(by: >)
            let batch = Array(fresh.prefix(slice))
            for start in stride(from: 0, to: batch.count, by: 20) {
                let chunk = Array(batch[start..<min(start + 20, batch.count)])
                for item in try await c.fetch(chunk, items: "UID FLAGS INTERNALDATE BODY.PEEK[]") {
                    guard let raw = item.raw, raw.count <= 15 * 1024 * 1024 else { continue }
                    storeIMAP(email, item)
                    if let row = try? s.query("SELECT from_email FROM messages WHERE account=? AND id=?", [.text(email), .text(String(item.uid))]).first,
                       let sender = row["from_email"]?.text, isMuted(email, sender) {
                        _ = try? await imapApply(email, ids: [String(item.uid)], add: [], remove: ["INBOX"], trash: false)
                    }
                }
            }
            let count = try s.query("SELECT count(*) AS n FROM messages WHERE account=?", [.text(email)]).first?["n"]?.int ?? 0
            let more = fresh.count > slice
            try s.run("UPDATE accounts SET backfill_done=?,total=?,last_sync=?,last_error=NULL WHERE email=?",
                      [.int(more ? 0 : 1), .int(count), .int(now()), .text(email)])
            return more ? 2 : pollSeconds
        } catch {
            setError(email, error.localizedDescription)
            return 300
        }
    }

    func storeIMAP(_ email: String, _ item: ImapConnection.Fetched) {
        guard let raw = item.raw else { return }
        let mail = MIME.parse(raw)
        let text = mail.text.isEmpty ? Detect.stripTags(mail.html) : mail.text
        let (name, addr) = Detect.parseAddress(mail.headers["from"] ?? "")
        let date = Self.parseDate(mail.headers["date"]) ?? item.internalDate ?? Date()
        let snippet = String(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(200))
        try? save(Draft(
            account: email, id: String(item.uid), threadID: nil, date: Int(date.timeIntervalSince1970 * 1000),
            subject: mail.headers["subject"] ?? "", name: name, address: addr, to: mail.headers["to"] ?? "",
            snippet: snippet, labels: Self.imapLabels(item.flags),
            attachments: mail.attachments.enumerated().map { (String($0.offset), $0.element.name, $0.element.mime, $0.element.size, "") },
            size: raw.count, html: mail.html, text: text, headers: mail.headers))
    }

    // MARK: actions

    func relocate(_ c: ImapConnection, uid: String, role: String) async throws {
        let listed = try await c.folders()
        func find(_ flag: String, _ names: [String]) -> String? {
            if let f = listed.first(where: { $0.attributes.contains(flag) }) { return f.name }
            let lowered = Dictionary(listed.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
            return names.compactMap { lowered[$0.lowercased()] }.first
        }
        var folder: String?
        if role == "trash" {
            folder = find("\\trash", ["Trash", "Deleted Items", "Deleted Messages", "[Gmail]/Trash", "已删除邮件"])
        } else {
            folder = find("\\archive", ["Archive", "Archives", "[Gmail]/All Mail", "归档"])
            if folder == nil {
                folder = "Archive"
                try await c.command("CREATE \(ImapConnection.quote("Archive"))", allowNO: true)
            }
        }
        guard let folder else {  // no trash folder: flag it and let the server purge it
            try await c.command("UID STORE \(uid) +FLAGS (\\Deleted)")
            try await c.command("EXPUNGE")
            return
        }
        if c.capabilities.contains("MOVE"), (try? await c.command("UID MOVE \(uid) \(ImapConnection.quote(folder))")) != nil { return }
        try await c.command("UID COPY \(uid) \(ImapConnection.quote(folder))")
        try await c.command("UID STORE \(uid) +FLAGS (\\Deleted)")
        try await c.command("EXPUNGE")
    }

    /// Applies label changes (Gmail vocabulary) to INBOX messages; returns the resulting labels per id.
    func imapApply(_ email: String, ids: [String], add: [String], remove: [String], trash: Bool) async throws -> [String: [String]] {
        let c = try await imapConnect(email)
        defer { Task { await c.logout() } }
        _ = try await c.select("INBOX")
        var result: [String: [String]] = [:]
        for id in ids {
            var labels = Set(storedLabels(email, id))
            if trash {
                try await relocate(c, uid: id, role: "trash")
                labels = labels.subtracting(["INBOX", "UNREAD"]).union(["TRASH"])
            } else {
                if remove.contains("UNREAD") { try await c.command("UID STORE \(id) +FLAGS (\\Seen)") }
                if add.contains("UNREAD") { try await c.command("UID STORE \(id) -FLAGS (\\Seen)") }
                if add.contains("STARRED") { try await c.command("UID STORE \(id) +FLAGS (\\Flagged)") }
                if remove.contains("STARRED") { try await c.command("UID STORE \(id) -FLAGS (\\Flagged)") }
                if remove.contains("INBOX"), labels.contains("INBOX") { try await relocate(c, uid: id, role: "archive") }
                labels = labels.union(add).subtracting(remove)
            }
            result[id] = labels.sorted()
        }
        return result
    }
}
