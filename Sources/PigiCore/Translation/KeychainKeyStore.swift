import Foundation

public struct KeychainKeyStore: KeyStore {
    public init() {}

    public func apiKey() throws -> String? { try Keychain.translationAPIKey() }

    @discardableResult
    public func setAPIKey(_ value: String) -> Bool { Keychain.setTranslationAPIKey(value) }
}
