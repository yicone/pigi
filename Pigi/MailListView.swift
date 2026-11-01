import SwiftUI

struct MailListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            if state.sections.isEmpty {
                Spacer()
                Text(state.readFilter == .unread ? "没有未读邮件" : "没有邮件")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(state.sections) { section in
                            HStack {
                                Text(section.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if section.id == state.sections.first?.id, state.unreadVisibleCount > 0 {
                                    MarkAllReadLink { state.confirmMarkAllRead(state.visibleMails) }
                                        .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            ForEach(section.mails) { mail in
                                MailRow(mail: mail, showsAccount: state.scope == .all,
                                        isSelected: state.selectedMailID == mail.id) { state.open(mail) }
                                    .id(mail.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: state.selectedMailID) {
                    if let id = state.selectedMailID { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
                }
            }
        }
        .background {
            Group {
                Button("") { state.moveSelection(1) }.shortcut(.nextMail)
                Button("") { state.moveSelection(-1) }.shortcut(.previousMail)
            }
            .opacity(0).allowsHitTesting(false)
        }
    }

    private var searchField: some View {
        @Bindable var state = state
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索邮件", text: $state.searchText)
                .textFieldStyle(.plain)
                .onChange(of: state.searchText) { state.searchChanged() }
                .onExitCommand { state.endSearch() }
            if !state.searchText.isEmpty {
                Button { state.endSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var header: some View {
        return HStack(spacing: 10) {
            Text(state.scopeTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if case .account(let email) = state.scope, state.isReadOnly(email) {
                Menu {
                    Button("收件箱") { state.selectedProtonLabel = nil }
                    Button("所有邮件") { state.selectedProtonLabel = "ALL" }
                    Button("星标") { state.selectedProtonLabel = "STARRED" }
                    Button("归档") { state.selectedProtonLabel = "ARCHIVE" }
                    Button("已发送") { state.selectedProtonLabel = "SENT" }
                    Button("草稿") { state.selectedProtonLabel = "DRAFT" }
                    Button("垃圾箱") { state.selectedProtonLabel = "TRASH" }
                    Button("垃圾邮件") { state.selectedProtonLabel = "SPAM" }
                    Divider()
                    ForEach(state.protonLabels[email] ?? []) { label in
                        Button(label.name) { state.selectedProtonLabel = "proton:" + label.id }
                    }
                } label: { Text(state.protonLabelTitle(email)) }
                .help("当前：" + (state.selectedProtonLabel ?? "收件箱"))
            }
            MailRefreshButton()
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .frame(height: 55)
    }
}

struct MailRow: View {
    @Environment(AppState.self) private var state
    let mail: Mail
    let showsAccount: Bool
    let isSelected: Bool
    var verticalPadding: CGFloat = 9
    /// Show the mailbox without its @domain (menu bar panel).
    var shortAccount = false
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    AvatarView(name: mail.senderName, size: 36)
                    if mail.isUnread {
                        Circle().fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .padding(1.5)
                            .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
                            .offset(x: -4.5, y: -4.5)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(mail.senderName)
                            .font(.system(size: 14, weight: mail.isUnread ? .semibold : .regular))
                            .lineLimit(1)
                        if mail.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 4)
                        Text(AppState.shortTime(mail.date))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .opacity(hovering && hasActions ? 0 : 1)
                    }
                    HStack(spacing: 6) {
                        Text(mail.subject)
                            .font(.system(size: 13, weight: mail.isUnread ? .medium : .regular))
                        Text(mail.snippet)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                    if showsAccount {
                        Text(shortAccount ? (mail.accountID.split(separator: "@").first.map(String.init) ?? mail.accountID) : mail.accountID)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.07) : Color.primary.opacity(hovering ? 0.045 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering && hasActions {
                HStack(spacing: 6) {
                    if mail.unsubKind != nil {
                        GlassPill(title: "退订", systemImage: "envelope.badge.shield.half.filled", compact: true) {
                            state.unsubTarget = mail
                        }
                    }
                    if mail.code != nil {
                        GlassPill(title: "复制验证码", systemImage: "doc.on.doc", compact: true) { state.copyCode(mail) }
                    }
                }
                .padding(.trailing, 8)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
            }
        }
        .scaleEffect(hovering ? 1.008 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .contextMenu {
            if !state.isReadOnly(mail.accountID) {
            Button("归档") { state.archive(mail.id) }
            Button(mail.isStarred ? "取消星标" : "加星标") { state.toggleStar(mail.id) }
            Button("删除") { state.delete(mail.id) }
            Divider()
            Button(mail.isUnread ? "标为已读" : "标为未读") { state.toggleUnread(mail.id) }
            } else { Text("Proton 邮箱为只读") }
        }
    }

    private var hasActions: Bool { mail.code != nil || mail.unsubKind != nil }
}

/// The small text link beside the first date heading.
struct MarkAllReadLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("全部已读")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor.opacity(hovering ? 1 : 0.8))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
