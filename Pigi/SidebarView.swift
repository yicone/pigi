import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Environment(LayoutState.self) private var layout
    @State private var renaming: SidebarGroup?
    @State private var newName = ""
    @State private var renamingAccount: Account?
    @State private var accountName = ""
    @State private var dropTarget: String?
    @State private var dragging: String?

    /// Narrow sidebar: addresses lose their domain.
    @AppStorage("showFullEmail") private var showFullEmail = false
    /// Names only unless the setting asks for full addresses; text that doesn't fit is cut off.
    private var compact: Bool { !showFullEmail }

    var body: some View {
        VStack(spacing: 0) {
            // The window buttons are drawn by AppKit in this row.
            HStack(spacing: 0) {
                BrandLockup()
                    .frame(width: min(56, max(0, layout.sidebarWidth - SidebarMetrics.trafficLightsX - 70)), height: 22)
                Spacer(minLength: 0)
            }
            .padding(.leading, SidebarMetrics.trafficLightsX + 66)
            .padding(.trailing, 4)
            .frame(height: SidebarMetrics.headerHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(
                        title: "所有邮件",
                        systemImage: "tray.2",
                        count: state.unreadCount(.all),
                        isSelected: state.scope == .all
                    ) { state.select(.all) }

                    ForEach(state.sidebarGroups) { entry in
                        let collapsed = state.collapsedGroups.contains(entry.id)
                        let groupLine = groupDropLine(entry.id)
                        VStack(alignment: .leading, spacing: 2) {
                            GroupHeader(
                                group: entry.group,
                                count: entry.accounts.count,
                                isCollapsed: collapsed,
                                onAddGmail: { Task { await state.addGmailAccount(to: entry.id) } },
                                onRename: { newName = entry.group.name; renaming = entry }
                            )
                            .overlay(alignment: .top) { if groupLine == .top { DropLine() } }
                            .onDrag {
                                dragging = "group:" + entry.id
                                return NSItemProvider(object: "group:\(entry.id)" as NSString)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                dropTarget = nil
                                dragging = nil
                                guard let item = items.first else { return false }
                                withAnimation(.snappy(duration: 0.28)) {
                                    if item.hasPrefix("group:") {
                                        state.moveGroup(String(item.dropFirst(6)), onto: entry.id)
                                    } else if item.hasPrefix("acct:") {
                                        state.moveAccount(String(item.dropFirst(5)), toGroup: entry.id)
                                    }
                                }
                                return item.hasPrefix("group:") || item.hasPrefix("acct:")
                            } isTargeted: { dropTarget = $0 ? "g:" + entry.id : (dropTarget == "g:" + entry.id ? nil : dropTarget) }
                            if !collapsed {
                                ForEach(entry.accounts) { account in
                                    let rowLine = accountDropLine(account.id, in: entry)
                                    SidebarRow(
                                        title: state.accountAliases[account.id] ?? (compact ? String(account.email.split(separator: "@").first ?? "") : account.email),
                                        avatarName: state.accountAliases[account.id] ?? account.name,
                                        avatarURL: state.accountAliases[account.id] == nil ? account.avatarURL : nil,
                                        count: state.unreadCount(.account(account.id)),
                                        isSelected: state.scope == .account(account.id),
                                        indent: 6,
                                        onRename: { accountName = state.accountAliases[account.id] ?? ""; renamingAccount = account },
                                        onRemove: account.kind == .gmail ? { state.removeGmailAccount(account.id) } : nil
                                    ) { state.select(.account(account.id)) }
                                    .overlay(alignment: .top) { if rowLine == .top { DropLine() } }
                                    .overlay(alignment: .bottom) { if rowLine == .bottom { DropLine() } }
                                    .onDrag {
                                        dragging = "acct:" + account.id
                                        return NSItemProvider(object: "acct:\(account.id)" as NSString)
                                    }
                                    .dropDestination(for: String.self) { items, _ in
                                        dropTarget = nil
                                        dragging = nil
                                        guard let item = items.first, item.hasPrefix("acct:") else { return false }
                                        withAnimation(.snappy(duration: 0.28)) {
                                            state.moveAccount(String(item.dropFirst(5)), toGroup: entry.id, onto: account.id)
                                        }
                                        return true
                                    } isTargeted: { dropTarget = $0 ? "a:" + account.id : (dropTarget == "a:" + account.id ? nil : dropTarget) }
                                }
                            }
                        }
                        .overlay(alignment: .bottom) { if groupLine == .bottom { DropLine() } }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .padding(.top, 9)

            footer
        }
        .focusEffectDisabled()
        .alert("修改显示名称", isPresented: Binding(get: { renamingAccount != nil }, set: { if !$0 { renamingAccount = nil } })) {
            TextField("显示名称", text: $accountName)
            Button("取消", role: .cancel) {}
            Button("好") { if let renamingAccount { state.setAlias(accountName, for: renamingAccount.id) } }
        } message: {
            Text("留空则恢复默认名称和头像。")
        }
        .alert("修改分组名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("分组名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("好") { if let renaming { state.renameGroup(renaming.id, to: newName) } }
        }
    }


    private enum LinePosition { case top, bottom }

    /// Where the line for a group drop goes: above the header when moving up, below the whole group otherwise.
    private func groupDropLine(_ id: String) -> LinePosition? {
        guard dropTarget == "g:" + id, let dragging else { return nil }
        if dragging.hasPrefix("group:") {
            let ids = state.sidebarGroups.map(\.id)
            guard let from = ids.firstIndex(of: String(dragging.dropFirst(6))), let to = ids.firstIndex(of: id), from != to
            else { return nil }
            return from > to ? .top : .bottom
        }
        return .bottom
    }

    /// Line for dropping a mailbox on another: it lands before the target, or after it when moving down within a group.
    private func accountDropLine(_ id: String, in entry: SidebarGroup) -> LinePosition? {
        guard dropTarget == "a:" + id, let dragging, dragging.hasPrefix("acct:") else { return nil }
        let moved = String(dragging.dropFirst(5))
        guard moved != id else { return nil }
        if let from = entry.accounts.firstIndex(where: { $0.id == moved }),
           let to = entry.accounts.firstIndex(where: { $0.id == id }), from < to { return .bottom }
        return .top
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            SyncStatus()
            HStack {
                FooterButton(systemImage: "folder.badge.plus", help: "添加分组") {
                    let id = state.addGroup(named: "新分组")
                    newName = "新分组"
                    renaming = state.sidebarGroups.first { $0.id == id }
                }
                Spacer()
                FooterButton(systemImage: "gearshape", help: "设置") { layout.showingSettings = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The sidebar folded to a column of avatars; hovering one shows the full address.
struct SidebarRail: View {
    @Environment(AppState.self) private var state
    @Environment(LayoutState.self) private var layout
    /// True when the sidebar is fully folded: the unfold button then sits beside the window buttons.
    var folded = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: SidebarMetrics.headerHeight)
            ScrollView {
                VStack(spacing: 8) {
                    RailButton(isSelected: state.scope == .all, help: "所有邮件", count: state.unreadCount(.all)) {
                        state.select(.all)
                    } content: {
                        Image(systemName: "tray.2").font(.system(size: 15)).frame(width: 30, height: 30)
                    }
                    ForEach(state.sidebarGroups.filter { !$0.accounts.isEmpty }) { entry in
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 22, height: 2)
                            .padding(.vertical, 4)
                            .help(entry.group.name)
                        ForEach(entry.accounts) { account in
                            RailButton(
                                isSelected: state.scope == .account(account.id),
                                help: account.email,
                                count: state.unreadCount(.account(account.id))
                            ) {
                                state.select(.account(account.id))
                            } content: {
                                AvatarView(
                                    name: state.accountAliases[account.id] ?? account.name,
                                    size: 30,
                                    imageURL: state.accountAliases[account.id] == nil ? account.avatarURL : nil
                                )
                            }
                        }
                    }
                }
                .padding(.top, 9)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .padding(.trailing, folded ? 16 : 0)
            FooterButton(systemImage: "gearshape", help: "设置") { layout.showingSettings = true }
                .padding(.vertical, 10)
                .padding(.trailing, folded ? 16 : 0)
        }
        .focusEffectDisabled()
    }
}

private struct BrandLockup: View {
    var body: some View {
        Image("BrandLockup")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .accessibilityLabel("pigi")
    }
}

struct RailButton<Content: View>: View {
    let isSelected: Bool
    let help: String
    let count: Int
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? (hovering ? 0.14 : 0.08) : (hovering ? 0.07 : 0)))
                )
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4.5)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 2, y: -2)
                    }
                }
                .overlay(alignment: .leading) { if isSelected { SelectionDot().offset(x: -17) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

private struct SyncStatus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isSyncing || state.sidebarError != nil {
            HStack(spacing: 6) {
                if state.isSyncing { ProgressView().controlSize(.small) }
                if let error = state.sidebarError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(error)
                }
            }
        }
    }
}

struct FooterButton: View {
    let systemImage: String
    var width: CGFloat = 28
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: width, height: 28)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

private struct GroupHeader: View {
    @Environment(AppState.self) private var state
    let group: AccountGroup
    let count: Int
    let isCollapsed: Bool
    let onAddGmail: () -> Void
    let onRename: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { state.toggleGroup(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(group.name)
                        .font(.system(size: 14, weight: .bold))
                    Text("\(count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("修改分组名称", action: onRename)
            Menu("添加邮箱") { addItems }
            if count == 0 { Button("删除分组", role: .destructive) { state.removeGroupIfEmpty(group.id) } }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var addItems: some View {
        Button("添加 Gmail 邮箱", action: onAddGmail)
    }
}

private struct DropLine: View {
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.4)).frame(height: 2).padding(.horizontal, 4).offset(y: 0)
    }
}

struct SelectionDot: View {
    var body: some View { Circle().fill(Color.orange).frame(width: 8, height: 8) }
}

private struct SidebarRow: View {
    let title: String
    var systemImage: String?
    var avatarName: String?
    var avatarURL: URL?
    let count: Int
    let isSelected: Bool
    var indent: CGFloat = 0
    var onRename: (() -> Void)?
    var onRemove: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14))
                        .frame(width: 20)
                } else if let avatarName {
                    AvatarView(name: avatarName, size: 20, imageURL: avatarURL)
                }
                Text(title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 10 + indent)
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? (hovering ? 0.14 : 0.08) : (hovering ? 0.07 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) { if isSelected { SelectionDot().offset(x: -8) } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if let onRename { Button("修改显示名称", action: onRename) }
            if let onRemove {
                Button("移除此账号", role: .destructive, action: onRemove)
            }
        }
    }
}
