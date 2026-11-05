import AppKit
import Foundation
import Observation
#if canImport(PigiCore)
import PigiCore
#endif

@MainActor
@Observable
final class AppState {

    private(set) var gmailAccounts: [Account] = GmailStore.emails.map(AppState.gmailAccount)
    /// Mailboxes the engine pulls over IMAP; the engine is the source of truth, this is the last list it gave.
    private(set) var imapAccounts: [Account] = (UserDefaults.standard.stringArray(forKey: "imapAccounts") ?? []).map(AppState.imapAccount)
    private(set) var protonAccounts: [Account] = (UserDefaults.standard.stringArray(forKey: "protonAccounts") ?? []).map(AppState.protonAccount)
    private(set) var protonLabels: [String: [ProtonLabel]] = [:]
    var selectedProtonLabel: String? = nil
    /// Mailboxes switched off in 邮箱管理: still pulled and kept by the engine, just not shown in the window or the panel.
    var hiddenAccounts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenAccounts") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenAccounts).sorted(), forKey: "hiddenAccounts") }
    }
    var mails: [Mail] = MailCache.load() { didSet { scheduleCacheSave() } }
    private var cacheSave: Task<Void, Never>?
    /// Unread mails that arrived in the latest pulls and have not been announced yet.
    private var freshMails: [Mail] = []

    /// Writes the headers to disk shortly after the last change.
    private func scheduleCacheSave() {
        cacheSave?.cancel()
        cacheSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            MailCache.save(self.mails)
        }
    }
    private var gmailClients: [String: GmailClient] = [:]
    private var avatarURLs: [String: URL] =
        (UserDefaults.standard.dictionary(forKey: "gmailAvatars") as? [String: String] ?? [:])
            .compactMapValues { URL(string: $0) }

    var scope: Scope = .all
    var readFilter: ReadFilter = .all { didSet { stayVisible = [] } }
    /// Mails read while the list shows only unread stay put until the list context changes.
    private(set) var stayVisible: Set<String> = []
    var selectedMailID: String?
    var groups: [AccountGroup] = AccountGroup.load() { didSet { AccountGroup.save(groups) } }
    var collapsedGroups: Set<String> = []
    /// Display names the user gave to mailboxes, by address.
    var accountAliases: [String: String] = (UserDefaults.standard.dictionary(forKey: "accountAliases") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(accountAliases, forKey: "accountAliases") }
    }

    var isSearching = false
    var searchText = "" { didSet { stayVisible = [] } }
    /// Ids returned by the server's full-text search for the current query.
    private var searchHits: Set<String> = []
    private var searchTask: Task<Void, Never>?

    private var activeSyncs = 0
    var isSyncing: Bool { activeSyncs > 0 || archiveCatchingUp }
    var syncError: String?
    /// Shared by mailbox settings and the sidebar; an ordinary refresh must not
    /// erase a failed credential save. A successful account update clears it.
    var credentialError: String?
    private(set) var serverCredentialError: String?
    /// Mailboxes that currently cannot reach their server; retried on the next poll.
    private(set) var networkErrorSummary: String?
    var displayedCredentialError: String? { credentialError ?? serverCredentialError }
    var sidebarError: String? { displayedCredentialError ?? syncError }
    var isRefreshing = false

    private static let syncWindow: TimeInterval = 30 * 24 * 3600
    /// Mail older than this many days is not kept in the self-hosted list.
    private static var gmailLiveDays: Int { min(ArchiveSettings.windowDays, 30) }

    var archiveStatus: String?
    var isArchiveSyncing = false
    private var archiveDirty = false
    @ObservationIgnored private var archiveFullRequested = false
    @ObservationIgnored private var archiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var archiveFailure: String?
    /// True while a large backlog is being pulled, so the sidebar can show progress.
    private var archiveCatchingUp = false

    // MARK: - Derived

    /// Every mailbox the engine syncs, including read-only Proton accounts.
    private var syncedAccountIDs: Set<String> {
        Set(gmailAccounts.map(\.id)).union(imapAccounts.map(\.id)).union(protonAccounts.map(\.id))
    }

    /// Every mailbox the app knows, shown or not.
    var allAccounts: [Account] {
        let gmail = gmailAccounts.map { account -> Account in
            var account = account
            account.avatarURL = avatarURLs[account.id]
            return account
        }
        return gmail + imapAccounts + protonAccounts
    }

    /// The mailboxes switched on, which is what the sidebar, the picker and "all mail" show.
    var accounts: [Account] { allAccounts.filter { !hiddenAccounts.contains($0.id) } }

    var scopeTitle: String {
        switch scope {
        case .all: "所有邮件"
        case .account(let id): id
        }
    }

    var visibleMails: [Mail] {
        filteredMails(scope: scope, readFilter: readFilter, stay: stayVisible, query: searchText)
    }

    /// The list for a scope, filter and search; the main window and the menu bar panel each ask with their own.
    func filteredMails(scope: Scope, readFilter: ReadFilter, stay: Set<String>, query: String) -> [Mail] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return mails
            .filter { mail in
                switch scope {
                case .all: !hiddenAccounts.contains(mail.accountID)
                case .account(let id): mail.accountID == id
                }
            }
            .filter { mail in
                guard isReadOnly(mail.accountID), query.isEmpty else { return true }
                let label: String
                if case .account = scope { label = selectedProtonLabel ?? "INBOX" } else { label = "INBOX" }
                return mail.labels?.contains(label) == true
            }
            .filter { readFilter == .all || $0.isUnread || stay.contains($0.id) }
            .filter {
                query.isEmpty
                    || searchHits.contains($0.id)
                    || $0.subject.localizedCaseInsensitiveContains(query)
                    || $0.senderName.localizedCaseInsensitiveContains(query)
                    || $0.snippet.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.date > $1.date }
    }

    var sections: [MailSection] { Self.sections(of: visibleMails) }

    static func sections(of list: [Mail]) -> [MailSection] {
        var order: [String] = []
        var buckets: [String: [Mail]] = [:]
        for mail in list {
            let title = sectionTitle(for: mail.date)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(mail)
        }
        return order.map { MailSection(title: $0, mails: buckets[$0] ?? []) }
    }

    /// Unread mails across every mailbox, for the menu bar.
    var unreadTotal: Int {
        mails.filter { $0.isUnread && !hiddenAccounts.contains($0.accountID) && isInboxMail($0) }.count
    }

    private func isInboxMail(_ mail: Mail) -> Bool { !isReadOnly(mail.accountID) || mail.labels?.contains("INBOX") == true }

    var selectedMail: Mail? {
        guard let id = selectedMailID else { return nil }
        return mails.first { $0.id == id }
    }

    func accounts(of kind: AccountKind) -> [Account] {
        accounts.filter { $0.kind == kind }
    }

    func unreadCount(_ scope: Scope) -> Int {
        mails.filter { mail in
            guard mail.isUnread, isInboxMail(mail) else { return false }
            switch scope {
            case .all: return !hiddenAccounts.contains(mail.accountID)
            case .account(let id): return mail.accountID == id
            }
        }.count
    }

    func protonLabelTitle(_ email: String) -> String {
        let label = selectedProtonLabel ?? "INBOX"
        let names = ["INBOX": "收件箱", "ALL": "所有邮件", "STARRED": "星标", "ARCHIVE": "归档", "SENT": "已发送", "DRAFT": "草稿", "TRASH": "垃圾箱", "SPAM": "垃圾邮件"]
        return names[label] ?? protonLabels[email]?.first { "proton:" + $0.id == label }?.name ?? "文件夹 / 标签"
    }

    func isReadOnly(_ email: String) -> Bool { protonAccounts.contains { $0.id == email } }

    private static func protonAccount(_ email: String) -> Account {
        Account(id: email, name: email.split(separator: "@").first.map(String.init) ?? email, kind: .proton)
    }

    private static func imapAccount(_ email: String) -> Account {
        Account(id: email, name: email.split(separator: "@").first.map(String.init) ?? email, kind: .imap)
    }

    private static func gmailAccount(_ email: String) -> Account {
        Account(id: email, name: email.split(separator: "@").first.map(String.init) ?? email, kind: .gmail)
    }

    private func gmailClient(_ email: String) -> GmailClient {
        if let client = gmailClients[email] { return client }
        let client = GmailClient(email: email)
        gmailClients[email] = client
        return client
    }

    // MARK: - Selection

    func select(_ scope: Scope) {
        self.scope = scope
        selectedProtonLabel = nil
        selectedMailID = nil
        stayVisible = []
    }

    /// Moves the selection through the visible list (J = down, K = up).
    func moveSelection(_ step: Int) {
        let list = visibleMails
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedMailID }
        let next = current.map { min(max($0 + step, 0), list.count - 1) } ?? 0
        open(list[next])
    }

    /// Reading a mail somewhere that has its own selection (the menu bar panel): marks it read and loads the body.
    func markOpened(_ mail: Mail) {
        if mail.isUnread { setRead(mail.id, true) }
        if !mail.bodyLoaded { Task { await loadBody(mail.id) } }
    }

    func open(_ mail: Mail) {
        selectedMailID = mail.id
        if mail.isUnread {
            if readFilter == .unread { stayVisible.insert(mail.id) }
            setRead(mail.id, true)
        }
        if !mail.bodyLoaded { Task { await loadBody(mail.id) } }
    }

    // MARK: - Sync

    /// Keeps the Mac current until the task is cancelled: the self-hosted mailbox is polled,
    /// Gmail arrives through the local archive, which tells us over a stream when something changed.
    func runSyncLoop() async {
        Task { await loadMissingAvatars() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.archiveLoop() }
        }
    }

    private func archiveLoop() async {
        var delay = 2.0
        while !Task.isCancelled {
            do {
                for try await _ in ArchiveClient().events() {
                    delay = 2
                    await syncFromArchive()
                }
            } catch {
                archiveStatus = "同步出错:\(error.localizedDescription)"
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    /// Manual refresh: asks the engine to pull every mailbox now, then reads what it has.
    func reloadAll(quiet: Bool = false) async {
        guard !isRefreshing else { return }
        syncError = nil
        isRefreshing = true
        defer { isRefreshing = false }
        let client = ArchiveClient()
        do {
            try await MailRefresher(accounts: { try await client.accounts() }, poke: { try await client.poke() }, pull: {
                await self.syncFromArchive()
                if let error = self.archiveFailure { throw ArchiveClient.Failure(message: error) }
            }).run()
            if !quiet { showToast("邮件已刷新") }
        } catch is CancellationError {
            return
        } catch {
            syncError = "刷新失败:\(error.localizedDescription)"
            if !quiet { showToast(syncError!) }
        }
    }

    private func loadMissingAvatars() async {
        for account in gmailAccounts where avatarURLs[account.id] == nil {
            if let url = await gmailClient(account.id).profilePictureURL() {
                avatarURLs[account.id] = url
                UserDefaults.standard.set(avatarURLs.mapValues(\.absoluteString), forKey: "gmailAvatars")
            }
        }
    }

    // MARK: - Mailbox management

    func setHidden(_ hidden: Bool, for id: String) {
        if hidden { hiddenAccounts.insert(id) } else { hiddenAccounts.remove(id) }
        if hidden {
            if scope == .account(id) { select(.all) }
            if let selected = selectedMail, selected.accountID == id { selectedMailID = nil }
        }
    }

    /// Takes the list of IMAP mailboxes from the engine, which knows which ones exist.
    func refreshServerAccounts() async {
        guard let list = try? await ArchiveClient().accounts() else { return }
        updateCredentialErrors(from: list)
        let emails = list.filter { $0.kind == "imap" }.map(\.email)
        if emails != imapAccounts.map(\.id) {
            imapAccounts = emails.map(Self.imapAccount)
            UserDefaults.standard.set(emails, forKey: "imapAccounts")
        }
        let protonEmails = list.filter { $0.kind == "proton" }.map(\.email)
        protonAccounts = protonEmails.map(Self.protonAccount)
        UserDefaults.standard.set(protonEmails, forKey: "protonAccounts")
        for email in protonEmails { protonLabels[email] = try? await ArchiveClient().protonLabels(email) }
    }

    func updateCredentialErrors(from accounts: [ArchiveAccount]) {
        // Rows written before the kind column carry only the message; the
        // credential-store texts still identify them.
        let keychainMessages = [CredentialPersistenceError.writeFailed.localizedDescription,
                                CredentialPersistenceError.recoveryFailed.localizedDescription,
                                CredentialPersistenceError.readFailed.localizedDescription]
        serverCredentialError = accounts.first {
            $0.lastErrorKind == AccountErrorKind.keychain.rawValue
                || ($0.lastErrorKind == nil && keychainMessages.contains($0.lastError ?? ""))
        }?.lastError
        let offline = accounts.filter { $0.lastErrorKind == AccountErrorKind.network.rawValue }
        if offline.isEmpty {
            networkErrorSummary = nil
        } else if offline.allSatisfy({ $0.kind == "proton" }) {
            networkErrorSummary = "\(offline.count) 个 Proton 账号暂时无法连接，将自动重试"
        } else {
            networkErrorSummary = "\(offline.count) 个邮箱暂时无法连接，将自动重试"
        }
    }

    func addProtonAccount(username: String, password: String, mailboxPassword: String, otp: String, interaction: ProtonLoginInteraction? = nil) async throws {
        try await reportCredentialFailure {
            try await ArchiveClient().addProton(username: username, password: password, mailboxPassword: mailboxPassword, otp: otp, interaction: interaction)
        }
        await refreshServerAccounts()
        await syncFromArchive(full: true)
    }

    /// Adds a mailbox the engine reads over IMAP. Throws with the engine's reason when the login fails.
    func addIMAPAccount(email: String, password: String, host: String, port: Int) async throws {
        try await reportCredentialFailure {
            try await ArchiveClient().addIMAP(email: email, password: password, host: host, port: port)
        }
        await refreshServerAccounts()
        await syncFromArchive()
    }

    /// Deletes a mailbox from the engine and from this Mac.
    func removeAccount(_ id: String) async throws {
        guard let account = allAccounts.first(where: { $0.id == id }) else { return }
        try await ArchiveClient().deleteAccount(id)
        if account.kind == .gmail {
            removeGmailAccount(id)
        } else {
            protonAccounts.removeAll { $0.id == id }
            protonLabels[id] = nil
            UserDefaults.standard.set(protonAccounts.map(\.id), forKey: "protonAccounts")
            imapAccounts.removeAll { $0.id == id }
            UserDefaults.standard.set(imapAccounts.map(\.id), forKey: "imapAccounts")
            mails.removeAll { $0.accountID == id }
            if scope == .account(id) { select(.all) }
        }
        hiddenAccounts.remove(id)
        // Flush the second cache now instead of waiting for a debounced save.
        try MailCache.saveChecked(mails)
    }

    // MARK: - Gmail accounts

    func addGmailAccount(to groupID: String? = nil,
                         signIn: () async throws -> (email: String, token: GmailAuth.Token) = GmailAuth.signIn) async {
        do {
            let (email, token) = try await signIn()
            guard let refresh = token.refreshToken else {
                syncError = "Google 没有返回长期授权,请在 Google 账号的第三方应用访问权限里移除 pigi 后重试"
                return
            }
            try await reportCredentialFailure { try GmailStore.add(email, refreshToken: refresh) }
            if !gmailAccounts.contains(where: { $0.id == email }) {
                gmailAccounts.append(Self.gmailAccount(email))
            }
            if let groupID { place(email, inGroup: groupID) }
            await ArchiveClient().ensureGmail([email])
            try await ArchiveClient().poke()
            await syncFromArchive()
            await loadMissingAvatars()
        } catch GmailAuth.AuthError.cancelled {
            return
        } catch is CredentialPersistenceError {
            // Already shown in both mailbox settings and the sidebar. Do not
            // duplicate it in syncError, which would survive a successful retry.
            return
        } catch {
            syncError = "登录失败:\(error.localizedDescription)"
        }
    }

    /// Re-runs the Google sign-in for a mailbox that is already added and swaps its
    /// refresh token in place, so its mail stays put. Returns the failure message,
    /// or nil on success and when the user cancelled.
    func reauthorizeGmailAccount(_ email: String) async -> String? {
        do {
            let (authorizedEmail, token) = try await GmailAuth.signIn()
            switch GmailStore.applyReauthorization(authorizedEmail: authorizedEmail, refreshToken: token.refreshToken, for: email) {
            case .replaced: break
            case .differentMailbox: return "授权的不是同一个邮箱"
            case .noRefreshToken: return "Google 没有返回长期授权,请在 Google 账号的第三方应用访问权限里移除 pigi 后重试"
            case .unknownMailbox: return "没有这个 Gmail 邮箱"
            case .keychainFailed:
                credentialError = CredentialPersistenceError.writeFailed.localizedDescription
                return credentialError
            }
            credentialError = nil
            await ArchiveClient().resetGmailSession(email)
            try await ArchiveClient().poke()
            await syncFromArchive()
            return nil
        } catch GmailAuth.AuthError.cancelled {
            return nil
        } catch {
            return "重新授权失败:\(error.localizedDescription)"
        }
    }

    /// Verifies a new IMAP password with the server, then stores it; local mail is untouched.
    func updateIMAPPassword(email: String, password: String) async throws {
        try await reportCredentialFailure {
            try await ArchiveClient().updateIMAPPassword(email: email, password: password)
        }
        await syncFromArchive()
    }

    func reportCredentialFailure(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            credentialError = nil
        } catch let error as CredentialPersistenceError {
            credentialError = error.localizedDescription
            throw error
        }
    }

    func removeGmailAccount(_ email: String) {
        GmailStore.remove(email)
        gmailClients[email] = nil
        gmailAccounts.removeAll { $0.id == email }
        avatarURLs[email] = nil
        UserDefaults.standard.set(avatarURLs.mapValues(\.absoluteString), forKey: "gmailAvatars")
        mails.removeAll { $0.accountID == email }
        if scope == .account(email) { select(.all) }
    }

    /// Replaces an account's mails with a fresh list, keeping bodies already
    /// downloaded and any search hits that are older than the sync window.
    /// Local read/star changes that a sync which started before the server
    /// confirmed them must not undo. `confirmedAt` is set once the server accepted the change.
    private struct LocalChange { var value: Bool; var confirmedAt: Date? }
    private var readChanges: [String: LocalChange] = [:]
    private var starChanges: [String: LocalChange] = [:]

    /// Pulls the mail inside the local window from the local archive: adds what is missing,
    /// follows read/star/archive changes, and drops what fell out of the window.
    /// `full` starts from the beginning instead of the last change number.
    func syncFromArchive(full: Bool = false) async {
        archiveFullRequested = archiveFullRequested || full
        if isArchiveSyncing {
            archiveDirty = true
            await withCheckedContinuation { archiveWaiters.append($0) }
            return
        }
        isArchiveSyncing = true
        defer {
            isArchiveSyncing = false
            archiveCatchingUp = false
            let waiters = archiveWaiters
            archiveWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        repeat {
            archiveDirty = false
            let full = archiveFullRequested
            archiveFullRequested = false
            await pullArchive(full: full)
        } while archiveDirty || archiveFullRequested
    }

    private func pullArchive(full: Bool) async {
        archiveFailure = nil
        await refreshServerAccounts()
        await ArchiveClient().ensureGmail()
        let days = ArchiveSettings.windowDays
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var cursor = (full || ArchiveSettings.cursorWindow != days || ArchiveSettings.cursorSchema != ArchiveSettings.schema) ? 0 : ArchiveSettings.cursor
        let gmail = syncedAccountIDs
        let firstPull = cursor == 0
        freshMails = []
        var touched = 0
        do {
            let client = ArchiveClient()
            var more = true
            while more {
                let page = try await client.changes(after: cursor, since: since)
                touched += applyArchive(page.items.filter { gmail.contains($0.account) })
                cursor = page.next
                more = page.more
                archiveCatchingUp = more
            }
            ArchiveSettings.cursor = cursor
            ArchiveSettings.cursorWindow = days
            ArchiveSettings.cursorSchema = ArchiveSettings.schema
            mails.removeAll { gmail.contains($0.accountID) && $0.date < since && !searchHits.contains($0.id) }
            archiveStatus = "已同步 · 本地保留最近 \(days) 天"
            if !firstPull {
                let recent = Date().addingTimeInterval(-3600)
                MailNotifier.shared.notify(freshMails.filter { !hiddenAccounts.contains($0.accountID) && $0.date > recent })
            }
        } catch {
            archiveFailure = error.localizedDescription
            archiveStatus = "同步失败:\(error.localizedDescription)"
        }
    }

    private func applyArchive(_ items: [ArchiveItem]) -> Int {
        var byID = Dictionary(mails.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var removed = Set<String>()
        var added: [Mail] = []
        var touched = 0
        for item in items {
            var mail = item.mail
            if item.status != "inbox" && (!isReadOnly(item.account) || item.status == "deleted") {
                if item.status == "deleted" && isReadOnly(item.account) {
                    removed.insert(mail.id)
                    searchHits.remove(mail.id)
                    touched += 1
                } else if byID[mail.id] != nil, !searchHits.contains(mail.id) { removed.insert(mail.id); touched += 1 }
                continue
            }
            if let change = readChanges[mail.id], change.confirmedAt == nil { mail.isUnread = !change.value }
            if let change = starChanges[mail.id], change.confirmedAt == nil { mail.isStarred = change.value }
            if let index = byID[mail.id], index >= 0 {
                if isReadOnly(item.account) {
                    // Invalidate a cached decrypted body when an event replaces it.
                    let wasLoaded = mails[index].bodyLoaded
                    mails[index] = mail
                    if wasLoaded { Task { await self.loadBody(mail.id) } }
                    touched += 1
                } else if mails[index].isUnread != mail.isUnread || mails[index].isStarred != mail.isStarred
                    || mails[index].code != mail.code || mails[index].unsubKind != mail.unsubKind {
                    mails[index].isUnread = mail.isUnread
                    mails[index].isStarred = mail.isStarred
                    mails[index].code = mail.code
                    mails[index].unsubKind = mail.unsubKind
                    touched += 1
                }
            } else {
                added.append(mail)
                if mail.isUnread && item.status == "inbox" { freshMails.append(mail) }
                byID[mail.id] = -1
                touched += 1
            }
        }
        if !removed.isEmpty { mails.removeAll { removed.contains($0.id) } }
        if !added.isEmpty { mails += added }
        return touched
    }

    private func loadBody(_ id: String) async {
        guard let mail = mail(id) else { return }
        do {
            let body = try await ArchiveClient().body(account: mail.accountID, id: mail.remoteID)
            let isHTML = body.html?.isEmpty == false
            update(id) {
                $0.body = (isHTML ? body.html : nil) ?? body.text
                $0.bodyLoaded = true
                $0.isHTML = isHTML
                $0.signatureStatus = body.signatureStatus
            }
        } catch {
            syncError = "读取邮件失败:\(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func searchChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchHits = []
            return
        }
        let account: String?
        switch scope {
        case .all: account = nil
        case .account(let id): account = id
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await searchArchive(query, account: account)
            guard !Task.isCancelled else { return }
            let known = Set(mails.map(\.id))
            mails += found.filter { !known.contains($0.id) }
            searchHits = Set(found.map(\.id))
        }
    }

    private func searchArchive(_ query: String, account: String?) async -> [Mail] {
        guard let items = try? await ArchiveClient().search(query, account: account) else { return [] }
        let known = syncedAccountIDs
        return items.filter { known.contains($0.account) }.map(\.mail)
    }

    func endSearch() {
        isSearching = false
        searchText = ""
        searchTask?.cancel()
        searchHits = []
    }

    // MARK: - Actions

    func toggleStar(_ id: String) {
        guard let mail = mail(id), !isReadOnly(mail.accountID) else { return }
        let starred = !mail.isStarred
        update(id) { $0.isStarred = starred }
        starChanges[id] = LocalChange(value: starred)
        sendToBackend(mail, failure: "加星标失败") {
            try await $0.modify(account: mail.accountID, id: mail.remoteID, add: starred ? ["STARRED"] : [], remove: starred ? [] : ["STARRED"])
        } rollback: {
            self.starChanges[id] = nil
            self.update(id) { $0.isStarred = !starred }
        }
    }

    func toggleUnread(_ id: String) {
        guard let mail = mail(id) else { return }
        if readFilter == .unread { stayVisible.insert(id) }
        setRead(id, mail.isUnread)
    }

    private func setRead(_ id: String, _ read: Bool) {
        guard let mail = mail(id), !isReadOnly(mail.accountID) else { return }
        update(id) { $0.isUnread = !read }
        readChanges[id] = LocalChange(value: read)
        sendToBackend(mail, failure: "标记已读失败") {
            try await $0.modify(account: mail.accountID, id: mail.remoteID, add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
        } rollback: {
            self.readChanges[id] = nil
            self.update(id) { $0.isUnread = read }
        }
    }

    var unreadVisibleCount: Int { visibleMails.filter { $0.isUnread && !isReadOnly($0.accountID) }.count }

    /// Marks everything unread in the current list as read; Gmail mails go up one call per mailbox.
    func markAllRead(ids: Set<String>? = nil) {
        let targets = (ids.map { selected in mails.filter { selected.contains($0.id) } } ?? visibleMails).filter { $0.isUnread && !isReadOnly($0.accountID) }
        guard !targets.isEmpty else { return }
        let gmail = targets
        for mail in gmail {
            update(mail.id) { $0.isUnread = false }
            readChanges[mail.id] = LocalChange(value: true)
        }
        for (account, list) in Dictionary(grouping: gmail, by: \.accountID) {
            Task {
                do {
                    try await ArchiveClient().modify(account: account, ids: list.map(\.remoteID), add: [], remove: ["UNREAD"])
                    let now = Date()
                    for mail in list where readChanges[mail.id] != nil { readChanges[mail.id]?.confirmedAt = now }
                } catch {
                    for mail in list {
                        readChanges[mail.id] = nil
                        update(mail.id) { $0.isUnread = true }
                    }
                    syncError = "标记已读失败:\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Code and unsubscribe

    /// A short message at the bottom of the window.
    var toast: String?
    private var toastTask: Task<Void, Never>?
    /// The mail whose unsubscribe the user is being asked to confirm.
    var unsubTarget: Mail?
    var markAllReadIDs: Set<String>?

    func confirmMarkAllRead(_ list: [Mail]) {
        let ids = Set(list.filter { $0.isUnread && !isReadOnly($0.accountID) }.map(\.id))
        markAllReadIDs = ids.isEmpty ? nil : ids
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func copyCode(_ mail: Mail) {
        guard let code = mail.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        showToast("已复制验证码 \(code)")
    }

    /// One-click mails are unsubscribed by the engine; others open the page. Either way the user already chose.
    func unsubscribe(_ mail: Mail) {
        guard !isReadOnly(mail.accountID) else { return }
        Task {
            do {
                switch try await ArchiveClient().unsubscribe(account: mail.accountID, id: mail.remoteID) {
                case .done:
                    remove(mail.id)
                    showToast("已退订 \(mail.senderName),邮件已归档")
                case .manual(let url):
                    guard let url else { showToast("这封邮件没有可打开的退订页面"); return }
                    NSWorkspace.shared.open(url)
                    showToast("已打开退订页面")
                }
            } catch {
                syncError = "退订失败:\(error.localizedDescription)"
            }
        }
    }

    func muteSender(_ mail: Mail) {
        guard !isReadOnly(mail.accountID) else { return }
        Task {
            do {
                try await ArchiveClient().mute(account: mail.accountID, sender: mail.senderEmail, id: mail.remoteID)
                remove(mail.id)
                showToast("已屏蔽 \(mail.senderName),之后的邮件会自动归档")
            } catch {
                syncError = "屏蔽失败:\(error.localizedDescription)"
            }
        }
    }

    func archive(_ id: String) {
        guard let mail = mail(id), !isReadOnly(mail.accountID) else { return }
        remove(id)
        sendToBackend(mail, failure: "归档失败") {
            try await $0.modify(account: mail.accountID, id: mail.remoteID, add: [], remove: ["INBOX"])
        } rollback: {
            self.mails.append(mail)
        }
    }

    /// Delete moves to the trash rather than erasing the mail.
    func delete(_ id: String) {
        guard let mail = mail(id), !isReadOnly(mail.accountID) else { return }
        remove(id)
        sendToBackend(mail, failure: "删除失败") {
            try await $0.trash(account: mail.accountID, id: mail.remoteID)
        } rollback: {
            self.mails.append(mail)
        }
    }

    private func remove(_ id: String) {
        let list = visibleMails
        if let index = list.firstIndex(where: { $0.id == id }), selectedMailID == id {
            let neighbour = index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
            selectedMailID = neighbour?.id
        }
        mails.removeAll { $0.id == id }
    }

    /// Runs a request against the mail's own backend; the UI is already
    /// updated optimistically, so a failure undoes it and surfaces the error.
    private func sendToBackend(
        _ mail: Mail,
        failure: String,
        _ gmail: @escaping (ArchiveClient) async throws -> Void,
        rollback: @escaping () -> Void
    ) {
        Task {
            do {
                try await gmail(ArchiveClient())
                let now = Date()
                if readChanges[mail.id] != nil { readChanges[mail.id]?.confirmedAt = now }
                if starChanges[mail.id] != nil { starChanges[mail.id]?.confirmedAt = now }
            } catch {
                rollback()
                syncError = "\(failure):\(error.localizedDescription)"
            }
        }
    }

    private func mail(_ id: String) -> Mail? {
        mails.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout Mail) -> Void) {
        guard let index = mails.firstIndex(where: { $0.id == id }) else { return }
        change(&mails[index])
    }

    // MARK: - Formatting

    private static func sectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "本周" }
        let components = calendar.dateComponents([.year, .month], from: date)
        let nowYear = calendar.component(.year, from: now)
        if components.year == nowYear { return "\(components.month ?? 0)月" }
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }

    static func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}
