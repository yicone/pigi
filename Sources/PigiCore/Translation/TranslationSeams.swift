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
    public let accountID: String
    public let mailID: String
    public let bodyHash: String
    public let model: String
    /// Includes the prompt contract version, provider, temperature and actual system prompt.
    public let promptVersion: Int
    public let targetLanguage: String

    /// Use the same configuration snapshot as the request. There is deliberately no raw-version
    /// initializer: callers cannot omit the editable settings when constructing a cache key.
    public init(accountID: String, mailID: String, bodyHash: String, configuration: TranslationConfig) {
        self.accountID = accountID
        self.mailID = mailID
        self.bodyHash = bodyHash
        self.model = configuration.model
        self.promptVersion = Self.promptFingerprint(version: TranslationConfig.promptVersion,
            systemPrompt: configuration.systemPrompt, temperature: configuration.temperature,
            endpoint: configuration.baseURL)
        self.targetLanguage = configuration.targetLanguage
    }
}

/// Only whole-mail, validated results can be committed. Storage failures remain visible to callers.
public protocol TranslationCache: Sendable {
    func get(_ key: TranslationCacheKey) async throws -> CachedTranslation?
    func begin(_ key: TranslationCacheKey) async throws -> SQLiteTranslationCache.Ticket
    func put(_ value: CachedTranslation, for ticket: SQLiteTranslationCache.Ticket, validated: Bool) async throws
    func clear() async throws
    func purge(accountID: String) async throws
}

/// `setAPIKey("")` deletes the stored key.
public protocol KeyStore: Sendable {
    func apiKey() throws -> String?
    @discardableResult
    func setAPIKey(_ value: String) -> Bool
}
