import Foundation
import os

/// Whole-mail request orchestration, used by LocalEngine's application API.
/// One immutable request configuration drives both the OpenAI client and all cache operations.
struct CachedMailTranslator: Sendable {
    /// Fixed literals only: never mail ids, accounts, subjects, bodies or endpoints.
    private let logger = Logger(subsystem: "one.yic.pigi", category: "translation")
    private let configuration: TranslationConfig
    private let cache: any TranslationCache
    private let translator: OpenAICompatibleTranslator
    private let pipeline: MailTranslationPipeline

    init(configuration: TranslationConfig, cache: any TranslationCache, keyStore: any KeyStore,
         transport: any HTTPTransport) throws {
        var snapshot = configuration
        // Include the extraction contract's fixed marker instructions in the actual request
        // and in its fingerprint, without changing the extraction/rendering implementation.
        snapshot.systemPrompt += "\n\n" + (try TranslationRequest(items: [])).system
        self.configuration = snapshot
        self.cache = cache
        self.translator = OpenAICompatibleTranslator(config: snapshot, keyStore: keyStore, transport: transport)
        self.pipeline = try MailTranslationPipeline()
    }

    func translate(accountID: String, mailID: String, subject: String, body: String, isHTML: Bool) async throws -> CachedTranslation {
        try Task.checkCancellation()
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           try !MailTranslationPipeline.hasContent(body: body, isHTML: isHTML) {
            throw MailTranslationError.noContent
        }
        let key = TranslationCacheKey(accountID: accountID, mailID: mailID,
            bodyHash: TranslationCacheKey.sourceHash(subject: subject, body: body, isHTML: isHTML),
            configuration: configuration)
        // Begin before the first suspension in a lookup, so purge/clear invalidates this
        // request even when it races with a cache miss.
        let ticket = try await cache.begin(key)
        if let hit = try await cache.get(key) {
            try Task.checkCancellation()
            logger.info("cache outcome=hit")
            return hit
        }
        logger.info("cache outcome=miss")
        try Task.checkCancellation()
        let translatedSubject: String
        if TranslationLanguage.shouldTranslate(subject) {
            let segments = try await translator.translate([TranslationSegment(id: 0, text: subject)])
            guard segments.count == 1, segments[0].id == 0 else { throw TranslationError.misaligned }
            translatedSubject = segments[0].text
        } else { translatedSubject = subject }
        let translatedBody = try await pipeline.translate(body: body, isHTML: isHTML,
            using: SegmentMailTranslator(translator: translator))
        try Task.checkCancellation()
        let value = CachedTranslation(subject: translatedSubject, body: translatedBody)
        // Both the HTTP client's id/count checks and the complete document's alignment
        // validation have succeeded. Throws/cancellation above never reach this write.
        try await cache.put(value, for: ticket, validated: true)
        logger.info("cache outcome=stored")
        return value
    }
}

/// Adapts the existing non-streaming client to the existing extraction contract.
private struct SegmentMailTranslator: MailTextTranslator {
    let translator: OpenAICompatibleTranslator

    func translate(_ request: TranslationRequest) async throws -> String {
        let items = try JSONDecoder().decode([TranslationItem].self, from: Data(request.user.utf8))
        let segments = try await translator.translate(items.map { TranslationSegment(id: $0.i, text: $0.t) })
        return String(decoding: try JSONEncoder().encode(segments.map { TranslationItem(i: $0.id, t: $0.text) }), as: UTF8.self)
    }
}
