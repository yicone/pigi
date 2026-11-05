import Darwin
import Foundation

/// Location of `mail.db`, `translations.db`, `mail-headers.json`, and `agent.sock`.
///
/// The installed app uses `~/Library/Application Support/pigi`. Regression binaries
/// compiled with `-D PIGI_REGRESSION`, and XCTest, refuse that real directory and
/// `~/Library/Containers` before creating anything. Point those processes at a
/// temporary home with `CFFIXED_USER_HOME` (Application Support) and `HOME`
/// (`homeDirectoryForCurrentUser`) instead of substituting a test double for the path code.
public enum AppSupport {
    public enum Failure: Error, Equatable, LocalizedError {
        case realUserData

        public var errorDescription: String? {
            "测试拒绝写入真实用户 Application Support/pigi 或 Containers"
        }
    }

    /// True when this process must not create or modify the logged-in user's app data.
    public static var refusesRealUserData: Bool {
        #if PIGI_REGRESSION
        true
        #else
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["PIGI_REGRESSION"] == "1" { return true }
        return NSClassFromString("XCTestCase") != nil
        #endif
    }

    /// Creates `…/pigi` at mode 0700, after the regression/XCTest guard.
    public static func pigiDirectory() throws -> URL {
        let directory = try resolvedPigiDirectory()
        try assertNotRealUserData(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// Call at the start of a regression that is expected to use the production path.
    public static func assertProcessSupportIsIsolated() throws {
        try assertNotRealUserData(try resolvedPigiDirectory())
    }

    public static func assertNotRealUserData(_ url: URL) throws {
        guard refusesRealUserData else { return }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = passwdHome()
        if home.isEmpty { throw Failure.realUserData }
        let support = (home as NSString).appendingPathComponent("Library/Application Support/pigi")
        let containers = (home as NSString).appendingPathComponent("Library/Containers")
        if path == support || path.hasPrefix(support + "/")
            || path == containers || path.hasPrefix(containers + "/") {
            throw Failure.realUserData
        }
    }

    private static func resolvedPigiDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
            .appendingPathComponent("pigi", isDirectory: true)
    }

    /// Passwd home, ignoring `HOME` and `CFFIXED_USER_HOME`.
    private static func passwdHome() -> String {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let size = sysconf(_SC_GETPW_R_SIZE_MAX)
        let length = size > 0 ? Int(size) : 16_384
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: length)
        defer { buffer.deallocate() }
        guard getpwuid_r(getuid(), &pwd, buffer, length, &result) == 0, let result, let dir = result.pointee.pw_dir else {
            return ""
        }
        return String(cString: dir)
    }
}
