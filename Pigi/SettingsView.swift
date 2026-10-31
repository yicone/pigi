import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "通用"
        case accounts = "邮箱管理"
        case notifications = "通知"
        case archive = "同步"
        case shortcuts = "快捷键"
        case about = "关于"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .accounts: "tray.2"
            case .notifications: "bell"
            case .archive: "externaldrive.badge.icloud"
            case .shortcuts: "keyboard"
            case .about: "info.circle"
            }
        }
    }

    @State private var page: Page = .general
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 13.5))
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(page == item ? 0.09 : 0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 180)
            .background(Color.primary.opacity(0.04))

            Group {
                switch page {
                case .general: GeneralPage()
                case .accounts: AccountsPage()
                case .notifications: NotificationsPage()
                case .archive: SyncSettingsPage()
                case .shortcuts: ShortcutsPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 780, height: 600)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(14)
            .help("关闭")
        }
        .focusEffectDisabled()
    }
}

private struct GeneralPage: View {
    @Environment(LayoutState.self) private var layout
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("appearanceMode") private var appearance: AppAppearance = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "通用", note: "邮件阅读的常规选项。")
            HStack {
                Text("外观").font(.system(size: 13.5))
                Spacer()
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: appearance) { appearance.apply() }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("加载远程图片").font(.system(size: 13.5))
                    Text("打开后,邮件详情会自动加载正文里的远程图片。关闭时只显示邮件自带的内容,可在单封邮件的菜单里临时加载。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $loadRemoteImages).labelsHidden().toggleStyle(.switch)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("默认宽度展示邮箱全称").font(.system(size: 13.5))
                    Text("关闭时邮箱栏只显示邮箱名称,默认宽度较窄,放不下的部分直接截断,想看全称可以手动拉宽。打开后显示完整地址,并使用更宽的默认宽度。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $showFullEmail).labelsHidden().toggleStyle(.switch)
                    .onChange(of: showFullEmail) { layout.sidebarWidth = LayoutState.defaultWidth }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("在 Dock 中显示").font(.system(size: 13.5))
                    Text("关闭后 Dock 里不再有 pigi 的图标,只保留菜单栏图标和菜单栏面板;主窗口可以从面板里的「打开主窗口」打开。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $showInDock).labelsHidden().toggleStyle(.switch)
                    .onChange(of: showInDock) { DockPolicy.shown = showInDock }
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 32, leading: 32, bottom: 24, trailing: 32))
    }
}

/// Title and one line of explanation shared by every page.
private struct PageHeader: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(note)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FormLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 76, alignment: .trailing)
    }
}

// MARK: - Sync

private struct SyncSettingsPage: View {
    @Environment(AppState.self) private var state

    @State private var localDays = ArchiveSettings.windowDays
    @State private var cloudDays: Int?
    @State private var note: String?

    private static let localChoices = [7, 14, 30, 60, 90, 180, 365]
    private static let cloudChoices = [30, 90, 180, 365, 730, 0]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                title: "同步",
                note: "邮件保存在这台 Mac 的本地数据库里,不经过任何第三方服务器。"
            )

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 16) {
                GridRow {
                    FormLabel("拉取范围")
                    row(
                        Picker("", selection: Binding(
                            get: { cloudDays ?? 30 },
                            set: { change(cloud: $0) }
                        )) {
                            ForEach(choices(Self.cloudChoices, including: cloudDays ?? 30), id: \.self) { Text(label($0)).tag($0) }
                        }
                        .disabled(cloudDays == nil),
                        hint: "从邮箱服务器下载最近多久的邮件;调大后更早的邮件会在后台逐步下载"
                    )
                }
                GridRow {
                    FormLabel("列表保留")
                    row(
                        Picker("", selection: Binding(
                            get: { localDays },
                            set: { change(local: $0) }
                        )) {
                            ForEach(choices(Self.localChoices, including: localDays), id: \.self) { Text(label($0)).tag($0) }
                        },
                        hint: "邮件列表里显示最近多久的邮件,更早的仍可搜索到"
                    )
                }
            }

            if let note = note ?? state.archiveStatus {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(32)
        .task { cloudDays = try? await ArchiveClient().backfillDays() }
    }

    private func row(_ picker: some View, hint: String) -> some View {
        HStack(spacing: 12) {
            picker.labelsHidden().frame(width: 130)
            Text(hint).font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    private func choices(_ base: [Int], including current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted { rank($0) < rank($1) }
    }

    /// 0 means "everything", which is wider than any number of days.
    private func rank(_ days: Int) -> Int { days == 0 ? .max : days }

    private func label(_ days: Int) -> String {
        switch days {
        case 0: "全部"
        case 365: "1 年"
        case 730: "2 年"
        case 180: "半年"
        default: "\(days) 天"
        }
    }

    private func change(local days: Int) {
        localDays = days
        ArchiveSettings.windowDays = days
        Task { await state.syncFromArchive() }
    }

    private func change(cloud days: Int) {
        Task {
            do {
                try await ArchiveClient().setBackfillDays(days)
                cloudDays = days
                note = "拉取范围已改为 \(label(days))"
            } catch {
                note = "设置失败:\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    private let store = ShortcutStore.shared

    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var note: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "快捷键", note: "点一下右侧的按键,再按下新的组合即可修改;按 Esc 取消。")
            section("邮箱栏", ShortcutAction.allCases.filter(\.isSidebar))
            section("邮件", ShortcutAction.allCases.filter { !$0.isSidebar && !$0.isGlobal })
            section("全局(在任何应用里都可用)", ShortcutAction.allCases.filter(\.isGlobal))
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Button("恢复默认") { stopRecording(); note = nil; store.resetAll() }
                    .disabled(store.isDefault)
                Spacer()
            }
        }
        .padding(32)
        }
        .onDisappear(perform: stopRecording)
    }

    private func section(_ title: String, _ items: [ShortcutAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(items) { action in
                    HStack {
                        Text(action.title).font(.system(size: 13.5))
                        Spacer()
                        recorder(action)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    if action != items.last { Divider().opacity(0.5) }
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func recorder(_ action: ShortcutAction) -> some View {
        let active = recording == action
        return Button {
            active ? stopRecording() : startRecording(action)
        } label: {
            Text(active ? "按下新的快捷键…" : store.combo(action).display)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 130, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(active ? 0.04 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        note = nil
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Esc
            guard let combo = KeyCombo.from(event) else { return nil }
            if let clash = store.set(combo, for: action) {
                note = "「\(combo.display)」已被「\(clash.title)」使用,请换一个。"
            } else {
                note = nil
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}


private struct AboutPage: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "关于", note: "版本信息。此 fork 已关闭在线更新。")
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("pigi").font(.system(size: 20, weight: .semibold))
                    Text("版本 \(AppVersion.display)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                status
                if let info = updater.available {
                    Text(info.notes.isEmpty ? "新版本 \(info.version)" : info.notes)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if updater.phase != .disabled {
                    HStack(spacing: 10) {
                        if let info = updater.available {
                            Button("更新到 \(info.version)") { Task { await updater.install() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(updater.isBusy)
                        }
                        Button("检查更新") { Task { await updater.check() } }
                            .disabled(updater.isBusy)
                        if updater.isBusy { ProgressView().controlSize(.small) }
                    }
                }
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 32, leading: 32, bottom: 24, trailing: 32))
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .idle: Text("尚未检查更新").foregroundStyle(.secondary)
        case .checking: Text("正在检查更新…").foregroundStyle(.secondary)
        case .upToDate: Label("已是最新版本", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let info): Label("有新版本 \(info.version)", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .downloading: Text("正在下载…").foregroundStyle(.secondary)
        case .installing: Text("正在安装,稍后自动重启…").foregroundStyle(.secondary)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .disabled: Text("在线更新已关闭").foregroundStyle(.secondary)
        }
    }
}


// MARK: - Mailbox management

private struct AccountsPage: View {
    @Environment(AppState.self) private var state
    @State private var adding = false
    @State private var removing: Account?
    @State private var failure: String?
    @State private var status: [String: ArchiveAccount] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeader(
                    title: "邮箱管理",
                    note: "关掉开关只是不在窗口和菜单栏面板里显示,pigi 仍会在后台同步这个邮箱,再打开就能看到。"
                )
                Spacer(minLength: 12)
                Menu {
                    Button("Gmail(登录授权)") { Task { await state.addGmailAccount() } }
                    Button("其他邮箱(IMAP)…") { adding = true }
                } label: {
                    Label("添加邮箱", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, 40)
            }

            GmailClientField()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.allAccounts) { account in
                        row(account)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(EdgeInsets(top: 32, leading: 32, bottom: 24, trailing: 32))
        .sheet(isPresented: $adding) { AddIMAPSheet() }
        .task {
            while !Task.isCancelled {
                if let list = try? await ArchiveClient().accounts() {
                    status = Dictionary(list.map { ($0.email, $0) }, uniquingKeysWith: { first, _ in first })
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert(
            "删除 \(removing?.email ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    do { try await state.removeAccount(account.id); failure = nil }
                    catch { failure = "删除失败:\(error.localizedDescription)" }
                }
            }
        } message: { _ in
            Text("pigi 会停止同步这个邮箱,并清除这台 Mac 上保存的它的全部邮件(邮箱服务器上的邮件不受影响)。")
        }
    }

    /// Only what needs attention: an error, or a first pull still running.
    @ViewBuilder
    private func syncState(_ item: ArchiveAccount?) -> some View {
        if let error = item?.lastError {
            Label("出错", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5)).foregroundStyle(.red)
                .help(error)
        } else if let item, item.backfillDone != 1 {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("拉取中 · \(item.stored) 封").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ account: Account) -> some View {
        let shown = Binding(
            get: { !state.hiddenAccounts.contains(account.id) },
            set: { state.setHidden(!$0, for: account.id) }
        )
        return HStack(spacing: 10) {
            Text(account.email).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Text(account.kind.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())
            Spacer()
            syncState(status[account.id])
            Toggle("", isOn: shown).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(shown.wrappedValue ? "在窗口和面板中显示" : "已隐藏,仍在后台同步")
            Button { removing = account } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }
}

/// Gmail needs the user's own Google OAuth client; IMAP mailboxes do not.
private struct GmailClientField: View {
    @State private var clientID = GmailAuth.clientID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Gmail 客户端 ID").font(.system(size: 12.5)).foregroundStyle(.secondary)
                TextField("", text: $clientID, prompt: Text("xxxxxxxx.apps.googleusercontent.com"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: clientID) { _, value in GmailAuth.clientID = value }
                if GmailAuth.isConfigured {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text("添加 Gmail 前需要填入你自己在 Google Cloud 创建的 OAuth 客户端 ID。")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            + Text(" 查看图文教程")
                .font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
        }
        .onTapGesture {
            if let url = URL(string: "https://pigi.xiezhaoye.site/gmail-api/") { NSWorkspace.shared.open(url) }
        }
    }
}

private struct AddIMAPSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var hostEdited = false
    @State private var working = false
    @State private var failure: String?

    private static let hosts: [String: String] = [
        "hotmail.com": "outlook.office365.com", "outlook.com": "outlook.office365.com",
        "live.com": "outlook.office365.com", "msn.com": "outlook.office365.com",
        "qq.com": "imap.qq.com", "foxmail.com": "imap.qq.com",
        "163.com": "imap.163.com", "126.com": "imap.126.com", "yeah.net": "imap.yeah.net",
        "gmail.com": "imap.gmail.com", "icloud.com": "imap.mail.me.com", "me.com": "imap.mail.me.com",
        "yahoo.com": "imap.mail.yahoo.com", "sina.com": "imap.sina.com", "139.com": "imap.139.com",
    ]

    private static func guessHost(_ email: String) -> String {
        guard let domain = email.split(separator: "@").last, email.contains("@"), !domain.isEmpty else { return "" }
        let key = domain.lowercased()
        return hosts[key] ?? "imap.\(key)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 IMAP 邮箱").font(.system(size: 16, weight: .semibold))
            Text("pigi 直接用 IMAP 登录并同步。多数邮箱需要先在网页设置里开启 IMAP,并使用授权码或应用专用密码,而不是登录密码。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    FormLabel("邮箱")
                    TextField("", text: $email, prompt: Text("name@example.com")).textFieldStyle(.roundedBorder)
                        .onChange(of: email) { if !hostEdited { host = Self.guessHost(email) } }
                }
                GridRow {
                    FormLabel("密码")
                    SecureField("", text: $password, prompt: Text("密码或授权码")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    FormLabel("服务器")
                    HStack {
                        TextField("", text: $host, prompt: Text("imap.example.com")).textFieldStyle(.roundedBorder)
                            .onChange(of: host) { if host != Self.guessHost(email) { hostEdited = true } }
                        TextField("", text: $port).textFieldStyle(.roundedBorder).frame(width: 64)
                    }
                }
            }
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("正在登录…").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || email.isEmpty || password.isEmpty || host.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func add() async {
        working = true
        defer { working = false }
        do {
            try await state.addIMAPAccount(
                email: email.trimmingCharacters(in: .whitespaces), password: password,
                host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 993)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}


// MARK: - Notifications

private struct NotificationsPage: View {
    @State private var notifier = MailNotifier.shared
    @State private var enabled = MailNotifier.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "通知", note: "收到新邮件时弹出系统通知并发出提示音。隐藏的邮箱不会通知。")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("新邮件通知").font(.system(size: 13.5))
                    Text("pigi 在运行时(包括只留在菜单栏)收到新邮件就提醒。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                    .onChange(of: enabled) {
                        MailNotifier.enabled = enabled
                        if enabled && notifier.access == .notDetermined { Task { await notifier.requestAccess() } }
                    }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 13))
                    Spacer()
                    if notifier.access == .notDetermined {
                        Button("请求授权") { Task { await notifier.requestAccess() } }
                    }
                    Button("打开系统通知设置") { notifier.openSystemSettings() }
                }
                if let hint {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("通知停留时间由 macOS 的临时或持久样式管理，系统不提供按秒设置的公开接口。验证码通知可在选项或展开后选择“复制验证码”。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(EdgeInsets(top: 32, leading: 32, bottom: 24, trailing: 32))
        .task { await notifier.refresh() }
    }

    private var color: Color {
        switch notifier.access {
        case .allowed: notifier.soundOn ? .green : .orange
        case .denied: .red
        default: .gray
        }
    }

    private var statusText: String {
        switch notifier.access {
        case .unknown: "正在检查系统通知权限…"
        case .notDetermined: "系统还没有授权 pigi 发通知"
        case .allowed: notifier.soundOn ? "系统通知已开启,带提示音" : "系统通知已开启,但提示音被关掉了"
        case .denied: "系统通知被关闭"
        }
    }

    private var hint: String? {
        switch notifier.access {
        case .denied: "请在系统设置 → 通知 → pigi 里允许通知。"
        case .allowed where !notifier.soundOn: "请在系统设置 → 通知 → pigi 里打开「播放通知声音」。"
        default: nil
        }
    }
}
