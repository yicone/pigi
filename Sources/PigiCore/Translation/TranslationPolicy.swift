import Foundation
import Observation

extension TranslationPermission {
    public static func evaluate(globalEnabled: Bool, configured: Bool, accountEnabled: Bool,
                                serviceConsent: Bool, isProton: Bool, accountConsent: Bool) -> Self {
        guard globalEnabled, configured else { return .notConfigured }
        guard accountEnabled else { return .disabled }
        guard serviceConsent else { return .needsServiceConsent }
        guard !isProton || accountConsent else { return .needsAccountConsent }
        return .allowed
    }
}

/// Stores privacy choices only. Credentials remain exclusively in KeychainVault.
@MainActor @Observable
public final class TranslationPrivacySettings {
    public static let shared = TranslationPrivacySettings()
    private struct AccountChoice: Codable {
        var enabled = false
        var protonConsent = false
    }
    private struct Choices: Codable {
        var accounts: [String: AccountChoice] = [:]
        var services: Set<String> = []
    }
    private var choices: Choices
    private let defaults: UserDefaults
    private static let storageKey = "translation.privacy.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choices = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Choices.self, from: $0) } ?? Choices()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(choices) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Bound to a concrete endpoint. Changing provider/path requires fresh consent.
    public static func serviceIdentity(_ endpoint: String) -> String? {
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }

    public func isEnabled(accountID: String) -> Bool { choices.accounts[accountID.lowercased()]?.enabled ?? false }
    public func hasAccountConsent(accountID: String) -> Bool { choices.accounts[accountID.lowercased()]?.protonConsent ?? false }
    public func hasServiceConsent(endpoint: String) -> Bool {
        guard let identity = Self.serviceIdentity(endpoint) else { return false }
        return choices.services.contains(identity)
    }

    public func policy(accountID: String, isProton: Bool, globalEnabled: Bool,
                       configured: Bool, endpoint: String) -> TranslationPermission {
        .evaluate(globalEnabled: globalEnabled, configured: configured && Self.serviceIdentity(endpoint) != nil,
                  accountEnabled: isEnabled(accountID: accountID), serviceConsent: hasServiceConsent(endpoint: endpoint),
                  isProton: isProton, accountConsent: hasAccountConsent(accountID: accountID))
    }

    /// Invoke only from an explicit confirmation action; never as a side effect of a request.
    public func grantServiceConsent(endpoint: String) {
        guard let identity = Self.serviceIdentity(endpoint) else { return }
        choices.services.insert(identity)
        save()
    }

    /// Proton stays off until the account-specific dialog has been accepted.
    @discardableResult
    public func setEnabled(_ enabled: Bool, accountID: String, isProton: Bool,
                           confirmingProtonConsent: Bool = false) -> TranslationPermission {
        let id = accountID.lowercased()
        var choice = choices.accounts[id] ?? AccountChoice()
        if enabled && isProton && !choice.protonConsent {
            guard confirmingProtonConsent else { return .needsAccountConsent }
            choice.protonConsent = true
        }
        choice.enabled = enabled
        choices.accounts[id] = choice
        save()
        return enabled ? .allowed : .disabled
    }

    public func removeAccount(_ accountID: String) {
        choices.accounts[accountID.lowercased()] = nil
        save()
    }
}

/// Immutable policy snapshot; reconstruct before each outgoing request and after any consent change.
public struct StoredTranslationPolicy: TranslationPolicy {
    private let decisions: [String: TranslationPermission]

    @MainActor
    public init(accounts: [(id: String, isProton: Bool)], globalEnabled: Bool, configured: Bool,
                endpoint: String, privacy: TranslationPrivacySettings? = nil) {
        let privacy = privacy ?? .shared
        var decisions: [String: TranslationPermission] = [:]
        for account in accounts {
            decisions[account.id.lowercased()] = privacy.policy(accountID: account.id, isProton: account.isProton,
                globalEnabled: globalEnabled, configured: configured, endpoint: endpoint)
        }
        self.decisions = decisions
    }

    public func permission(forAccount accountID: String) -> TranslationPermission {
        decisions[accountID.lowercased()] ?? .disabled
    }
}
