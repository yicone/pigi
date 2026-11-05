import SwiftUI
#if canImport(PigiCore)
import PigiCore
#endif

struct TranslationPage: View {
    private let store = TranslationConfigStore()
    @State private var config = TranslationConfig()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "翻译",
                    note: "把英文邮件译成简体中文,需要你自备 OpenAI 兼容服务;默认关闭。"
                )
                TranslationEnableSection(config: persisted)
                TranslationAPISection(config: persisted)
                TranslationPrivacySection(endpoint: config.baseURL)
                TranslationAdvancedSection(config: persisted)
                Spacer()
            }
            .padding(32)
        }
        .task { config = store.load() }
    }

    /// Every edit writes through to UserDefaults.
    private var persisted: Binding<TranslationConfig> {
        Binding(
            get: { config },
            set: { config = $0; store.save(config) }
        )
    }
}

private struct TranslationEnableSection: View {
    @Binding var config: TranslationConfig

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("启用翻译").font(.system(size: 13.5))
                Text("打开后,阅读英文邮件时可以译成简体中文;需要先在下面配好服务和密钥。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: $config.enabled).labelsHidden().toggleStyle(.switch)
        }
    }
}

private struct TranslationAPISection: View {
    @Binding var config: TranslationConfig
    private let keyStore = KeychainKeyStore()

    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var keyNote: String?
    @State private var testing = false
    @State private var testResult: Result<Void, TranslationError>?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 16) {
                GridRow {
                    FormLabel("服务地址")
                    TextField("https://api.example.com/v1", text: $config.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    FormLabel("模型")
                    TextField("例如 gpt-4o-mini", text: $config.model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    FormLabel("密钥")
                    HStack(spacing: 10) {
                        SecureField("API Key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Button("保存密钥") { saveKey() }
                            .disabled(keyDraft.isEmpty)
                        if hasKey {
                            Text("已保存").font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("清除") { clearKey() }
                        }
                    }
                }
                if let keyNote {
                    GridRow {
                        FormLabel("")
                        Text(keyNote).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    FormLabel("请求超时")
                    HStack(spacing: 8) {
                        TextField("", value: $config.requestTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("秒,范围 5–600").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    FormLabel("")
                    HStack(spacing: 10) {
                        Button(testing ? "测试中…" : "测试连接") { runTest() }
                            .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                if let testResult {
                    GridRow {
                        FormLabel("")
                        switch testResult {
                        case .success:
                            Label("连接正常", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12.5)).foregroundStyle(.green)
                        case .failure(let error):
                            Text(TranslationConnectionTest.message(for: error))
                                .font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
                        }
                    }
                }
            }
        }
        .task {
            do {
                hasKey = try keyStore.apiKey() != nil
            } catch {
                hasKey = false
                keyNote = "读不到钥匙串里的密钥"
            }
        }
        .onDisappear { testTask?.cancel() }
    }

    private func saveKey() {
        if keyStore.setAPIKey(keyDraft) {
            keyDraft = ""
            hasKey = true
            keyNote = "已保存在钥匙串"
        } else {
            keyNote = "密钥没存上"
        }
    }

    private func clearKey() {
        _ = keyStore.setAPIKey("")
        hasKey = false
        keyNote = nil
    }

    private func runTest() {
        testResult = nil
        testing = true
        let storedKey = (try? keyStore.apiKey()) ?? nil
        let key = keyDraft.isEmpty ? (storedKey ?? "") : keyDraft
        let current = config
        testTask = Task {
            let result = await TranslationConnectionTest.run(config: current, apiKey: key)
            testResult = result
            testing = false
        }
    }
}

private struct TranslationAdvancedSection: View {
    @Binding var config: TranslationConfig

    var body: some View {
        DisclosureGroup("高级") {
            VStack(alignment: .leading, spacing: 12) {
                Text("系统提示词").font(.system(size: 13)).foregroundStyle(.secondary)
                TextEditor(text: $config.systemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Button("恢复默认") { config.systemPrompt = TranslationConfig.defaultSystemPrompt }
                        .disabled(config.systemPrompt == TranslationConfig.defaultSystemPrompt)
                    Spacer()
                }
                Toggle("指定 Temperature", isOn: specifyTemperature)
                    .toggleStyle(.switch)
                if config.temperature != nil {
                    HStack(spacing: 8) {
                        TextField("", value: temperature, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("0–2").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
                Text("留空则不发送该字段,部分服务/模型不接受这个参数。")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        }
    }

    private var specifyTemperature: Binding<Bool> {
        Binding(
            get: { config.temperature != nil },
            set: { config.temperature = $0 ? (config.temperature ?? 0.2) : nil }
        )
    }

    private var temperature: Binding<Double> {
        Binding(
            get: { config.temperature ?? 0.2 },
            set: { config.temperature = min(2, max(0, $0)) }
        )
    }
}
