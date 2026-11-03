import Foundation

enum AccountKind: String, CaseIterable, Identifiable {
    case gmail
    case imap
    case proton

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .imap: "IMAP"
        case .proton: "Proton（只读）"
        }
    }
}

struct Account: Identifiable, Hashable {
    /// The mailbox address, which is also the stable identifier.
    let id: String
    var name: String
    var kind: AccountKind
    var avatarURL: URL?

    var email: String { id }
}

struct Mail: Identifiable, Hashable, Codable {
    /// "<account>#<remote id>", unique across every mailbox.
    let id: String
    let accountID: String
    /// The id the backend knows this mail by.
    let remoteID: String
    var senderName: String
    var senderEmail: String
    var subject: String
    var snippet: String
    var body: String
    var date: Date
    var isUnread: Bool
    var isStarred: Bool
    /// List endpoints only return a snippet; the body is fetched on open.
    var bodyLoaded: Bool
    var isHTML: Bool
    /// Verification code found in the mail (found by the engine), if any.
    var code: String? = nil
    /// How the mail can be unsubscribed from: one_click, link or mailto; nil when it cannot.
    var unsubKind: String? = nil
    var labels: [String]? = nil
    var signatureStatus: String? = nil
}

/// What the sidebar has selected: every mailbox merged, or a single one.
enum Scope: Hashable {
    case all
    case account(String)
}

enum ReadFilter: String, CaseIterable, Identifiable {
    case all
    case unread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        }
    }
}

struct MailSection: Identifiable {
    let title: String
    let mails: [Mail]
    var id: String { title }
}
