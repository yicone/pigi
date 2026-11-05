import Foundation

public struct KeychainKeyStore: KeyStore {
    public static let didChangeNotification = Notification.Name("pigi.translationAPIKeyDidChange")
    public init() {}

    public func apiKey() throws -> String? { try Keychain.translationAPIKey() }

    @discardableResult
    public func setAPIKey(_ value: String) -> Bool {
        let saved = Keychain.setTranslationAPIKey(value)
        if saved { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
        return saved
    }
}
