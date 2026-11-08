import SwiftUI
#if canImport(PigiCore)
import PigiCore
#endif

struct MailDetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let mail = state.selectedMail {
            MailDetailContent(mail: mail)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 34, weight: .light))
                Text("选择一封邮件")
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One opened mail: header with actions, then the body. `onBack` adds a back arrow (menu bar panel).
struct MailDetailContent: View {
    @Environment(AppState.self) private var state
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true
    /// Per-mail choice from the menu; nil follows the setting.
    @State private var remoteOverride: Bool?
    @State var translation = MailTranslationReader()
    private var allowRemoteContent: Bool { remoteOverride ?? loadRemoteImages }
    let mail: Mail
    var inset: CGFloat = 26
    var onBack: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            head(mail)
                    .contextMenu {
                        if !state.isReadOnly(mail.accountID) {
                        Button("归档") { state.archive(mail.id) }
                        Button(mail.isStarred ? "取消星标" : "加星标") { state.toggleStar(mail.id) }
                        Button("删除") { state.delete(mail.id) }
                        Divider()
                        Button(mail.isUnread ? "标为已读" : "标为未读") { state.toggleUnread(mail.id) }
                        } else { Text("Proton 邮箱为只读") }
                        Button(translation.actionTitle(account: mail.accountID, isProton: isProton)) { translate() }
                            .disabled(!mail.bodyLoaded || translation.isTranslating)
                            .accessibilityIdentifier("mail.translation.menu")
                        Button(allowRemoteContent ? "屏蔽远程图片" : "加载远程图片") { remoteOverride = !allowRemoteContent }
                    }
                // A thin light-grey rule that stops short of both edges.
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, inset)
                VStack(spacing: 0) {
                    if shouldShowTranslationBanner {
                        translationBanner
                    }
                    Group {
                        if mail.bodyLoaded {
                            MailHTMLView(body: translation.showingTranslation ? (translation.translatedBody ?? mail.body) : mail.body,
                                         isHTML: mail.isHTML, allowRemoteContent: allowRemoteContent,
                                         inlineImages: state.inlineImagesByMailID[mail.id] ?? [],
                                         horizontalInset: inset)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            .foregroundStyle(.primary)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: mail.id) { remoteOverride = nil }
            .onChange(of: translationSource, initial: true) {
                translation.reset()
                translation.select(mailID: mail.id)
                translation.refreshConfiguration()
            }
            .onChange(of: translation.permission(account: mail.accountID, isProton: isProton)) { _, permission in
                if permission == .disabled || permission == .notConfigured { translation.reset() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                translation.refreshConfiguration()
            }
            .onReceive(NotificationCenter.default.publisher(for: KeychainKeyStore.didChangeNotification)) { _ in
                translation.reset()
                translation.refreshConfiguration()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                translation.refreshConfiguration()
            }
            .onDisappear { translation.cancel(mailID: mail.id) }
            .alert("允许向翻译服务外发？", isPresented: Binding(
                get: { translation.pendingConsent != nil },
                set: { if !$0 { translation.dismissConsent() } })) {
                    Button("取消", role: .cancel) { translation.dismissConsent() }
                    Button("同意并翻译") { translation.confirmConsent() }
                } message: {
                    if let request = translation.pendingConsent {
                        Text((request.requiresAccountConsent ? "此 Proton 邮箱的端到端邮件将交给外部翻译服务。" : "")
                            + "将邮件主题和正文发送至 \(TranslationPrivacySettings.serviceIdentity(request.endpoint) ?? "")，不含收件人地址。正文中本来包含的地址仍会随正文发送。译文以明文保存在这台 Mac。")
                    }
                }
    }

    private var isProton: Bool { state.isReadOnly(mail.accountID) }

    private var shouldShowTranslationBanner: Bool {
        mail.bodyLoaded && (translation.isTranslating || translation.translatedBody != nil || translation.errorMessage != nil
            || !TranslationLanguage.isPrimarilyChinese(String((mail.subject + "\n" + RemoteMapping.plainText(mail.body)).prefix(4_000))))
    }

    private func translate() {
        translation.activate(account: mail.accountID, id: mail.remoteID, mailID: mail.id, isProton: isProton)
    }

    private var translationBanner: some View {
        HStack(spacing: 8) {
            if translation.isTranslating { ProgressView().controlSize(.small) }
            Button(action: translate) {
                Text(translation.bannerMessage(signatureFailed: mail.signatureStatus == "failed"))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .disabled(!mail.bodyLoaded || translation.isTranslating)
            if translation.isTranslating {
                Button("取消") { translation.cancel(mailID: mail.id) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mail.translation.cancel")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, inset)
        .padding(.vertical, 8)
        .accessibilityIdentifier(translation.errorMessage == nil ? "mail.translation.banner" : "mail.translation.error")
    }

    private var translationSource: TranslationSource {
        TranslationSource(id: mail.id, account: mail.accountID, remoteID: mail.remoteID,
                          subject: mail.subject, body: mail.body, isHTML: mail.isHTML, loaded: mail.bodyLoaded)
    }

    private struct TranslationSource: Equatable {
        let id: String
        let account: String
        let remoteID: String
        let subject: String
        let body: String
        let isHTML: Bool
        let loaded: Bool
    }

    /// Sender, addresses, date and subject; the panel also has a back button.
    private func head(_ mail: Mail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let onBack {
                GlassCircleButton(systemImage: "chevron.left", action: onBack)
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(mail.senderName).font(.system(size: 15, weight: .medium))
                    Text(mail.senderEmail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("收件人:\(mail.accountID)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(mail.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if mail.signatureStatus == "verified" {
                    Label("签名已验证", systemImage: "checkmark.shield")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if mail.signatureStatus == "failed" {
                    Label("签名校验失败 · 请谨慎对待邮件内容", systemImage: "exclamationmark.shield")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Text(translation.showingTranslation ? (translation.translatedSubject ?? mail.subject) : mail.subject)
                    .font(.system(size: 17))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.top, 6)
                if translation.showingTranslation, translation.translatedSubject != nil {
                    Text(mail.subject)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mail.translation.originalSubject")
                }
            }
            Spacer(minLength: 12)
            actions(mail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Translation follows the service settings; mail-specific actions follow engine metadata.
    @ViewBuilder
    private func actions(_ mail: Mail) -> some View {
        HStack(spacing: 8) {
            if translation.isAvailable {
                if translation.isTranslating { ProgressView().controlSize(.small) }
                GlassPill(title: translation.isTranslating ? "翻译中…" : (translation.showingTranslation ? "原文" : "翻译"),
                          systemImage: "character.bubble") {
                    translate()
                }
                .disabled(!mail.bodyLoaded || translation.isTranslating)
                .accessibilityIdentifier("mail.translation.toggle")
                .help(translation.showingTranslation ? "显示原文" : "使用已配置的服务翻译为简体中文")
            }
            if mail.code != nil {
                GlassPill(title: "复制验证码", systemImage: "doc.on.doc") { state.copyCode(mail) }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if mail.unsubKind != nil {
                GlassPill(title: "退订", systemImage: "envelope.badge.shield.half.filled") { state.unsubTarget = mail }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: mail.code)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: mail.unsubKind)
    }
}
