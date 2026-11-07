import XCTest
@testable import PigiCore

private struct ProductionEngineState: @unchecked Sendable {
    let store: Store?
    let cache: SQLiteTranslationCache
    let dependencies: TranslationDependencies?
}

private extension LocalEngine {
    func saveProductionState() -> ProductionEngineState {
        ProductionEngineState(store: store, cache: translationCache, dependencies: translationDependencies)
    }

    func installProductionDependencies(_ dependencies: TranslationDependencies) {
        translationDependencies = dependencies
    }

    func restoreProductionState(_ state: ProductionEngineState) {
        store = state.store
        translationCache = state.cache
        translationDependencies = state.dependencies
    }

    /// Swap the engine's cache mid-run; a new instance on the same path simulates an app restart.
    func installTranslationCache(_ cache: SQLiteTranslationCache) {
        translationCache = cache
    }

    func seedProductionMail(cache: SQLiteTranslationCache, html: Bool, body: String? = nil) throws {
        translationCache = cache
        let memory = try Store(path: ":memory:")
        for sql in Self.schema { try memory.run(sql) }
        store = memory
        try memory.run("INSERT INTO accounts(email,kind) VALUES('mail@example.invalid','imap')")
        try memory.run("INSERT INTO messages(account,id,subject,html) VALUES('mail@example.invalid','one','Hello subject',?)",
            [html ? compress(body ?? "<p>Hello <b>world</b></p>") : .null])
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
    private var markerSuffixes: [Int: String] = [:]
    private var dropClosingMarker = false
    private var hook: (@Sendable () async throws -> Void)?

    func recorded() -> [URLRequest] { requests }
    func setMalformed(_ value: Bool) { malformed = value }
    func setMarkerSuffixes(_ value: [Int: String]) { markerSuffixes = value }
    func setDropClosingMarker(_ value: Bool) { dropClosingMarker = value }
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
            var text = $0.t.replacingOccurrences(of: "Hello", with: "你好")
                .replacingOccurrences(of: "world", with: "世界").replacingOccurrences(of: "subject", with: "主题")
            if text.hasPrefix("⟦pigi:") {
                if dropClosingMarker, let closing = text.range(of: "⟦pigi:", options: .backwards) {
                    text = String(text[..<closing.lowerBound])
                }
                text += markerSuffixes[$0.i] ?? ""
            }
            return TranslationItem(i: $0.i, t: text)
        }
        let content = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class ProductionFixture {
    let engine = LocalEngine.shared
    private var savedState: ProductionEngineState?
    let cache = SQLiteTranslationCache(path: ":memory:")
    let transport = ProductionTransport()
    let defaults: UserDefaults
    let configStore: TranslationConfigStore
    let privacy: TranslationPrivacySettings
    let suite = "production-translation-" + UUID().uuidString

    init(html: Bool = false, body: String? = nil) async throws {
        defaults = UserDefaults(suiteName: suite)!
        configStore = TranslationConfigStore(defaults: defaults)
        privacy = TranslationPrivacySettings(defaults: defaults)
        configStore.save(TranslationConfig(enabled: true, baseURL: "https://provider-a.example.invalid/v1", model: "same-model",
            systemPrompt: "Translate faithfully."))
        privacy.setEnabled(true, accountID: "mail@example.invalid", isProton: false)
        privacy.grantServiceConsent(endpoint: configStore.load().baseURL)
        savedState = await engine.saveProductionState()
        try await engine.seedProductionMail(cache: cache, html: html, body: body)
        await engine.installProductionDependencies(TranslationDependencies(configStore: configStore,
            keyStore: ProductionKeyStore(), transport: transport, privacy: privacy))
    }

    func cleanup() async {
        if let savedState { await engine.restoreProductionState(savedState) }
        defaults.removePersistentDomain(forName: suite)
    }

    // Exercise the exact public application entry and its LocalEngine.shared dispatch.
    func request() async throws -> CachedTranslation {
        try await ArchiveClient().translateMail(account: "mail@example.invalid", id: "one")
    }
}

final class ProductionTranslationTests: XCTestCase {
    @MainActor
    func testEmptyVisibleContentDoesNotSendOrWriteCache() async throws {
        let fixture = try await ProductionFixture()
        addTeardownBlock { await fixture.cleanup() }
        let translator = try CachedMailTranslator(configuration: fixture.configStore.load(), cache: fixture.cache,
            keyStore: ProductionKeyStore(), transport: fixture.transport)
        for (body, html) in [(" \n\t", false), ("", true), ("<html><head><style>p {color:red}</style></head><body><p> </p></body></html>", true)] {
            do {
                _ = try await translator.translate(accountID: "mail@example.invalid", mailID: "empty", subject: " ", body: body, isHTML: html)
                XCTFail("accepted empty visible content")
            } catch let error as MailTranslationError { XCTAssertEqual(error, .noContent) }
        }
        let records = await fixture.transport.recorded()
        XCTAssertEqual(records.count, 0)
    }

    @MainActor
    func testEngineRequestsUseConfigurationForCacheReadAndWrite() async throws {
        let fixture = try await ProductionFixture()
        addTeardownBlock { await fixture.cleanup() }
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
        addTeardownBlock { await fixture.cleanup() }
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
        addTeardownBlock { await fixture.cleanup() }
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
        addTeardownBlock { await fixture.cleanup() }
        let cache = fixture.cache
        await fixture.transport.onNextSend { try await cache.clear() }
        do { _ = try await fixture.request(); XCTFail("wrote a late translation after clear") }
        catch SQLiteTranslationCache.Failure.invalidated {}
        _ = try await fixture.request()
        let records = await fixture.transport.recorded()
        XCTAssertEqual(records.count, 4)
    }

    @MainActor
    func testReaderDelegatesToEngineAndReadsThroughWholeMailCache() async throws {
        let fixture = try await ProductionFixture()
        addTeardownBlock { await fixture.cleanup() }
        let reader = MailTranslationReader(store: fixture.configStore, keyStore: ProductionKeyStore())
        reader.toggle(account: "mail@example.invalid", id: "one")
        await reader.task?.value
        XCTAssertEqual(reader.translatedBody, "你好 世界")
        XCTAssertTrue(reader.showingTranslation)
        reader.reset()
        reader.toggle(account: "mail@example.invalid", id: "one")
        await reader.task?.value
        XCTAssertEqual(reader.translatedBody, "你好 世界")
        let requests = await fixture.transport.recorded()
        XCTAssertEqual(requests.count, 2, "second translation was not served from the engine cache")
    }

    @MainActor
    func testFileBackedCacheServesWholeMailAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("translations.db").path
        let fixture = try await ProductionFixture()
        addTeardownBlock { await fixture.cleanup() }
        await fixture.engine.installTranslationCache(SQLiteTranslationCache(path: path))
        let first = try await fixture.request()
        // A fresh cache instance over the same file simulates an app restart.
        await fixture.engine.installTranslationCache(SQLiteTranslationCache(path: path))
        let second = try await fixture.request()
        XCTAssertEqual(first, second)
        let requests = await fixture.transport.recorded()
        XCTAssertEqual(requests.count, 2, "reopened cache did not serve the stored translation")
        let rows = try Store(path: path).query("SELECT count(*) AS n FROM translations")
        XCTAssertEqual(rows.first?["n"]?.int, 1)
    }

    @MainActor
    func testHTMLUsesValidatedPipelineAndWholeMailCache() async throws {
        let fixture = try await ProductionFixture(html: true)
        addTeardownBlock { await fixture.cleanup() }
        let first = try await fixture.request()
        XCTAssertTrue(first.body.contains("你好"))
        XCTAssertTrue(first.body.contains("<b>世界</b>"))
        let second = try await fixture.request()
        XCTAssertEqual(first, second)
        let records = await fixture.transport.recorded()
        XCTAssertEqual(records.count, 2)
    }

    @MainActor
    func testLongHTMLTrailingFiveAndFourCharactersWritesPersistentCache() async throws {
        let body = (0..<19).map { "<p>Hello <b>world</b> paragraph \($0).</p>" }.joined()
        let fixture = try await ProductionFixture(html: true, body: body)
        addTeardownBlock { await fixture.cleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("translations.db").path
        await fixture.engine.installTranslationCache(SQLiteTranslationCache(path: path))
        await fixture.transport.setMarkerSuffixes([7: "abcde", 11: "多余字符"])

        let first = try await fixture.request()
        let document = try XMLDocument(xmlString: first.body)
        let paragraphs = try document.nodes(forXPath: "//p")
        XCTAssertEqual(paragraphs.count, 19)
        for (index, paragraph) in paragraphs.enumerated() {
            XCTAssertEqual(paragraph.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), "你好 世界 paragraph \(index).")
        }
        XCTAssertEqual(try document.nodes(forXPath: "//p/b").map(\.stringValue), Array(repeating: "世界", count: 19))
        XCTAssertFalse(first.body.contains("⟦pigi:"))
        let rows = try Store(path: path).query("SELECT count(*) AS n FROM translations")
        XCTAssertEqual(rows.first?["n"]?.int, 1)
        await fixture.engine.installTranslationCache(SQLiteTranslationCache(path: path))
        let second = try await fixture.request()
        XCTAssertEqual(first, second)
        let requests = await fixture.transport.recorded()
        XCTAssertEqual(requests.count, 2, "reopened cache must avoid another service request")
    }

    @MainActor
    func testBrokenClosingMarkerDoesNotCacheAndReaderCanRetry() async throws {
        let fixture = try await ProductionFixture(html: true)
        addTeardownBlock { await fixture.cleanup() }
        await fixture.transport.setDropClosingMarker(true)
        let reader = MailTranslationReader(store: fixture.configStore, keyStore: ProductionKeyStore())
        reader.toggle(account: "mail@example.invalid", id: "one")
        await reader.task?.value
        XCTAssertEqual(reader.errorMessage, "译文与原文片段未能对齐，请重试翻译。")
        XCTAssertNil(reader.translatedBody)
        XCTAssertFalse(reader.showingTranslation)
        await fixture.transport.setDropClosingMarker(false)
        reader.toggle(account: "mail@example.invalid", id: "one")
        await reader.task?.value
        XCTAssertNil(reader.errorMessage)
        XCTAssertTrue(reader.showingTranslation)
        let requests = await fixture.transport.recorded()
        XCTAssertEqual(requests.count, 4, "alignment failure must not write a whole-mail cache entry")
        let intact = try await fixture.engine.originalProductionMailIsIntact()
        XCTAssertTrue(intact)
    }
}
