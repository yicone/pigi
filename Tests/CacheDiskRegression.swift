import Foundation

// Compiled with the real AppState/MailCache/ArchiveClient/LocalEngine/Store.
// Only Keychain and MainWindow are replaced; no credentials or server requests.
extension ProtonSyncRegression {
    static func diskPrivacyCases() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        precondition(support.path.hasPrefix(home.path + "/"), "refusing non-isolated application support")
        let directory = support.appendingPathComponent("pigi")
        let path = directory.appendingPathComponent("mail.db").path
        let header = directory.appendingPathComponent("mail-headers.json")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep a second connection open so existing WAL/SHM survive reopening.
        let existing = try Store(path: path)
        for statement in LocalEngine.schema { try existing.run(statement) }
        try existing.run("CREATE TABLE IF NOT EXISTS disk_fixture(data BLOB)")
        try existing.run("INSERT INTO disk_fixture VALUES(?)", [.blob(Data(repeating: 42, count: 4096))])
        for file in [path, path + "-wal", path + "-shm"] {
            precondition(fm.fileExists(atPath: file), "missing WAL fixture")
            try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let engine = LocalEngine.shared
        _ = try await engine.inspect("SELECT count(*) FROM disk_fixture") // actual db() migration
        func mode(_ path: String) throws -> Int {
            (try fm.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue & 0o777
        }
        let directoryMode = try mode(directory.path)
        precondition(directoryMode == 0o700)
        for file in [path, path + "-wal", path + "-shm"] { let permissions = try mode(file); precondition(permissions == 0o600) }
        let pageCount = try existing.query("PRAGMA page_count").first!["page_count"]!.int!
        try existing.run("PRAGMA max_page_count=\(pageCount)")
        do {
            try existing.transaction { try existing.run("INSERT INTO disk_fixture VALUES(?)", [.blob(Data(repeating: 1, count: 4 * 1024 * 1024))]) }
            fatalError("SQLITE_FULL write swallowed")
        } catch is SQLError {}
        let committed = try existing.query("SELECT count(*) AS n FROM disk_fixture").first!["n"]!.int!
        precondition(committed == 1)
        print("PASS: real SQLite page-capacity write failure rolls back without partial insertion")
        print("PASS: production db() migrates existing directory, DB, WAL and SHM permissions on isolated disk")

        let email = "fixture@example.test", other = "other@example.test"
        let remote = FixtureProton(), second = FixtureProton()
        await remote.put("one", text: "synthetic_deleted_body")
        await remote.rescan(["one"], latest: "c0")
        await second.put("one", text: "synthetic_retained_body")
        await second.rescan(["one"], latest: "o0")
        try await engine.fixture(email, remote: remote)
        try await engine.fixture(other, remote: second)
        try await engine.pullProton(email, remote: remote)
        try await engine.pullProton(other, remote: second)
        UserDefaults.standard.setVolatileDomain([
            "gmailAccounts": [String](), "imapAccounts": [String](),
            "protonAccounts": [email, other], "hiddenAccounts": [String]()
        ], forName: UserDefaults.argumentDomain)
        let state = AppState()
        var firstMail = fixtureMail(); firstMail.body = "synthetic_body_never_in_headers"
        let otherMail = Mail(id: other + "#one", accountID: other, remoteID: "one", senderName: "Fixture", senderEmail: "sender@example.test", subject: "Fixture", snippet: "", body: "", date: Date(), isUnread: true, isStarred: false, bodyLoaded: true, isHTML: false)
        state.mails = [firstMail, otherMail]
        try MailCache.saveChecked(state.mails)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: header.path)
        _ = MailCache.load()
        let headerMode = try mode(header.path)
        precondition(headerMode == 0o600)
        let encoded = try String(contentsOf: header, encoding: .utf8)
        precondition(!encoded.contains("synthetic_body_never_in_headers"))

        // Real SQLITE_READONLY error through the app removal path must propagate.
        _ = try await engine.inspect("PRAGMA query_only=ON")
        do { try await state.removeAccount(email); fatalError("DB write failure swallowed") }
        catch is SQLError {}
        precondition(state.mails.count == 2 && MailCache.load().count == 2)
        let intact = try await engine.inspect("SELECT count(*) AS n FROM accounts")
        precondition(intact.first?["n"]?.int == 2)
        _ = try await engine.inspect("PRAGMA query_only=OFF")
        try await state.removeAccount(email)
        precondition(state.mails.count == 1 && MailCache.load().map(\.accountID) == [other])
        for table in ["accounts", "messages", "attachments", "fts", "muted", "account_labels", "proton_snapshot"] {
            let rows: [SQLRow]
            if table == "fts" { rows = try await engine.inspect("SELECT count(*) AS n FROM fts WHERE body LIKE '%synthetic_deleted_body%'") }
            else { rows = try await engine.inspect("SELECT count(*) AS n FROM \(table) WHERE \(table == "accounts" ? "email" : "account")='fixture@example.test'") }
            precondition(rows.first?["n"]?.int == 0)
        }
        let retained = try await engine.body(account: other, id: "one")
        precondition(retained.text == "synthetic_retained_body")
        print("PASS: actual AppState -> ArchiveClient -> disk DB -> header rewrite deletion; readonly SQL failure propagates without partial DB deletion")

        // A directory at the JSON target produces a real filesystem write error.
        try fm.removeItem(at: header)
        try fm.createDirectory(at: header, withIntermediateDirectories: false)
        do { try await state.removeAccount(other); fatalError("app cache I/O failure swallowed") }
        catch let error as ArchiveClient.Failure { precondition(error.message.contains("缓存")) }
        precondition(!fm.fileExists(atPath: header.path), "failed rewrite retained old cache target")
        precondition(state.mails.isEmpty)
        let noAccounts = try await engine.accounts()
        precondition(noAccounts.isEmpty)
        try MailCache.saveChecked(state.mails)
        precondition(MailCache.load().isEmpty)
        print("PASS: app deletion reports real header-cache write failure, removes stale target and allows empty-cache recovery")
    }
}
