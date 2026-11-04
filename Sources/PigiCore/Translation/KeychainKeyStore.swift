import Foundation

public struct KeychainKeyStore: KeyStore {
    private let vault: KeychainVault

    public init(vault: KeychainVault = .shared) {
        self.vault = vault
    }

    public func apiKey() -> String? { vault.readTranslationAPIKey() }

    @discardableResult
    public func setAPIKey(_ value: String) -> Bool { vault.writeTranslationAPIKey(value) }
}
