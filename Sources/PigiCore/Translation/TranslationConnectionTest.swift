import Foundation

public enum TranslationConnectionTest {
    /// Sends one minimal segment through the same translator used at runtime.
    public static func run(
        config: TranslationConfig,
        apiKey: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) async -> Result<Void, TranslationError> {
        let translator = OpenAICompatibleTranslator(
            config: config,
            keyStore: InlineKeyStore(apiKey),
            transport: transport
        )
        do {
            _ = try await translator.translate([TranslationSegment(id: 0, text: "Hello")])
            return .success(())
        } catch let error as TranslationError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network("未知错误"))
        }
    }

    /// User-facing message. Never includes the API key.
    public static func message(for error: TranslationError) -> String {
        switch error {
        case .notConfigured:
            "请先把服务地址、模型和密钥填完整。"
        case .invalidBaseURL:
            "服务地址无效,需要 http 或 https 地址。"
        case .misaligned:
            "服务返回的条数和发送的对不上。"
        case .timeout:
            "连接超时,请检查网络或调大请求超时。"
        case .network(let detail):
            "网络不通:\(detail)"
        case .http(let status, let message):
            switch status {
            case 401, 403:
                "服务拒绝了请求(HTTP \(status)),请检查密钥是否正确。"
            default:
                message.isEmpty ? "服务返回 HTTP \(status)。" : "服务返回 HTTP \(status):\(message)"
            }
        case .invalidResponse:
            "返回格式不对,请确认这是兼容 OpenAI 接口的服务。"
        case .cancelled:
            "已取消。"
        }
    }
}

private struct InlineKeyStore: KeyStore {
    let key: String
    init(_ key: String) { self.key = key }
    func apiKey() -> String? { key }
    func setAPIKey(_ value: String) -> Bool { false }
}
