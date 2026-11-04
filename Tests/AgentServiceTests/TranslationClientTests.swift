import XCTest
@testable import PigiCore

final class TranslationClientTests: XCTestCase {
    private let key = "sk-test-sentinel-816"

    // MARK: Request shape

    func testRequestShapeTrimsBaseAndOmitsTemperature() async throws {
        let transport = FakeTransport()
        transport.handler = { request in
            (try Self.chatJSON([["i": 1, "t": "你好"]]), Self.response(200, url: request.url))
        }
        var config = makeConfig(base: "  https://api.test/v1/  ")
        config.requestTimeout = 42
        let translator = OpenAICompatibleTranslator(
            config: config, keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        let out = try await translator.translate([TranslationSegment(id: 1, text: "Hello")])
        XCTAssertEqual(out, [TranslationSegment(id: 1, text: "你好")])

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 42)

        let body = try XCTUnwrap(transport.bodyJSON())
        XCTAssertEqual(body["model"] as? String, "model-x")
        XCTAssertEqual((body["stream"] as? NSNumber)?.boolValue, false)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["stream_options"])
        XCTAssertNil(body["response_format"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, TranslationConfig.defaultSystemPrompt)
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        let user = try XCTUnwrap(messages[1]["content"] as? String)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(user.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["i"] as? Int, 1)
        XCTAssertEqual(items[0]["t"] as? String, "Hello")
    }

    func testRequestIncludesTemperatureOnlyWhenSet() async throws {
        let transport = FakeTransport()
        transport.handler = { request in
            (try Self.chatJSON([["i": 0, "t": "x"]]), Self.response(200, url: request.url))
        }
        var config = makeConfig()
        config.temperature = 0.5
        let translator = OpenAICompatibleTranslator(
            config: config, keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        _ = try await translator.translate([TranslationSegment(id: 0, text: "Hi")])
        let body = try XCTUnwrap(transport.bodyJSON())
        XCTAssertEqual(body["temperature"] as? Double, 0.5)
        XCTAssertEqual((body["stream"] as? NSNumber)?.boolValue, false)
    }

    // MARK: Response handling

    func testFencedAndReorderedReplyAlignsByID() async throws {
        let transport = FakeTransport()
        transport.handler = { request in
            (try Self.chatJSON([
                ["i": 3, "t": "三"],
                ["i": 1, "t": "一"],
                ["i": 2, "t": "二"],
            ], fenced: true), Self.response(200, url: request.url))
        }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        let out = try await translator.translate([
            TranslationSegment(id: 1, text: "a"),
            TranslationSegment(id: 2, text: "b"),
            TranslationSegment(id: 3, text: "c"),
        ])
        XCTAssertEqual(out, [
            TranslationSegment(id: 1, text: "一"),
            TranslationSegment(id: 2, text: "二"),
            TranslationSegment(id: 3, text: "三"),
        ])
    }

    func testMisalignedReplies() async throws {
        let cases: [[[String: Any]]] = [
            [["i": 1, "t": "a"]],                                    // fewer
            [["i": 1, "t": "a"], ["i": 2, "t": "b"], ["i": 3, "t": "c"]], // more
            [["i": 1, "t": "a"], ["i": 1, "t": "b"]],                // duplicate id
            [["i": 1, "t": "a"], ["i": 9, "t": "b"]],                // unknown id
        ]
        for items in cases {
            let transport = FakeTransport()
            transport.handler = { request in
                (try Self.chatJSON(items), Self.response(200, url: request.url))
            }
            let translator = OpenAICompatibleTranslator(
                config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
            await assertError(.misaligned) {
                try await translator.translate([
                    TranslationSegment(id: 1, text: "a"),
                    TranslationSegment(id: 2, text: "b"),
                ])
            }
        }
    }

    func testNonJSONReplyIsInvalidResponse() async throws {
        let transport = FakeTransport()
        transport.handler = { request in
            (try Self.chatData(content: "这不是 JSON"), Self.response(200, url: request.url))
        }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        await assertError(.invalidResponse) {
            try await translator.translate([TranslationSegment(id: 1, text: "a")])
        }
    }

    func testMissingFieldIsInvalidResponse() async throws {
        let transport = FakeTransport()
        transport.handler = { request in
            (try Self.chatJSON([["i": 1]]), Self.response(200, url: request.url))
        }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        await assertError(.invalidResponse) {
            try await translator.translate([TranslationSegment(id: 1, text: "a")])
        }
    }

    func testMalformedEnvelopeIsInvalidResponse() async throws {
        let transport = FakeTransport()
        transport.handler = { request in (Data("oops".utf8), Self.response(200, url: request.url)) }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        await assertError(.invalidResponse) {
            try await translator.translate([TranslationSegment(id: 1, text: "a")])
        }
    }

    // MARK: Errors

    func testHTTPErrorStatusAndMessageHideKey() async throws {
        let log = CapturingTranslationLog()
        let transport = FakeTransport()
        let body = try JSONSerialization.data(
            withJSONObject: ["error": ["message": "invalid api key \(key) supplied"]])
        transport.handler = { request in (body, Self.response(401, url: request.url)) }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: log)
        do {
            _ = try await translator.translate([TranslationSegment(id: 0, text: "a")])
            XCTFail("expected http error")
        } catch TranslationError.http(let status, let message) {
            XCTAssertEqual(status, 401)
            XCTAssertFalse(message.contains(key), message)
            XCTAssertTrue(message.contains("***"))
            XCTAssertFalse(String(describing: message).contains(key))
        }
        for entry in log.snapshot() {
            XCTAssertFalse(entry.contains(key), entry)
        }
        let shown = TranslationConnectionTest.message(for: .http(status: 401, message: "invalid api key \(key)"))
        XCTAssertFalse(shown.contains(key))
    }

    func testHTTPErrorPlainBodyIsTruncatedAndSanitized() async throws {
        let transport = FakeTransport()
        let raw = String(repeating: "x", count: 500) + key
        transport.handler = { request in (Data(raw.utf8), Self.response(500, url: request.url)) }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        do {
            _ = try await translator.translate([TranslationSegment(id: 0, text: "a")])
            XCTFail("expected http error")
        } catch TranslationError.http(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertLessThanOrEqual(message.count, 200)
            XCTAssertFalse(message.contains(key))
        }
    }

    func testTimeoutAndNetworkMapping() async throws {
        let transport = FakeTransport()
        transport.handler = { _ in throw URLError(.timedOut) }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        await assertError(.timeout) {
            try await translator.translate([TranslationSegment(id: 0, text: "a")])
        }

        transport.handler = { _ in throw URLError(.cannotConnectToHost) }
        await assertError(.network("cannotConnectToHost")) {
            try await translator.translate([TranslationSegment(id: 0, text: "a")])
        }
    }

    func testCancellationMapsToCancelled() async {
        let transport = FakeTransport()
        transport.handler = { _ in
            try await Task.sleep(for: .seconds(600))
            return (Data(), Self.response(200))
        }
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        let task = Task { try await translator.translate([TranslationSegment(id: 0, text: "a")]) }
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation")
        case .failure(let error):
            if let translationError = error as? TranslationError {
                XCTAssertEqual(translationError, .cancelled)
            } else {
                XCTAssertTrue(error is CancellationError, "unexpected \(error)")
            }
        }
    }

    // MARK: Configuration gates

    func testNotConfiguredSkipsRequest() async throws {
        let transport = FakeTransport()
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(nil), transport: transport, log: CapturingTranslationLog())
        await assertError(.notConfigured) {
            try await translator.translate([TranslationSegment(id: 0, text: "a")])
        }

        var noModel = makeConfig()
        noModel.model = "  "
        let translator2 = OpenAICompatibleTranslator(
            config: noModel, keyStore: MemoryKeyStore(key), transport: transport, log: CapturingTranslationLog())
        await assertError(.notConfigured) {
            try await translator2.translate([TranslationSegment(id: 0, text: "a")])
        }
        XCTAssertEqual(transport.requestCount(), 0)
    }

    func testInvalidBaseURLSkipsRequest() async throws {
        for base in ["not a url", "ftp://api.test", "https://", ""] {
            let transport = FakeTransport()
            let translator = OpenAICompatibleTranslator(
                config: makeConfig(base: base), keyStore: MemoryKeyStore(key),
                transport: transport, log: CapturingTranslationLog())
            await assertError(.invalidBaseURL) {
                try await translator.translate([TranslationSegment(id: 0, text: "a")])
            }
            XCTAssertEqual(transport.requestCount(), 0, base)
        }
    }

    func testEmptySegmentsSendNothing() async throws {
        let transport = FakeTransport()
        let translator = OpenAICompatibleTranslator(
            config: makeConfig(), keyStore: MemoryKeyStore(nil), transport: transport, log: CapturingTranslationLog())
        let out = try await translator.translate([])
        XCTAssertEqual(out, [])
        XCTAssertEqual(transport.requestCount(), 0)
    }

    // MARK: TranslationConfig / store

    func testChatCompletionsURL() {
        var config = TranslationConfig()
        XCTAssertNil(config.chatCompletionsURL)
        config.baseURL = " https://api.test/v1/ "
        XCTAssertEqual(config.chatCompletionsURL?.absoluteString, "https://api.test/v1/chat/completions")
        config.baseURL = "http://localhost:11434"
        XCTAssertEqual(config.chatCompletionsURL?.absoluteString, "http://localhost:11434/chat/completions")
        config.baseURL = "ftp://api.test"
        XCTAssertNil(config.chatCompletionsURL)
        config.baseURL = "api.test/v1"
        XCTAssertNil(config.chatCompletionsURL)
    }

    func testIsConfiguredRequiresURLModelAndKey() {
        var config = TranslationConfig()
        config.baseURL = "https://api.test"
        config.model = "m"
        XCTAssertTrue(config.isConfigured(hasKey: true))
        XCTAssertFalse(config.isConfigured(hasKey: false))
        config.model = " "
        XCTAssertFalse(config.isConfigured(hasKey: true))
        config.model = "m"
        config.baseURL = "nope"
        XCTAssertFalse(config.isConfigured(hasKey: true))
    }

    func testConfigStoreDefaultsRoundtripAndClamp() throws {
        let defaults = UserDefaults(suiteName: "pigi-tests.\(UUID().uuidString)")!
        let store = TranslationConfigStore(defaults: defaults)

        let loaded = store.load()
        XCTAssertEqual(loaded, TranslationConfig())
        XCTAssertFalse(loaded.enabled)
        XCTAssertEqual(loaded.requestTimeout, 120)
        XCTAssertNil(loaded.temperature)
        XCTAssertEqual(loaded.systemPrompt, TranslationConfig.defaultSystemPrompt)

        var config = TranslationConfig()
        config.enabled = true
        config.baseURL = "https://api.test"
        config.model = "m"
        config.requestTimeout = 7
        store.save(config)
        let again = store.load()
        XCTAssertEqual(again, config)
        XCTAssertNil(again.temperature)

        var clamped = TranslationConfig()
        clamped.requestTimeout = 1
        XCTAssertEqual(clamped.requestTimeout, 5)
        clamped.requestTimeout = 9999
        XCTAssertEqual(clamped.requestTimeout, 600)

        let raw = try JSONSerialization.data(withJSONObject: ["requestTimeout": 9999, "enabled": true])
        defaults.set(raw, forKey: "translation.config")
        let decoded = store.load()
        XCTAssertEqual(decoded.requestTimeout, 600)
        XCTAssertTrue(decoded.enabled)

        defaults.set(Data("not json".utf8), forKey: "translation.config")
        XCTAssertEqual(store.load(), TranslationConfig())
    }

    // MARK: KeychainKeyStore

    func testKeychainKeyStoreWriteReadDelete() {
        let vault = KeychainVault(backend: MemoryKeychainBackend(), service: "pigi-tests")
        let store = KeychainKeyStore(vault: vault)
        XCTAssertNil(store.apiKey())
        XCTAssertTrue(store.setAPIKey(key))
        XCTAssertEqual(store.apiKey(), key)
        XCTAssertTrue(store.setAPIKey(""))
        XCTAssertNil(store.apiKey())
    }

    // MARK: TranslationConnectionTest

    func testConnectionTestSuccessSendsOneRequest() async throws {
        let transport = FakeTransport()
        transport.handler = { request in
            (try Self.chatJSON([["i": 0, "t": "你好"]]), Self.response(200, url: request.url))
        }
        let result = await TranslationConnectionTest.run(config: makeConfig(), apiKey: key, transport: transport)
        switch result {
        case .success: break
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
        XCTAssertEqual(transport.requestCount(), 1)
    }

    func testConnectionTestMapsFailure() async throws {
        let transport = FakeTransport()
        let body = try JSONSerialization.data(withJSONObject: ["error": ["message": "bad key \(key)"]])
        transport.handler = { request in (body, Self.response(403, url: request.url)) }
        let result = await TranslationConnectionTest.run(config: makeConfig(), apiKey: key, transport: transport)
        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .http(status: 403, message: "bad key ***"))
        let shown = TranslationConnectionTest.message(for: error)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertFalse(shown.contains(key), shown)
        XCTAssertTrue(shown.contains("检查密钥"))
    }

    func testConnectionTestNotConfiguredSendsNothing() async {
        let transport = FakeTransport()
        let result = await TranslationConnectionTest.run(config: makeConfig(), apiKey: "", transport: transport)
        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .notConfigured)
        XCTAssertEqual(transport.requestCount(), 0)
    }

    func testMessageForEveryErrorIsSafeAndNonEmpty() {
        let errors: [TranslationError] = [
            .notConfigured, .invalidBaseURL, .misaligned, .timeout,
            .network("cannotConnectToHost"), .http(status: 503, message: "down"),
            .invalidResponse, .cancelled,
        ]
        for error in errors {
            let message = TranslationConnectionTest.message(for: error)
            XCTAssertFalse(message.isEmpty, "\(error)")
            XCTAssertFalse(message.contains(key), "\(error)")
        }
    }

    // MARK: Helpers

    private func makeConfig(base: String = "https://api.test/v1") -> TranslationConfig {
        var config = TranslationConfig()
        config.baseURL = base
        config.model = "model-x"
        return config
    }

    private static func response(_ status: Int, url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://api.test/v1/chat/completions")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func chatJSON(_ items: [[String: Any]], fenced: Bool = false) throws -> Data {
        let inner = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        var content = String(decoding: inner, as: UTF8.self)
        if fenced { content = "```json\n\(content)\n```" }
        return try chatData(content: content)
    }

    private static func chatData(content: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func assertError(
        _ expected: TranslationError,
        _ body: () async throws -> [TranslationSegment],
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as TranslationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var currentHandler: ((URLRequest) async throws -> (Data, HTTPURLResponse))?

    var handler: ((URLRequest) async throws -> (Data, HTTPURLResponse))? {
        get { lock.lock(); defer { lock.unlock() }; return currentHandler }
        set { lock.lock(); defer { lock.unlock() }; currentHandler = newValue }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let handler = record(request) { return try await handler(request) }
        return (Data(), HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.test")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func record(_ request: URLRequest) -> ((URLRequest) async throws -> (Data, HTTPURLResponse))? {
        lock.lock(); defer { lock.unlock() }
        sent.append(request)
        return currentHandler
    }

    func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return sent.count
    }

    func bodyJSON() throws -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let body = sent.last?.httpBody else { return nil }
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private var key: String?

    init(_ key: String? = nil) { self.key = key }

    func apiKey() -> String? { key }

    func setAPIKey(_ value: String) -> Bool {
        key = value.isEmpty ? nil : value
        return true
    }
}

private final class CapturingTranslationLog: TranslationLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func info(_ message: String) { append(message) }
    func error(_ message: String) { append(message) }

    private func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(message)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
