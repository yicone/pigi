import Foundation

/// Which Gmail accounts are signed in. Emails live in UserDefaults.
/// Refresh tokens live in the shared `vault-v1` keychain item.
public enum GmailStore {
    private static let defaultsKey = "gmailAccounts"

    public static func keychainKey(_ email: String) -> String { "gmail-refresh-\(email)" }

    public static var emails: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    public static func add(_ email: String, refreshToken: String) throws {
        try add(email, refreshToken: refreshToken, defaults: .standard, credentials: CredentialStore())
    }

    static func add(_ email: String, refreshToken: String, defaults: UserDefaults, credentials: CredentialStore) throws {
        try credentials.save(keychainKey(email), refreshToken)
        var list = defaults.stringArray(forKey: defaultsKey) ?? []
        if !list.contains(email) { list.append(email) }
        defaults.set(list, forKey: defaultsKey)
    }

    /// Replaces the refresh token of a mailbox that is already signed in.
    /// Returns false when the mailbox is unknown so it can never create an account.
    public static func replaceRefreshToken(_ token: String, for email: String) -> Bool {
        guard emails.contains(email) else { return false }
        return Keychain.set(keychainKey(email), token)
    }

    /// Two addresses name the same mailbox when they match ignoring case and whitespace.
    public static func isSameMailbox(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public enum ReauthorizationResult: Equatable { case replaced, differentMailbox, noRefreshToken, unknownMailbox, keychainFailed }

    /// Applies a finished Google sign-in to an existing mailbox. Nothing is written
    /// unless the authorized address matches and Google returned a refresh token.
    public static func applyReauthorization(authorizedEmail: String, refreshToken: String?, for email: String) -> ReauthorizationResult {
        guard isSameMailbox(authorizedEmail, email) else { return .differentMailbox }
        guard let refreshToken else { return .noRefreshToken }
        guard emails.contains(email) else { return .unknownMailbox }
        return replaceRefreshToken(refreshToken, for: email) ? .replaced : .keychainFailed
    }

    public static func remove(_ email: String) {
        _ = Keychain.set(keychainKey(email), "")
        UserDefaults.standard.set(emails.filter { $0 != email }, forKey: defaultsKey)
    }
}
