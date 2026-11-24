import Foundation

/// Gmail registrations share the engine's SQLite accounts table.
/// Refresh tokens remain exclusively in the keychain vault.
public enum GmailStore {
    public static func keychainKey(_ email: String) -> String { "gmail-refresh-\(email)" }

    public static func refreshToken(for email: String) throws -> String {
        try AccountConfiguration.shared.refreshToken(for: email, credentials: CredentialStore())
    }

    public static var emails: [String] {
        (try? AccountConfiguration.shared.emails(kind: "gmail")) ?? []
    }

    public static func add(_ email: String, refreshToken: String) throws {
        try AccountConfiguration.shared.addGmail(email, refreshToken: refreshToken, credentials: CredentialStore())
    }

    /// Replaces the refresh token of a mailbox that is already signed in.
    /// Returns false when the mailbox is unknown so it can never create an account.
    public static func replaceRefreshToken(_ token: String, for email: String) -> Bool {
        guard emails.contains(email) else { return false }
        do { try AccountConfiguration.shared.replaceRefreshToken(token, for: email, credentials: CredentialStore()); return true }
        catch { return false }
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

    public static func remove(_ email: String) throws {
        try AccountConfiguration.shared.removeCredentials(for: email, credentials: CredentialStore())
        // The engine deletes the authoritative account row and cached mail.
    }
}
