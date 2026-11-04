import Foundation

public struct TranslationSegment: Sendable, Equatable {
    public var id: Int
    public var text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

public enum TranslationError: Error, Equatable, Sendable {
    case notConfigured
    case invalidBaseURL
    case misaligned
    case timeout
    case network(String)
    case http(status: Int, message: String)
    case invalidResponse
    case cancelled
}

public protocol SegmentTranslator: Sendable {
    /// Throws `.misaligned` when the reply's count or id set does not match the input.
    func translate(_ segments: [TranslationSegment]) async throws -> [TranslationSegment]
}

public enum TranslationPermission: Sendable, Equatable {
    case allowed
    case disabled
    case notConfigured
    case needsServiceConsent
    case needsAccountConsent
}

public protocol TranslationPolicy: Sendable {
    func permission(forAccount accountID: String) -> TranslationPermission
}

public struct TranslationCacheKey: Hashable, Sendable {
    public var accountID: String
    public var mailID: String
    public var bodyHash: String
    public var model: String
    public var promptVersion: Int
    public var targetLanguage: String

    public init(accountID: String, mailID: String, bodyHash: String, model: String, promptVersion: Int, targetLanguage: String) {
        self.accountID = accountID
        self.mailID = mailID
        self.bodyHash = bodyHash
        self.model = model
        self.promptVersion = promptVersion
        self.targetLanguage = targetLanguage
    }
}

public protocol TranslationCache: Sendable {
    func get(_ key: TranslationCacheKey) async -> [TranslationSegment]?
    func put(_ key: TranslationCacheKey, _ value: [TranslationSegment]) async
    func clear() async
    func purge(accountID: String) async
}

/// `setAPIKey("")` deletes the stored key.
public protocol KeyStore: Sendable {
    func apiKey() throws -> String?
    @discardableResult
    func setAPIKey(_ value: String) -> Bool
}
