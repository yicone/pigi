import Foundation
#if canImport(PigiCore)
import PigiCore
#endif

/// Local mail window: how far back mail is kept on this Mac, and the sync cursor into the engine.
enum ArchiveSettings {
    /// How far back mail is kept on this Mac.
    static var windowDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "archiveWindowDays")
            return stored > 0 ? stored : 30
        }
        set { UserDefaults.standard.set(max(newValue, 1), forKey: "archiveWindowDays") }
    }
    /// Last change number pulled, and the window it was pulled for.
    static var cursor: Int {
        get { UserDefaults.standard.integer(forKey: "archiveCursor") }
        set { UserDefaults.standard.set(newValue, forKey: "archiveCursor") }
    }
    static var cursorWindow: Int {
        get { UserDefaults.standard.integer(forKey: "archiveCursorWindow") }
        set { UserDefaults.standard.set(newValue, forKey: "archiveCursorWindow") }
    }
    /// Bumped when the archive items gain fields, so one full pull refreshes what is cached.
    static let schema = 3
    static var cursorSchema: Int {
        get { UserDefaults.standard.integer(forKey: "archiveCursorSchema") }
        set { UserDefaults.standard.set(newValue, forKey: "archiveCursorSchema") }
    }
    static var isConfigured: Bool { true }
}

extension ArchiveItem {
    var mail: Mail {
        let name = (fromName?.isEmpty == false ? fromName : fromEmail) ?? ""
        return Mail(
            id: "\(account)#\(id)",
            accountID: account,
            remoteID: id,
            senderName: name,
            senderEmail: fromEmail ?? "",
            subject: (subject?.isEmpty == false ? subject : nil) ?? "(无主题)",
            snippet: RemoteMapping.plainText(snippet ?? ""),
            body: "",
            date: Date(timeIntervalSince1970: Double(date) / 1000),
            isUnread: unread != 0,
            isStarred: starred != 0,
            bodyLoaded: false,
            isHTML: false,
            code: code,
            unsubKind: unsubKind
        )
    }
}
