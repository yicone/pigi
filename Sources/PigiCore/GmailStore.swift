import Foundation

/// Which Gmail accounts are signed in. Emails live in UserDefaults, refresh
/// tokens in the Keychain.
public enum GmailStore {
    private static let defaultsKey = "gmailAccounts"

    public static func keychainKey(_ email: String) -> String { "gmail-refresh-\(email)" }

    public static var emails: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    public static func add(_ email: String, refreshToken: String) {
        Keychain.set(keychainKey(email), refreshToken)
        var list = emails
        if !list.contains(email) { list.append(email) }
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }

    public static func remove(_ email: String) {
        Keychain.set(keychainKey(email), "")
        UserDefaults.standard.set(emails.filter { $0 != email }, forKey: defaultsKey)
    }
}
