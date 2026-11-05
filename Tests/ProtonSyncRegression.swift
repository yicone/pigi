import AppKit
import SwiftUI

#if !CACHE_DISK_REGRESSION
enum MailCache {
    static func load() -> [Mail] { [] }
    static func save(_ mails: [Mail]) {}
    static func saveChecked(_ mails: [Mail]) throws {}
    static func clear() {}
}
#endif
enum Keychain {
    private static var values: [String: String] = [:]
    private static let lock = NSLock()
    private static var rejectingWrites = false
    static func rejectWrites(_ reject: Bool) { lock.lock(); defer { lock.unlock() }; rejectingWrites = reject }
    static func warm() throws {}
    static func get(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    @discardableResult static func set(_ key: String, _ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rejectingWrites else { return false }
        values[key] = value.isEmpty ? nil : value
        return true
    }
    static func translationAPIKey() throws -> String? { try get("translation-api-key") }
    @discardableResult static func setTranslationAPIKey(_ value: String) -> Bool { set("translation-api-key", value) }
}
@MainActor enum MainWindow { static func show() {} }

actor FixtureProton: ProtonSyncRemote {
    var snapshotPages = ["": ["one", "two"], "two": [String]()]
    var rows: [String: ProtonSyncMetadata] = [:]
    var bodies: [String: ProtonMessageBody] = [:]
    var pages: [String: ProtonEventPage] = [:]
    var failing: String?
    var failureCode: ProtonHelperError = .key
    var latestID = "c0"
    var eventError: ProtonHelperError?
    var latestCalls = 0
    var snapshotCalls = 0
    func latest() async throws -> String { latestCalls += 1; return latestID }
    func labels() async throws -> [ProtonLabel] { [ProtonLabel(id: "custom", name: "Work", parent: "parent", type: 3)] }
    func snapshot(after: String) async throws -> [String] { snapshotCalls += 1; return snapshotPages[after] ?? [] }
    func metadata(id: String) async throws -> ProtonSyncMetadata {
        guard let row = rows[id] else { throw ProtonHelperError.notFound }
        return row
    }
    func decrypt(id: String) async throws -> ProtonMessageBody {
        if id == failing { throw failureCode }
        guard let body = bodies[id] else { throw ProtonHelperError.notFound }
        return body
    }
    func events(cursor: String) async throws -> ProtonEventPage {
        if let eventError { throw eventError }
        return pages[cursor] ?? ProtonEventPage(cursor: cursor, more: false, reset: false, changes: [])
    }
    func failEvents(_ code: ProtonHelperError?) { eventError = code }
    func callCounts() -> (Int, Int) { (latestCalls, snapshotCalls) }
    func put(_ id: String, unread: Bool = true, labels: [String] = ["0", "5", "custom"], text: String = "fixture plaintext", html: Bool = false, signature: String? = nil) {
        rows[id] = ProtonSyncMetadata(id: id, subject: "Fixture \(id)", time: Int(Date().timeIntervalSince1970), unread: unread,
                                     sender_name: "Fixture sender", sender_email: "sender@example.test", labels: labels, size: 42)
        bodies[id] = ProtonMessageBody(body: text, mimeType: html ? "text/html" : "text/plain", signatureStatus: signature)
    }
    func mimeBody(_ id: String, body: String) { bodies[id] = ProtonMessageBody(body: body, mimeType: "multipart/mixed") }
    func failure(_ id: String?, code: ProtonHelperError = .key) { failing = id; failureCode = code }
    func event(_ cursor: String, next: String, changes: [(String, Bool)], reset: Bool = false, more: Bool = false) {
        pages[cursor] = ProtonEventPage(cursor: next, more: more, reset: reset, changes: changes.map { .init(id: $0.0, deleted: $0.1) })
    }
    func rescan(_ ids: [String], latest: String) { snapshotPages = ["": ids, ids.last ?? "last": []]; latestID = latest }
}

extension LocalEngine {
    func fixture(_ email: String, remote: any ProtonSyncRemote) throws {
        if store == nil {
            store = try Store(path: ":memory:")
            for statement in Self.schema { try store!.run(statement) }
        }
        try db().run("INSERT OR IGNORE INTO accounts(email,kind) VALUES(?,'proton')", [.text(email)])
        protonSessions[email] = remote
    }
    func inspect(_ sql: String) throws -> [SQLRow] { try db().query(sql) }
    func cursor(_ email: String) throws -> String? { try account(email)?["history_id"]?.text }
    func offset(_ email: String) throws -> String? { try account(email)?["page_token"]?.text }
    func sequence() throws -> Int { try currentSeq() }
}

@main @MainActor struct ProtonSyncRegression {
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) { fputs("FAIL: Proton sync timeout\n", stderr); _exit(124) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain([
            "gmailAccounts": [String](), "imapAccounts": [String](), "protonAccounts": ["fixture@example.test"],
            "hiddenAccounts": [String](), "sidebarGroups": Data(),
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        #if CACHE_DISK_REGRESSION
        try await diskPrivacyCases()
        #else
        try await credentialFailureCases()
        try await eventRecoveryCases()
        let email = "fixture@example.test", other = "other@example.test"
        let engine = LocalEngine(), remote = FixtureProton()
        await remote.put("one", signature: "verified")
        await remote.put("two", text: "<p>HTML fixture</p>", html: true, signature: "failed")
        try await engine.fixture(email, remote: remote)
        try await engine.pullProton(email, remote: remote)
        let initialCursor = try await engine.cursor(email), initialOffset = try await engine.offset(email)
        precondition(initialCursor == "c0" && initialOffset == "two")
        let plain = try await engine.body(account: email, id: "one"), html = try await engine.body(account: email, id: "two")
        precondition(plain.signatureStatus == "verified" && html.signatureStatus == "failed")
        precondition(plain.text == "fixture plaintext" && html.html == "<p>HTML fixture</p>")
        let labels = try await engine.protonLabels(email)
        precondition(labels.first?.name == "Work" && labels.first?.parent == "parent" && labels.first?.type == 3)
        let initialRows = try await engine.inspect("SELECT * FROM messages")
        precondition(initialRows.count == 2 && initialRows.allSatisfy { $0["unread"]?.int == 1 })
        precondition(initialRows.allSatisfy { $0["labels"]?.text?.contains("proton:custom") == true })
        print("PASS: snapshot, label/folder mapping, local plaintext/HTML and unread preservation")

        try await engine.pullProton(email, remote: remote)
        let seq = try await engine.sequence()
        try await engine.pullProton(email, remote: remote)
        let repeated = try await engine.sequence()
        precondition(seq == repeated)
        print("PASS: repeated empty incremental polls are idempotent")

        await remote.put("one", unread: false, labels: ["6", "5", "10"], text: "replacement searchable body")
        await remote.put("three")
        await remote.event("c0", next: "c1", changes: [("one", false), ("three", false), ("two", true)])
        for code: ProtonHelperError in [.key, .keyMissing, .keyFormat, .keyDecryption, .network, .timeout, .rateLimited, .proxy, .apiVersion, .humanVerificationRequired] {
            await remote.failure("three", code: code)
            do { try await engine.pullProton(email, remote: remote); fatalError("failure swallowed") }
            catch let error as ProtonHelperError { precondition(error == code) }
            let failedCursor = try await engine.cursor(email)
            precondition(failedCursor == "c0")
        }
        await remote.failure(nil)
        try await engine.pullProton(email, remote: remote)
        let updatedCursor = try await engine.cursor(email)
        precondition(updatedCursor == "c1")
        let rows = try await engine.inspect("SELECT * FROM messages ORDER BY id")
        precondition(rows.count == 3 && rows.first?["unread"]?.int == 0 && rows.first?["starred"]?.int == 1)
        precondition(rows.first?["status"]?.text == "archived" && rows.last?["status"]?.text == "deleted")
        let updatedBody = try await engine.body(account: email, id: "one")
        precondition(updatedBody.text == "replacement searchable body")
        let hits = try await engine.search("replacement", account: email)
        precondition(hits.count == 1)
        let fts = try await engine.inspect("SELECT count(*) AS n FROM fts")
        precondition(fts.first?["n"]?.int == 3)
        print("PASS: cursor stays on failure; replay updates body/FTS/flags and deletion without duplicates")

        let distinctErrors: [ProtonHelperError] = [.keyMissing, .keyFormat, .keyDecryption, .network, .timeout, .rateLimited, .proxy, .apiVersion]
        precondition(Set(distinctErrors.map { $0.localizedDescription }).count == distinctErrors.count)
        let privacy = try await engine.inspect("PRAGMA secure_delete")
        precondition(privacy.first?["secure_delete"]?.int == 1)
        let otherRemote = FixtureProton()
        await otherRemote.put("one", text: "isolated account")
        await otherRemote.rescan(["one"], latest: "o0")
        try await engine.fixture(other, remote: otherRemote)
        try await engine.pullProton(other, remote: otherRemote)
        let otherBody = try await engine.body(account: other, id: "one")
        precondition(otherBody.text == "isolated account")
        print("PASS: identical remote IDs remain isolated across accounts")

        await remote.event("c1", next: "expired", changes: [], reset: true)
        await remote.rescan(["three"], latest: "fresh")
        try await engine.pullProton(email, remote: remote)
        try await engine.pullProton(email, remote: remote)
        try await engine.pullProton(email, remote: remote)
        let fresh = try await engine.cursor(email)
        precondition(fresh == "fresh")
        let rescanned = try await engine.inspect("SELECT id,status FROM messages WHERE account='fixture@example.test' ORDER BY id")
        precondition(rescanned.first?["status"]?.text == "deleted")
        let preservedOther = try await engine.body(account: other, id: "one")
        precondition(preservedOther.text == "isolated account")
        let deletedHits = try await engine.search("replacement", account: email)
        precondition(deletedHits.isEmpty)
        print("PASS: expired event reset rebuilds snapshot and reconciles vanished mail per account")

        for operation in 0..<3 {
            do {
                switch operation {
                case 0: try await engine.modify(account: email, ids: ["three"], add: [], remove: ["UNREAD"])
                case 1: _ = try await engine.unsubscribe(account: email, id: "three")
                default: try await engine.mute(account: email, sender: "sender@example.test", id: "three")
                }
                fatalError("Proton write allowed")
            } catch let error as ArchiveClient.Failure { precondition(error.message.contains("只读")) }
        }
        let muted = try await engine.inspect("SELECT count(*) AS n FROM muted")
        precondition(muted.first?["n"]?.int == 0)
        print("PASS: engine rejects modify, unsubscribe and mute before side effects")

        try await engine.deleteAccount(other)
        for table in ["accounts", "messages", "attachments", "account_labels", "proton_snapshot", "muted"] {
            let column = table == "accounts" ? "email" : "account"
            let remaining = try await engine.inspect("SELECT count(*) AS n FROM \(table) WHERE \(column)='other@example.test'")
            precondition(remaining.first?["n"]?.int == 0)
        }
        let removedSearch = try await engine.search("isolated", account: other)
        precondition(removedSearch.isEmpty)
        let keptBody = try await engine.body(account: email, id: "three")
        precondition(!keptBody.text.isEmpty)
        print("PASS: cache deletion removes account tables and search while preserving another account")
        let state = AppState()
        var mail = fixtureMail()
        state.mails = [mail]
        state.open(mail)
        state.toggleUnread(mail.id)
        state.toggleStar(mail.id)
        state.archive(mail.id)
        state.delete(mail.id)
        state.markAllRead()
        precondition(state.mails.count == 1 && state.mails[0].isUnread && !state.mails[0].isStarred)
        precondition(state.accounts(of: .proton).count == 1 && state.sidebarGroups.contains { $0.id == AccountGroup.protonID })
        state.select(.account(email))
        state.selectedProtonLabel = "proton:custom"
        precondition(state.visibleMails.count == 1)
        state.selectedProtonLabel = "SPAM"
        precondition(state.visibleMails.isEmpty)
        mail.labels = ["SPAM"]
        state.mails = [mail]
        precondition(state.visibleMails.count == 1)
        precondition(state.unreadTotal == 0 && state.unreadCount(.account(email)) == 0)
        state.select(.all)
        precondition(state.visibleMails.isEmpty)
        print("PASS: Proton UI open/actions preserve state; account group and label filtering work")

        // Remove a live account; a stale in-flight task must not resurrect it.
        try await engine.deleteAccount(email)
        do { try await engine.pullProton(email, remote: remote); fatalError("deleted account resumed") }
        catch is CancellationError {}
        let remaining = try await engine.accounts()
        precondition(remaining.isEmpty)
        print("PASS: removal clears local labels/mail and stale sync cannot resurrect account")
        let mimeEngine = LocalEngine(), mimeRemote = FixtureProton()
        await mimeRemote.put("one")
        await mimeRemote.put("two")
        await mimeRemote.mimeBody("one", body: """
        Content-Type: multipart/alternative; boundary="fixture-boundary"

        --fixture-boundary
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        c3ludGhldGljIE1JTUUgdGV4dA==
        --fixture-boundary
        Content-Type: text/html; charset=utf-8

        <p>synthetic MIME HTML</p>
        --fixture-boundary--
        """)
        try await mimeEngine.fixture(email, remote: mimeRemote)
        try await mimeEngine.pullProton(email, remote: mimeRemote)
        let mimeBody = try await mimeEngine.body(account: email, id: "one")
        precondition(mimeBody.text == "synthetic MIME text" && mimeBody.html == "<p>synthetic MIME HTML</p>")
        print("PASS: decrypted PGP/MIME maps decoded plaintext and HTML through the existing MIME parser")
        try await sessionPersistence()
        if CommandLine.arguments.count > 1 { try renderEvidence(state, to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        #endif
    }

    static func sessionPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proton-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("helper")
        let source = """
        #!/usr/bin/python3
        import json,sys
        for line in sys.stdin:
            r=json.loads(line)
            if r['method']=='hello':
                result={'protocol':1,'helper_version':'fixture','max_frame_bytes':8388608,'methods':['login','list','decrypt','logout','session']}
            elif r['method']=='session':
                result={'uid':'synthetic-uid','access':'synthetic-access','refresh':'synthetic-refresh','salted':'c3ludGhldGlj','email':'fixture@example.test'}
            elif r['method']=='resume':
                result={'authenticated':True}
            elif r['method']=='latest':
                result={'cursor':'fixture-cursor'}
            elif r['method']=='labels':
                result=[]
            else:
                result={'logged_out':True}
            print(json.dumps({'version':1,'id':r['id'],'result':result}),flush=True)
        """
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ProtonHelperClient(executable: executable)
        let session = ProtonSession(client: client, email: "fixture@example.test")
        try await session.saveSecret()
        let key = ProtonSession.key("fixture@example.test")
        let savedSecret = try Keychain.get(key)
        precondition(savedSecret?.contains("synthetic-refresh") == true)
        Keychain.rejectWrites(true)
        do { try await session.saveSecret(); fatalError("failed save was hidden") }
        catch CredentialPersistenceError.writeFailed {}
        do { _ = try await session.latest(); fatalError("failed request save was hidden") }
        catch CredentialPersistenceError.recoveryFailed {}
        let resumed = ProtonSession(client: client, email: "fixture@example.test",
                                    initialSecret: .init(uid: "synthetic", access: "synthetic", refresh: "synthetic", salted: "synthetic", email: "fixture@example.test"))
        do { try await resumed.resume(); fatalError("failed resume save was hidden") }
        catch CredentialPersistenceError.recoveryFailed {}
        let engine = LocalEngine()
        try await engine.fixture("fixture@example.test", remote: session)
        let delay = await engine.syncProton("fixture@example.test")
        let account = try await engine.accounts().first
        let cached = await engine.protonSessions["fixture@example.test"]
        precondition(delay == 120 && cached == nil)
        precondition(account?.lastError == CredentialPersistenceError.recoveryFailed.localizedDescription)
        let state = AppState()
        state.updateCredentialErrors(from: account.map { [$0] } ?? [])
        precondition(state.sidebarError == account?.lastError && state.displayedCredentialError == account?.lastError)
        Keychain.rejectWrites(false)
        print("PASS: Proton save, request, resume and background sync surface failed writes and failed recovery saves")
        session.deactivate()
        Keychain.set(key, "new session")
        try await session.saveSecret()
        let replacedSecret = try Keychain.get(key)
        precondition(replacedSecret == "new session")
        Keychain.set(key, "")
        try await session.saveSecret()
        let removedSecret = try Keychain.get(key)
        precondition(removedSecret == nil)
        let mismatch = ProtonSession(client: client, email: "other@example.test")
        do { try await mismatch.saveSecret(); fatalError("cross-account session persisted") }
        catch ProtonHelperError.credentials {}
        try await client.logout()
        print("PASS: pipe session export persists only to the fixture Keychain; deactivated sessions cannot overwrite or resurrect secrets")
    }

    static func credentialFailureCases() async throws {
        let state = AppState()
        let before = GmailStore.emails
        Keychain.rejectWrites(true)
        defer { Keychain.rejectWrites(false) }
        await state.addGmailAccount(signIn: {
            ("credential-fixture@example.test", GmailAuth.Token(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: .distantFuture))
        })
        let message = CredentialPersistenceError.writeFailed.localizedDescription
        precondition(GmailStore.emails == before && state.gmailAccounts.isEmpty)
        precondition(state.displayedCredentialError == message && state.sidebarError == message)
        state.syncError = nil
        precondition(state.sidebarError == message, "refresh erased the credential failure")
        do {
            try await state.reportCredentialFailure { throw CredentialPersistenceError.recoveryFailed }
            fatalError("credential error was not rethrown to the settings sheet")
        } catch CredentialPersistenceError.recoveryFailed {}
        precondition(state.displayedCredentialError == CredentialPersistenceError.recoveryFailed.localizedDescription)
        precondition(state.sidebarError == state.displayedCredentialError)
        try await state.reportCredentialFailure {}
        precondition(state.displayedCredentialError == nil && state.sidebarError == nil, "successful recovery kept a stale error")
        let account = ArchiveAccount(email: "credential-fixture@example.test", backfillDone: 1, total: 0,
                                     lastSync: nil, lastError: message, stored: 0, kind: "proton")
        state.updateCredentialErrors(from: [account])
        precondition(state.displayedCredentialError == message && state.sidebarError == message)
        state.updateCredentialErrors(from: [])
        precondition(state.displayedCredentialError == nil)
        print("PASS: failed Gmail save never adds an account; settings and sidebar retain redacted credential failures until recovery")
    }

    // Go's loopback tests establish HTTP -> wire classification; here exercise
    // the real sync catch/state/presentation path rather than failing a body fetch.
    static func eventRecoveryCases() async throws {
        let engine = LocalEngine(), remote = FixtureProton(), email = "events@example.test"
        await remote.rescan([], latest: "c0")
        try await engine.fixture(email, remote: remote)
        try await engine.pullProton(email, remote: remote)
        let baseline = await remote.callCounts()
        let sequence = try await engine.sequence()
        for code: ProtonHelperError in [.apiVersion, .humanVerificationRequired, .upstream, .notFound] {
            await remote.failEvents(code)
            let delay = await engine.syncProton(email)
            let cursor = try await engine.cursor(email)
            let counts = await remote.callCounts()
            let account = try await engine.inspect("SELECT backfill_done,page_token,last_error FROM accounts WHERE email='events@example.test'").first!
            let afterSequence = try await engine.sequence()
            precondition(delay == 120 && cursor == "c0" && account["backfill_done"]?.int == 1)
            precondition(account["page_token"]?.text == nil && afterSequence == sequence)
            precondition(counts == baseline, "event failure incorrectly sampled latest or started a snapshot")
            precondition(account["last_error"]?.text == code.localizedDescription)
        }
        precondition(ProtonHelperError.apiVersion.localizedDescription != ProtonHelperError.humanVerificationRequired.localizedDescription)
        print("PASS: events version/HV/upstream/404 failures retain cursor and distinct safe hints without snapshot/latest calls")

        await remote.failEvents(nil)
        await remote.event("c0", next: "fresh", changes: [], reset: true)
        await remote.rescan([], latest: "fresh")
        try await engine.pullProton(email, remote: remote)
        let resetCursor = try await engine.cursor(email)
        let resetAccount = try await engine.inspect("SELECT backfill_done FROM accounts WHERE email='events@example.test'").first!
        let resetCounts = await remote.callCounts()
        precondition(resetCursor == "fresh" && resetAccount["backfill_done"]?.int == 0)
        precondition(resetCounts.0 == baseline.0 + 1 && resetCounts.1 == baseline.1)
        try await engine.pullProton(email, remote: remote)
        let complete = try await engine.inspect("SELECT backfill_done FROM accounts WHERE email='events@example.test'").first!
        let completeCounts = await remote.callCounts()
        precondition(complete["backfill_done"]?.int == 1 && completeCounts.1 == baseline.1 + 1)
        print("PASS: explicit invalidated-state reset alone rebases cursor and rebuilds snapshot")
    }

    static func renderEvidence(_ state: AppState, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws {
            let hosting = NSHostingView(rootView: view.frame(width: width, height: height).background(Color.white).foregroundStyle(Color.black).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            hosting.frame = window.contentView!.bounds
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("no bitmap") }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no PNG") }
            try data.write(to: directory.appendingPathComponent(name))
            window.close()
        }
        try capture(AddProtonSheet().environment(state), "proton-login.png", width: 460, height: 360)
        state.credentialError = CredentialPersistenceError.writeFailed.localizedDescription
        try capture(AccountsPage().environment(state), "credential-settings.png", width: 600, height: 600)
        let layout = LayoutState()
        layout.sidebarWidth = 250
        try capture(SidebarView().environment(state).environment(layout), "credential-sidebar.png", width: 250, height: 600)
        state.credentialError = nil
        state.mails = [fixtureMail()]
        state.select(.account("fixture@example.test"))
        try capture(MailListView().environment(state), "proton-inbox.png", width: 480, height: 500)
        try capture(MailDetailContent(mail: fixtureMail()).environment(state), "proton-signature.png", width: 900, height: 500)
        for status in ["verified", "failed", "unverified"] {
            var mail = fixtureMail()
            mail.signatureStatus = status
            try capture(MailDetailContent(mail: mail).environment(state), "proton-signature-\(status).png", width: 900, height: 500)
        }
        print("PASS: synthetic Proton login, inbox and all signature states UI rendered")
    }

    static func fixtureMail() -> Mail {
        Mail(id: "fixture@example.test#three", accountID: "fixture@example.test", remoteID: "three", senderName: "Fixture", senderEmail: "sender@example.test",
             subject: "Fixture", snippet: "", body: "", date: Date(), isUnread: true, isStarred: false, bodyLoaded: true, isHTML: false,
             labels: ["INBOX", "ALL", "proton:custom"])
    }
}
