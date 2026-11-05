import Foundation
import os

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        return (data, http)
    }
}

public protocol TranslationLogging: Sendable {
    func info(_ message: String)
    func error(_ message: String)
}

public struct TranslationOSLog: TranslationLogging {
    private let logger = Logger(subsystem: "one.yic.pigi", category: "translation")

    public init() {}

    public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

/// Non-streaming OpenAI-compatible `/chat/completions` translator. No SSE.
public struct OpenAICompatibleTranslator: SegmentTranslator {
    private let config: TranslationConfig
    private let keyStore: any KeyStore
    private let transport: any HTTPTransport
    private let log: any TranslationLogging

    public init(
        config: TranslationConfig,
        keyStore: any KeyStore,
        transport: any HTTPTransport = URLSessionTransport(),
        log: any TranslationLogging = TranslationOSLog()
    ) {
        self.config = config
        self.keyStore = keyStore
        self.transport = transport
        self.log = log
    }

    public func translate(_ segments: [TranslationSegment]) async throws -> [TranslationSegment] {
        if segments.isEmpty { return [] }
        // A keychain read failure means we cannot prove configuration; never leak details.
        let key: String
        do {
            key = try keyStore.apiKey() ?? ""
        } catch {
            throw TranslationError.notConfigured
        }
        guard !key.isEmpty, !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.notConfigured
        }
        guard let endpoint = config.chatCompletionsURL else { throw TranslationError.invalidBaseURL }
        try Task.checkCancellation()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(config: config, segments: segments)

        let started = Date()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as TranslationError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw TranslationError.cancelled
        } catch {
            throw TranslationError.network("请求失败")
        }
        try Task.checkCancellation()

        guard (200..<300).contains(response.statusCode) else {
            let message = Self.errorMessage(from: data, status: response.statusCode, key: key)
            log.error("translation failed status=\(response.statusCode) segments=\(segments.count)")
            throw TranslationError.http(status: response.statusCode, message: message)
        }
        log.info("translation ok status=\(response.statusCode) segments=\(segments.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return try Self.decodeSegments(from: data, matching: segments)
    }

    private static func map(_ error: URLError) -> TranslationError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        // URLError.Code names carry no URL or credential.
        default: return .network(describe(error.code))
        }
    }

    private static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: "notConnectedToInternet"
        case .cannotConnectToHost: "cannotConnectToHost"
        case .cannotFindHost: "cannotFindHost"
        case .networkConnectionLost: "networkConnectionLost"
        case .secureConnectionFailed: "secureConnectionFailed"
        case .serverCertificateUntrusted: "serverCertificateUntrusted"
        default: "code \(code.rawValue)"
        }
    }

    private static func requestBody(config: TranslationConfig, segments: [TranslationSegment]) throws -> Data {
        let items = segments.map { ["i": $0.id, "t": $0.text] as [String: Any] }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: items), as: UTF8.self)
        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": content],
            ],
        ]
        if let temperature = config.temperature { body["temperature"] = temperature }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func errorMessage(from data: Data, status: Int, key: String) -> String {
        var message = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let text = error["message"] as? String {
            message = text
        } else {
            message = String(decoding: data.prefix(200), as: UTF8.self)
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "***") }
        if message.count > 200 { message = String(message.prefix(200)) }
        return message.isEmpty ? "HTTP \(status)" : message
    }

    private static func decodeSegments(from data: Data, matching input: [TranslationSegment]) throws -> [TranslationSegment] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw TranslationError.invalidResponse }

        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let items = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        else { throw TranslationError.invalidResponse }
        guard items.count == input.count else { throw TranslationError.misaligned }

        var byID: [Int: String] = [:]
        for item in items {
            guard let i = item["i"] as? Int, let t = item["t"] as? String else {
                throw TranslationError.invalidResponse
            }
            guard byID[i] == nil else { throw TranslationError.misaligned }
            byID[i] = t
        }
        return try input.map { segment in
            guard let text = byID[segment.id] else { throw TranslationError.misaligned }
            return TranslationSegment(id: segment.id, text: text)
        }
    }
}
