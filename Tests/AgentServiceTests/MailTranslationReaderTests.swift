import XCTest
@testable import PigiCore

@MainActor
final class MailTranslationReaderTests: XCTestCase {
    private func fixture(enabled: Bool = true, key: String? = "fixture-key", baseURL: String = "https://translation.test/v1",
                         model: String = "fixture-model", transport: ReaderTransport = ReaderTransport())
        -> (MailTranslationReader, TranslationConfigStore, ReaderTransport) {
        let defaults = UserDefaults(suiteName: "pigi-reader-tests.\(UUID().uuidString)")!
        let store = TranslationConfigStore(defaults: defaults)
        store.save(TranslationConfig(enabled: enabled, baseURL: baseURL, model: model))
        return (MailTranslationReader(store: store, keyStore: ReaderKeyStore(key: key), transport: transport), store, transport)
    }

    func testGateRequiresEnabledURLModelAndNonemptyKey() async {
        for (enabled, key, base, model) in [
            (false, "key", "https://translation.test", "model"),
            (true, "", "https://translation.test", "model"),
            (true, "key", "invalid", "model"),
            (true, "key", "https://translation.test", " ")
        ] {
            let (reader, _, transport) = fixture(enabled: enabled, key: key, baseURL: base, model: model)
            reader.refreshConfiguration()
            XCTAssertFalse(reader.isAvailable)
            reader.toggle(body: "Please read this email.", isHTML: false)
            XCTAssertFalse(reader.isTranslating)
            let count = await transport.count
            XCTAssertEqual(count, 0)
        }
        let (reader, _, _) = fixture()
        reader.refreshConfiguration()
        XCTAssertTrue(reader.isAvailable)
    }

    func testKeyReadFailureHidesEntry() {
        let (_, store, transport) = fixture()
        let reader = MailTranslationReader(store: store, keyStore: ReaderKeyStore(key: nil, fails: true), transport: transport)
        reader.refreshConfiguration()
        XCTAssertFalse(reader.isAvailable)
    }

    func testClickTranslatesAndTogglesOriginalWithoutAnotherRequest() async {
        let (reader, _, transport) = fixture()
        reader.toggle(body: "Hello world", isHTML: false)
        XCTAssertTrue(reader.isTranslating)
        await reader.task?.value
        XCTAssertFalse(reader.isTranslating)
        XCTAssertEqual(reader.translatedBody, "你好 world")
        XCTAssertTrue(reader.showingTranslation)
        reader.toggle(body: "Hello world", isHTML: false)
        XCTAssertFalse(reader.showingTranslation)
        reader.toggle(body: "Hello world", isHTML: false)
        XCTAssertTrue(reader.showingTranslation)
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testAdapterPreservesHTMLMarkersAndBothSystemPrompts() async throws {
        let (reader, store, transport) = fixture()
        var config = store.load()
        config.systemPrompt = "Custom translation instruction."
        store.save(config)
        reader.toggle(body: "<p>Hello <b>world</b></p>", isHTML: true)
        await reader.task?.value
        let output = try XCTUnwrap(reader.translatedBody)
        let xml = try XMLDocument(xmlString: output)
        XCTAssertEqual(try xml.nodes(forXPath: "//b").first?.stringValue, "world")
        XCTAssertTrue(output.contains("你好"))
        let recorded = await transport.lastRequest()
        let request = try XCTUnwrap(recorded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains(config.systemPrompt))
        XCTAssertTrue(messages[0]["content"]!.contains("boundary marker verbatim"))
        XCTAssertEqual(messages[1]["role"], "user")
    }

    func testFailureKeepsOriginalAndAllowsRetryWithoutLeakingResponse() async {
        let transport = ReaderTransport(status: 503)
        let (reader, _, _) = fixture(transport: transport)
        reader.toggle(body: "Hello world", isHTML: false)
        await reader.task?.value
        XCTAssertNil(reader.translatedBody)
        XCTAssertFalse(reader.showingTranslation)
        XCTAssertTrue(reader.errorMessage?.contains("503") == true)
        XCTAssertFalse(reader.errorMessage?.contains("private-response") == true)
        await transport.setStatus(200)
        reader.toggle(body: "Hello world", isHTML: false)
        await reader.task?.value
        XCTAssertTrue(reader.showingTranslation)
        XCTAssertNil(reader.errorMessage)
    }

    func testSwitchingMailDiscardsLateResponseAndDuplicateClicks() async {
        let transport = ReaderTransport(hold: true)
        let (reader, _, _) = fixture(transport: transport)
        reader.toggle(body: "Hello old mail", isHTML: false)
        let pending = reader.task
        await transport.waitUntilStarted()
        reader.toggle(body: "Hello old mail", isHTML: false)
        let count = await transport.count
        XCTAssertEqual(count, 1)
        reader.reset()
        await transport.release()
        await pending?.value
        XCTAssertNil(reader.translatedBody)
        XCTAssertFalse(reader.showingTranslation)
        XCTAssertFalse(reader.isTranslating)
        XCTAssertNil(reader.errorMessage)
    }

    func testDisableOrChangeConfigurationCancelsPendingTranslation() async {
        for disable in [true, false] {
            let transport = ReaderTransport(hold: true)
            let (reader, store, _) = fixture(transport: transport)
            reader.toggle(body: "Hello old mail", isHTML: false)
            let pending = reader.task
            await transport.waitUntilStarted()
            var config = store.load()
            if disable { config.enabled = false } else { config.model = "different-model" }
            store.save(config)
            reader.refreshConfiguration()
            XCTAssertEqual(reader.isAvailable, !disable)
            XCTAssertFalse(reader.isTranslating)
            await transport.release()
            await pending?.value
            XCTAssertNil(reader.translatedBody)
            XCTAssertFalse(reader.showingTranslation)
        }
    }
}

private struct ReaderKeyStore: KeyStore {
    let key: String?
    var fails = false
    func apiKey() throws -> String? {
        if fails { throw TranslationError.notConfigured }
        return key
    }
    func setAPIKey(_ value: String) -> Bool { false }
}

private actor ReaderTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var status: Int
    private let hold: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    init(status: Int = 200, hold: Bool = false) { self.status = status; self.hold = hold }
    var count: Int { requests.count }
    func lastRequest() -> URLRequest? { requests.last }
    func setStatus(_ status: Int) { self.status = status }
    func waitUntilStarted() async {
        if requests.isEmpty { await withCheckedContinuation { started = $0 } }
    }
    func release() { held?.resume(); held = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        started?.resume(); started = nil
        // Intentionally ignores cancellation to exercise stale response protection.
        if hold { await withCheckedContinuation { held = $0 } }
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = object["messages"] as! [[String: String]]
        let items = try JSONDecoder().decode([TranslationItem].self, from: Data(messages[1]["content"]!.utf8))
        let output = items.map { TranslationItem(i: $0.i, t: $0.t.replacingOccurrences(of: "Hello", with: "你好")) }
        let content = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]], "error": ["message": "private-response"]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
