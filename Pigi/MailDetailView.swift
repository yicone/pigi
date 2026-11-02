import SwiftUI

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
                        Button(allowRemoteContent ? "屏蔽远程图片" : "加载远程图片") { remoteOverride = !allowRemoteContent }
                    }
                // A thin light-grey rule that stops short of both edges.
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, inset)
                VStack(spacing: 0) {
                    Group {
                        if mail.bodyLoaded {
                            MailHTMLView(body: mail.body, isHTML: mail.isHTML, allowRemoteContent: allowRemoteContent,
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
                Text(mail.subject)
                    .font(.system(size: 17))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.top, 6)
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

    /// Copy-code and unsubscribe, each only when the engine found one in this mail.
    @ViewBuilder
    private func actions(_ mail: Mail) -> some View {
        HStack(spacing: 8) {
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
