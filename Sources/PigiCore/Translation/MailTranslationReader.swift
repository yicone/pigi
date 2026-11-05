import Foundation
import Observation

/// Ephemeral reading state. Translations never replace the stored mail body.
@MainActor
@Observable
public final class MailTranslationReader {
    public private(set) var isAvailable = false
    public private(set) var isTranslating = false
    public private(set) var translatedBody: String?
    public private(set) var showingTranslation = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let store: TranslationConfigStore
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private var config = TranslationConfig()
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    public init(
        store: TranslationConfigStore = TranslationConfigStore(),
        keyStore: any KeyStore = KeychainKeyStore(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.store = store
        self.keyStore = keyStore
        self.transport = transport
    }

    public func refreshConfiguration() {
        let updated = store.load()
        let key = updated.enabled ? ((try? keyStore.apiKey()) ?? nil) : nil
        let available = updated.enabled && updated.isConfigured(hasKey: !(key ?? "").isEmpty)
        if updated != config || available != isAvailable { reset() }
        config = updated
        isAvailable = available
    }

    public func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        isTranslating = false
        translatedBody = nil
        showingTranslation = false
        errorMessage = nil
    }

    public func toggle(body: String, isHTML: Bool) {
        refreshConfiguration()
        guard isAvailable, !isTranslating else { return }
        if translatedBody != nil {
            showingTranslation.toggle()
            return
        }
        errorMessage = nil
        isTranslating = true
        let current = generation
        let translator = OpenAICompatibleTranslator(config: config, keyStore: keyStore, transport: transport)
        task = Task { [weak self] in
            do {
                let result = try await MailTranslationPipeline().translate(body: body, isHTML: isHTML, using: translator)
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.translatedBody = result
                self.showingTranslation = true
                self.isTranslating = false
                self.task = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.isTranslating = false
                self.task = nil
                if error is CancellationError || (error as? TranslationError) == .cancelled { return }
                // Do not show provider response bodies or raw errors containing mail data.
                switch error as? TranslationError {
                case .timeout: self.errorMessage = "翻译超时，请重试或在设置中调大超时。"
                case .notConfigured, .invalidBaseURL: self.errorMessage = "请检查翻译设置中的服务地址、模型和密钥。"
                case .http(let status, _): self.errorMessage = "翻译服务返回 HTTP \(status)，请检查设置后重试。"
                default: self.errorMessage = "翻译失败，请检查网络与服务设置后重试。"
                }
            }
        }
    }
}
