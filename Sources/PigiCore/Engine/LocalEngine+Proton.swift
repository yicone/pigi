import Foundation

extension LocalEngine {
    func addProton(username: String, password: String, mailboxPassword: String, otp: String, interaction: ProtonLoginInteraction? = nil) async throws {
        let remote = try await ProtonSession.signIn(username: username, password: password, mailboxPassword: mailboxPassword, otp: otp, interaction: interaction)
        let email = remote.email
        do {
            let existing = try account(email)
            guard existing == nil || existing?["kind"]?.text == "proton" else {
                throw ArchiveClient.Failure(message: "这个邮箱已使用其他类型添加")
            }
            // Reauthentication keeps the cursor and mail. A completed new login
            // replaces only this account's secret, after identity is known.
            let previous = protonSessions[email] as? ProtonSession
            previous?.deactivate()
            let previousSecret = Keychain.get(ProtonSession.key(email))
            do {
                try db().transaction {
                    try db().run("INSERT OR IGNORE INTO accounts(email,added_at,kind) VALUES(?,?,'proton')", [.text(email), .int(now())])
                    try remote.persistInitial()
                }
            } catch {
                _ = Keychain.set(ProtonSession.key(email), previousSecret ?? "")
                previous?.reactivate()
                throw error
            }
            protonSessions[email] = remote
            trigger(email)
            announce()
            try? await previous?.client.logout()
        } catch {
            try? await remote.client.logout()
            throw error
        }
    }

    func protonLabels(_ email: String) throws -> [ProtonLabel] {
        try db().query("SELECT * FROM account_labels WHERE account=? ORDER BY type,name", [.text(email)]).map {
            ProtonLabel(id: $0["id"]?.text ?? "", name: $0["name"]?.text ?? "", parent: $0["parent"]?.text ?? "", type: $0["type"]?.int ?? 1)
        }
    }

    private func checkProton(_ email: String, _ remote: any ProtonSyncRemote) throws {
        guard protonSessions[email] === remote, try account(email)?["kind"]?.text == "proton" else { throw CancellationError() }
    }

    func syncProton(_ email: String) async -> Double {
        var attempted: (any ProtonSyncRemote)?
        do {
            let remote: any ProtonSyncRemote
            if let active = protonSessions[email] { remote = active; attempted = active }
            else {
                let restored = try ProtonSession.fromKeychain(email)
                // Register before awaiting so remove/re-login can deactivate it.
                protonSessions[email] = restored
                attempted = restored
                try await restored.resume()
                try checkProton(email, restored)
                remote = restored
            }
            try await pullProton(email, remote: remote)
            try checkProton(email, remote)
            try db().run("UPDATE accounts SET last_sync=?,last_error=NULL,total=(SELECT count(*) FROM messages WHERE account=? AND status!='deleted') WHERE email=?",
                         [.int(now()), .text(email), .text(email)])
            let done = try account(email)?["backfill_done"]?.int == 1
            return done ? pollSeconds : 2
        } catch is CancellationError { return pollSeconds }
        catch {
            if let attempted, protonSessions[email] !== attempted { return pollSeconds }
            // Never save SDK, SQL or decoding diagnostics, which may carry content.
            let safe = (error as? ProtonHelperError)?.localizedDescription ?? "Proton 同步未完成，将重试"
            setError(email, safe)
            if let code = error as? ProtonHelperError, [.credentials, .notAuthenticated, .transport, .timeout, .key, .keyMissing, .keyFormat, .keyDecryption].contains(code) {
                (protonSessions[email] as? ProtonSession)?.deactivate()
                protonSessions[email] = nil
            }
            return 120
        }
    }

    func pullProton(_ email: String, remote: any ProtonSyncRemote) async throws {
        try checkProton(email, remote)
        let labels = try await remote.labels()
        try checkProton(email, remote)
        let s = try db()
        let previousLabels = try protonLabels(email)
        let labelsChanged = previousLabels.sorted { ($0.type, $0.name, $0.id) < ($1.type, $1.name, $1.id) } != labels.sorted { ($0.type, $0.name, $0.id) < ($1.type, $1.name, $1.id) }
        try s.transaction {
            if labelsChanged { _ = try nextSeq() }
            try s.run("DELETE FROM account_labels WHERE account=?", [.text(email)])
            for label in labels {
                try s.run("INSERT INTO account_labels VALUES(?,?,?,?,?)", [.text(email), .text(label.id), .text(label.name), .text(label.parent), .int(label.type)])
            }
        }
        guard let acct = try account(email) else { throw CancellationError() }
        var cursor = acct["history_id"]?.text
        if cursor == nil {
            let latest = try await remote.latest()
            try checkProton(email, remote)
            guard !latest.isEmpty else { throw ProtonHelperError.protocolViolation }
            try beginProtonSnapshot(email, cursor: latest)
            cursor = latest
        }
        if try account(email)?["backfill_done"]?.int != 1 {
            let after = try account(email)?["page_token"]?.text ?? ""
            let ids = try await remote.snapshot(after: after)
            try checkProton(email, remote)
            guard Set(ids).count == ids.count, !ids.contains(after) else { throw ProtonHelperError.protocolViolation }
            for id in ids {
                try await fetchProton(email, id: id, remote: remote)
                try s.run("INSERT OR IGNORE INTO proton_snapshot VALUES(?,?)", [.text(email), .text(id)])
            }
            try checkProton(email, remote)
            if let last = ids.last {
                // Paging by stable ID, never a shifting page offset. A crash can
                // replay the page safely; no cursor advances ahead of a body.
                try s.run("UPDATE accounts SET page_token=? WHERE email=?", [.text(last), .text(email)])
                return
            }
            try s.transaction {
                let seq = try nextSeq()
                try s.run("UPDATE messages SET status='deleted',seq=? WHERE account=? AND id NOT IN (SELECT id FROM proton_snapshot WHERE account=?)",
                          [.int(seq), .text(email), .text(email)])
                try s.run("UPDATE accounts SET backfill_done=1,page_token=NULL WHERE email=?", [.text(email)])
                try s.run("DELETE FROM proton_snapshot WHERE account=?", [.text(email)])
            }
        }
        // Bound work per poll. More pages resume on the next poll from the last
        // committed event cursor, including after a process crash or network loss.
        for _ in 0..<5 {
            let page: ProtonEventPage
            do { page = try await remote.events(cursor: cursor!) }
            catch let error as ProtonHelperError where error == .cursorExpired {
                let latest = try await remote.latest()
                try checkProton(email, remote)
                try beginProtonSnapshot(email, cursor: latest)
                return
            }
            try checkProton(email, remote)
            guard !page.cursor.isEmpty, !page.more || page.cursor != cursor else { throw ProtonHelperError.protocolViolation }
            if page.reset {
                let latest = try await remote.latest()
                try checkProton(email, remote)
                try beginProtonSnapshot(email, cursor: latest)
                return
            }
            // Fetch current metadata instead of applying possibly partial flag
            // events. Coalescing preserves the last deletion/create for each ID.
            var changes: [String: Bool] = [:]
            for change in page.changes { changes[change.id] = change.deleted }
            for (id, deleted) in changes.sorted(by: { $0.key < $1.key }) {
                if deleted { try deleteProtonMessage(email, id) }
                else { try await fetchProton(email, id: id, remote: remote) }
            }
            try checkProton(email, remote)
            try s.run("UPDATE accounts SET history_id=? WHERE email=?", [.text(page.cursor), .text(email)])
            cursor = page.cursor
            if !page.more { return }
        }
        trigger(email)
    }

    private func beginProtonSnapshot(_ email: String, cursor: String) throws {
        guard !cursor.isEmpty else { throw ProtonHelperError.protocolViolation }
        let s = try db()
        try s.transaction {
            try s.run("DELETE FROM proton_snapshot WHERE account=?", [.text(email)])
            try s.run("UPDATE accounts SET history_id=?,page_token=NULL,backfill_done=0 WHERE email=?", [.text(cursor), .text(email)])
        }
    }

    private func deleteProtonMessage(_ email: String, _ id: String) throws {
        let seq = try nextSeq()
        try db().run("UPDATE messages SET status='deleted',seq=? WHERE account=? AND id=?", [.int(seq), .text(email), .text(id)])
    }

    private func fetchProton(_ email: String, id: String, remote: any ProtonSyncRemote) async throws {
        do {
            let meta = try await remote.metadata(id: id)
            let body = try await remote.decrypt(id: id)
            try checkProton(email, remote)
            guard meta.id == id else { throw ProtonHelperError.protocolViolation }
            let mime = body.mimeType.lowercased()
            let html: String
            let text: String
            if mime.hasPrefix("multipart/") || mime == "message/rfc822" {
                // PGP/MIME decrypts to a MIME entity with its own headers.
                let parsed = MIME.parse(Data(body.body.utf8))
                html = parsed.html
                text = parsed.text.isEmpty ? Detect.stripTags(html) : parsed.text
            } else {
                html = mime.hasPrefix("text/html") ? body.body : ""
                text = html.isEmpty ? body.body : Detect.stripTags(html)
            }
            try save(Draft(account: email, id: id, threadID: nil, date: meta.time * 1000, subject: meta.subject,
                           name: meta.sender_name, address: meta.sender_email, to: email,
                           snippet: String(text.prefix(200)), labels: meta.mappedLabels, attachments: [], size: meta.size,
                           html: html, text: text, headers: [:], signatureStatus: body.signatureStatus))
        } catch ProtonHelperError.notFound {
            try checkProton(email, remote)
            try deleteProtonMessage(email, id)
        }
    }
}
