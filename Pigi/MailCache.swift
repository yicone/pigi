import Foundation
#if canImport(PigiCore)
import PigiCore
#endif

/// Mail headers kept on disk so a launch only has to ask the servers about what is new.
/// Bodies are not stored; they are fetched when a mail is opened.
enum MailCache {
    private static func url() throws -> URL {
        let folder = try AppSupport.pigiDirectory()
        let file = folder.appendingPathComponent("mail-headers.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return file
    }

    static func load() -> [Mail] {
        guard let url = try? url(), let data = try? Data(contentsOf: url),
              let mails = try? JSONDecoder().decode([Mail].self, from: data) else { return [] }
        return mails
    }

    static func save(_ mails: [Mail]) {
        try? saveChecked(mails)
    }

    /// Used by account removal, where silent persistence failure could leave
    /// headers from a removed mailbox on disk.
    static func saveChecked(_ mails: [Mail]) throws {
        let url = try url()
        let slim = mails.map { mail -> Mail in
            var mail = mail
            mail.body = ""
            mail.bodyLoaded = false
            return mail
        }
        do {
            let data = try JSONEncoder().encode(slim)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Never retain the previous account's headers after a failed rewrite.
            do { try FileManager.default.removeItem(at: url) }
            catch { throw ArchiveClient.Failure(message: "邮件头缓存写入及旧缓存清理失败，请检查磁盘权限") }
            throw ArchiveClient.Failure(message: "邮件头缓存写入失败，旧缓存已清除")
        }
    }

    static func clear() {
        if let url = try? url() { try? FileManager.default.removeItem(at: url) }
    }
}
