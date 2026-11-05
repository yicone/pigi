import XCTest
@testable import PigiCore

private extension LocalEngine {
    func seedProductionMail(cache: SQLiteTranslationCache, html: Bool) throws {
        translationCache = cache
        let memory = try Store(path: ":memory:")
        for sql in Self.schema { try memory.run(sql) }
        store = memory
        try memory.run("INSERT INTO accounts(email,kind) VALUES('mail@example.invalid','imap')")
        try memory.run("INSERT INTO messages(account,id,subject,html) VALUES('mail@example.invalid','one','Hello subject',?)",
            [html ? compress("<p>Hello <b>world</b></p>") : .null])
        try memory.run("INSERT INTO fts(rowid,subject,sender,body) SELECT rowid,subject,'sender','Hello world' FROM messages")
    }

    func originalProductionMailIsIntact() throws -> Bool {
        try body(account: "mail@example.invalid", id: "one").text == "Hello world"
            && db().query("SELECT subject FROM messages").first?["subject"]?.text == "Hello subject"
            && currentSeq() == 0
    }
}

private struct ProductionKeyStore: KeyStore {
    func apiKey() throws -> String? { "fixture-key" }
    func setAPIKey(_ value: String) -> Bool { false }
}

private actor ProductionTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var malformed = false
    private var hook: (@Sendable () async throws -> Void)?

    func recorded() -> [URLRequest] { requests }
    func setMalformed(_ value: Bool) { malformed = value }
    func onNextSend(_ action: @escaping @Sendable () async throws -> Void) { hook = action }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let action = hook; hook = nil
        try await action?()
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = payload["messages"] as! [[String: Any]]
        let source = messages[1]["content"] as! String
        var items = try JSONDecoder().decode([TranslationItem].self, from: Data(source.utf8))
        items = malformed ? [] : items.map {
            TranslationItem(i: $0.i, t: $0.t.replacingOccurrences(of: "Hello", with: "你好")
                .replacingOccurrences(of: "world", with: "世界").replacingOccurrences(of: "subject", with: "主题"))
        }
        let content = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class ProductionFixture {
    let engine = LocalEngine()
    let cache = SQLiteTranslationCache(path: ":memory:")
    let transport = ProductionTransport()
    let defaults: UserDefaults
    let configStore: TranslationConfigStore
    let privacy: TranslationPrivacySettings
    let suite = "production-translation-" + UUID().uuidString

    init(html: Bool = false) async throws {
        defaults = UserDefaults(suiteName: suite)!
        configStore = TranslationConfigStore(defaults: defaults)
        privacy = TranslationPrivacySettings(defaults: defaults)
        configStore.save(TranslationConfig(enabled: true, baseURL: "https://provider-a.example.invalid/v1", model: "same-model",
            systemPrompt: "Translate faithfully."))
        privacy.setEnabled(true, accountID: "mail@example.invalid", isProton: false)
        privacy.grantServiceConsent(endpoint: configStore.load().baseURL)
        try await engine.seedProductionMail(cache: cache, html: html)
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }

    // Exercise the engine method used by ArchiveClient, never construct or query a cache key in these tests.
    func request() async throws -> CachedTranslation {
        try await engine.translateMail(account: "mail@example.invalid", id: "one", configStore: configStore,
            keyStore: ProductionKeyStore(), transport: transport, privacy: privacy)
    }
}

final class ProductionTranslationTests: XCTestCase {
    @MainActor
    func testEngineRequestsUseConfigurationForCacheReadAndWrite() async throws {
        let fixture = try await ProductionFixture()
        defer { fixture.cleanup() }
        let original = fixture.configStore.load()
        let first = try await fixture.request()
        XCTAssertEqual(first, CachedTranslation(subject: "你好 主题", body: "你好 世界"))
        _ = try await fixture.request()
        let originalRequests = await fixture.transport.recorded()
        XCTAssertEqual(originalRequests.count, 2) // Subject + body, then a whole-mail cache hit.

        var provider = original; provider.baseURL = "https://provider-b.example.invalid/v1"
        fixture.configStore.save(provider)
        do { _ = try await fixture.request(); XCTFail("provider consent was bypassed") }
        catch let error as TranslationPermissionError { XCTAssertEqual(error.permission, .needsServiceConsent) }
        fixture.privacy.grantServiceConsent(endpoint: provider.baseURL)
        var temperature = original; temperature.temperature = 0.2
        var warmer = original; warmer.temperature = 0.7
        var prompt = original; prompt.systemPrompt = "Use another translation style."
        var expectedCount = 2
        for config in [provider, temperature, warmer, prompt] {
            fixture.configStore.save(config)
            _ = try await fixture.request()
            expectedCount += 2
            let records = await fixture.transport.recorded()
            XCTAssertEqual(records.count, expectedCount, "configuration change reused an old translation")
            for record in records.suffix(2) {
                XCTAssertEqual(record.url, config.chatCompletionsURL)
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.httpBody!) as? [String: Any])
                XCTAssertEqual(body["temperature"] as? Double, config.temperature)
                XCTAssertEqual(body["model"] as? String, config.model)
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertTrue((messages[0]["content"] as? String)?.hasPrefix(config.systemPrompt) == true)
                XCTAssertFalse(String(decoding: record.httpBody!, as: UTF8.self).contains("mail@example.invalid"))
            }
            _ = try await fixture.request()
            let repeated = await fixture.transport.recorded()
            XCTAssertEqual(repeated.count, expectedCount, "new configuration was not cached")
        }
        let intact = try await fixture.engine.originalProductionMailIsIntact()
        XCTAssertTrue(intact)
    }

    @MainActor
    func testConfigurationEditDuringRequestDoesNotChangeSnapshotOrWriteKey() async throws {
        let fixture = try await ProductionFixture()
        defer { fixture.cleanup() }
        let original = fixture.configStore.load()
        var next = original; next.temperature = 0.7
        let store = fixture.configStore
        let replacement = next
        await fixture.transport.onNextSend { store.save(replacement) }
        _ = try await fixture.request()
        let firstRecords = await fixture.transport.recorded()
        XCTAssertEqual(firstRecords.count, 2)
        for record in firstRecords {
            let body = try JSONSerialization.jsonObject(with: record.httpBody!) as! [String: Any]
            XCTAssertNil(body["temperature"], "one mail request mixed configuration snapshots")
        }
        _ = try await fixture.request()
        let secondRecords = await fixture.transport.recorded()
        XCTAssertEqual(secondRecords.count, 4, "old request was incorrectly written under the new configuration")
        fixture.configStore.save(original)
        _ = try await fixture.request()
        let restored = await fixture.transport.recorded()
        XCTAssertEqual(restored.count, 4, "the original request was not stored under its own snapshot")
    }

    @MainActor
    func testAlignmentFailureAndCancellationDoNotCacheProductionResults() async throws {
        let fixture = try await ProductionFixture()
        defer { fixture.cleanup() }
        await fixture.transport.setMalformed(true)
        do { _ = try await fixture.request(); XCTFail("accepted malformed translation") }
        catch let error as TranslationError { XCTAssertEqual(error, .misaligned) }
        await fixture.transport.setMalformed(false)
        await fixture.transport.onNextSend { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = Task { try await fixture.request() }
        do { _ = try await cancelled.value; XCTFail("accepted cancelled translation") }
        catch is CancellationError {} catch let error as TranslationError { XCTAssertEqual(error, .cancelled) }
        _ = try await fixture.request()
        let records = await fixture.transport.recorded()
        XCTAssertEqual(records.count, 4) // Malformed + cancelled + full successful retry.
        _ = try await fixture.request()
        let cached = await fixture.transport.recorded()
        XCTAssertEqual(cached.count, 4)
    }

    @MainActor
    func testClearDuringProductionRequestRejectsLateWrite() async throws {
        let fixture = try await ProductionFixture()
        defer { fixture.cleanup() }
        let cache = fixture.cache
        await fixture.transport.onNextSend { try await cache.clear() }
        do { _ = try await fixture.request(); XCTFail("wrote a late translation after clear") }
        catch SQLiteTranslationCache.Failure.invalidated {}
        _ = try await fixture.request()
        let records = await fixture.transport.recorded()
        XCTAssertEqual(records.count, 4)
    }

    @MainActor
    func testHTMLUsesValidatedPipelineAndWholeMailCache() async throws {
        let fixture = try await ProductionFixture(html: true)
        defer { fixture.cleanup() }
        let first = try await fixture.request()
        XCTAssertTrue(first.body.contains("你好"))
        XCTAssertTrue(first.body.contains("<b>世界</b>"))
        let second = try await fixture.request()
        XCTAssertEqual(first, second)
        let records = await fixture.transport.recorded()
        XCTAssertEqual(records.count, 2)
    }
}
