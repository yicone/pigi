import SwiftUI
#if canImport(PigiCore)
import PigiCore
#endif

/// ACM-816 mounts this as one line inside its translation settings page.
/// The page supplies its current endpoint; no API key is passed to this view.
struct TranslationPrivacySection: View {
    let endpoint: String
    @Environment(AppState.self) private var state
    private let privacy = TranslationPrivacySettings.shared
    @State private var pendingProton: Account?
    @State private var confirmService = false
    @State private var pendingEndpoint = ""
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("各账号开关").font(.headline)
            ForEach(state.allAccounts) { account in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name)
                        Text(account.email).font(.caption).foregroundStyle(.secondary)
                        if account.kind == .proton {
                            Text("端到端邮件会发给外部翻译服务")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("允许此邮箱翻译", isOn: Binding(
                        get: { privacy.isEnabled(accountID: account.id) },
                        set: { enabled in
                            let result = privacy.setEnabled(enabled, accountID: account.id, isProton: account.kind == .proton)
                            if result == .needsAccountConsent { pendingProton = account }
                        }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("允许 \(account.name) 翻译")
                }
            }
            Button(privacy.hasServiceConsent(endpoint: endpoint) ? "已同意向此服务外发" : "确认向此服务外发…") {
                pendingEndpoint = endpoint
                confirmService = true
            }
            .disabled(privacy.hasServiceConsent(endpoint: endpoint) || TranslationPrivacySettings.serviceIdentity(endpoint) == nil)
            Text("翻译会将邮件主题和正文发送给所配置的服务，不含收件人地址。正文中本来包含的地址仍会随正文发送。更换服务需重新确认。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button(clearing ? "正在清空…" : "清空译文缓存…") { confirmClear = true }.disabled(clearing)
            Text("translations.db 保存本机明文译文，包括 Proton 邮件译文。清空会删除所有账号的译文阅读缓存，不影响原信；正在翻译的旧结果不会重新写入。备份中的副本不在清理范围内。")
                .font(.caption).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .alert("允许此 Proton 邮箱翻译？", isPresented: Binding(
            get: { pendingProton != nil }, set: { if !$0 { pendingProton = nil } })) {
                Button("取消", role: .cancel) { pendingProton = nil }
                Button("同意并开启") {
                    if let account = pendingProton {
                        privacy.setEnabled(true, accountID: account.id, isProton: true, confirmingProtonConsent: true)
                    }
                    pendingProton = nil
                }
            } message: {
                Text("端到端邮件的主题和正文会发给外部翻译服务，不含收件人地址。译文以明文保存在这台 Mac。")
            }
        .alert("允许向翻译服务外发？", isPresented: $confirmService) {
            Button("取消", role: .cancel) {}
            Button("同意") { privacy.grantServiceConsent(endpoint: pendingEndpoint) }
        } message: {
            Text("将邮件主题和正文发送至 \(TranslationPrivacySettings.serviceIdentity(pendingEndpoint) ?? "")，不含收件人地址。正文中本来包含的地址仍会随正文发送。")
        }
        .alert("清空所有译文缓存？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clearing = true
                Task {
                    defer { clearing = false }
                    do { try await SQLiteTranslationCache.shared.clear(); note = "译文缓存已清空" }
                    catch { note = "清空失败，缓存可能仍存在，请重试" }
                }
            }
        } message: { Text("删除所有账号（包括 Proton）的本机明文译文缓存。原信保持不变。") }
    }
}
