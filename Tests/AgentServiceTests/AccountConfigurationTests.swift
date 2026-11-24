import XCTest
@testable import PigiCore

final class AccountConfigurationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var path: String { directory.appendingPathComponent("Library/Application Support/pigi/mail.db").path }
    private var config: AccountConfiguration { AccountConfiguration(path: path) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        suite = "pigi.config.tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    func testMigrationPreservesRowsAndLegacyValuesWithoutResurrectingDeletedAccounts() throws {
        defaults.set(["Legacy@Example.test", "Legacy@Example.test"], forKey: "gmailAccounts")
        defaults.set(["stale@example.test"], forKey: "imapAccounts")
        defaults.set(" legacy.apps.googleusercontent.com \n", forKey: "gmailClientID")
        try config.setGmailClientID("new.apps.googleusercontent.com")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES('imap@example.test','imap','imap.invalid',993)")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["Legacy@Example.test"])
        XCTAssertEqual(try config.emails(kind: "imap"), ["imap@example.test"])
        XCTAssertEqual(try config.gmailClientID(), "new.apps.googleusercontent.com")
        XCTAssertEqual(try db.query("SELECT imap_host FROM accounts WHERE kind='imap'").first?["imap_host"]?.text, "imap.invalid")
        XCTAssertEqual(defaults.stringArray(forKey: "gmailAccounts"), ["Legacy@Example.test", "Legacy@Example.test"])
        XCTAssertEqual(defaults.string(forKey: "gmailClientID"), " legacy.apps.googleusercontent.com \n")
        try db.run("DELETE FROM accounts WHERE kind='gmail'")
        try config.setGmailClientID("")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), [])
        XCTAssertEqual(try config.gmailClientID(), "")
    }

    func testFreshMigrationImportsClientIDAndIsAtomicAndRetryable() throws {
        defaults.set(["a@example.test", "b@example.test"], forKey: "gmailAccounts")
        defaults.set(" fixture.apps.googleusercontent.com ", forKey: "gmailClientID")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("CREATE TRIGGER reject_account BEFORE INSERT ON accounts WHEN NEW.email='b@example.test' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        XCTAssertThrowsError(try config.migrateLegacy(defaults: defaults))
        XCTAssertEqual(try config.emails(kind: "gmail"), [])
        XCTAssertEqual(try config.gmailClientID(), "")
        try db.run("DROP TRIGGER reject_account")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["a@example.test", "b@example.test"])
        XCTAssertEqual(try config.gmailClientID(), "fixture.apps.googleusercontent.com")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFailedAccountInsertCompensatesCredentialsAndReportsFailedRecovery() throws {
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("CREATE TRIGGER reject_account BEFORE INSERT ON accounts BEGIN SELECT RAISE(ABORT,'fixture'); END")
        for rejectRecovery in [false, true] {
            var token = "old-synthetic"
            var writes = 0
            let credentials = CredentialStore(read: { _ in token }, write: { _, value in
                writes += 1
                if rejectRecovery && writes == 2 { return false }
                token = value
                return true
            })
            XCTAssertThrowsError(try config.addGmail("a@example.test", refreshToken: "new-synthetic", credentials: credentials)) {
                if rejectRecovery { XCTAssertEqual($0 as? CredentialPersistenceError, .recoveryFailed) }
            }
            XCTAssertEqual(writes, 2)
            if !rejectRecovery { XCTAssertEqual(token, "old-synthetic") }
            XCTAssertEqual(try config.emails(kind: "gmail"), [])
        }
    }

    func testIndependentCLIReadsSameConfigurationAndSeesUpdates() throws {
        defaults.set(["gmail@example.test"], forKey: "gmailAccounts")
        defaults.set("fixture.apps.googleusercontent.com", forKey: "gmailClientID")
        try config.migrateLegacy(defaults: defaults)
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES('imap@example.test','imap','imap.invalid',993)")
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/pigi-config")
        func readCLI(useDefault: Bool = false) throws -> [String: Any] {
            let process = Process()
            process.executableURL = executable
            process.arguments = useDefault ? [] : ["--database", path]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = directory.path
            env["CFFIXED_USER_HOME"] = directory.path
            env["PIGI_REGRESSION"] = "1"
            process.environment = env
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let first = try readCLI()
        XCTAssertEqual(first["gmail"] as? [String], ["gmail@example.test"])
        XCTAssertEqual(first["imap"] as? [String], ["imap@example.test"])
        XCTAssertEqual(first["gmailClientID"] as? String, "fixture.apps.googleusercontent.com")
        try config.setGmailClientID("updated.apps.googleusercontent.com")
        try db.run("DELETE FROM accounts WHERE kind='gmail'")
        let next = try readCLI(useDefault: true)
        XCTAssertEqual(next["gmail"] as? [String], [])
        XCTAssertEqual(next["gmailClientID"] as? String, "updated.apps.googleusercontent.com")
    }

    func testUnreadableConfigurationThrowsWithoutTouchingCredentials() throws {
        let invalid = AccountConfiguration(path: directory.appendingPathComponent("missing/mail.db").path)
        var reads = 0
        var writes = 0
        let credentials = CredentialStore(read: { _ in reads += 1; return nil }, write: { _, _ in writes += 1; return true })
        XCTAssertThrowsError(try invalid.addGmail("a@example.test", refreshToken: "synthetic", credentials: credentials))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(writes, 0)
    }
}
