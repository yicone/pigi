import AppKit
import Darwin
import SwiftUI

// Stand-ins compiled instead of the app's mail cache and the real keychain.
// Nothing in this process may read the login keychain or a real mailbox.
enum MailCache {
    static func load() -> [Mail] { fixtureMails }
    static func save(_ mails: [Mail]) {}
    static func saveChecked(_ mails: [Mail]) throws {}
    static func clear() {}
}

enum Keychain {
    private static let lock = NSLock()
    private static var gets = 0
    private static var sets = 0
    private static var translationReads = 0
    static var getCount: Int { lock.lock(); defer { lock.unlock() }; return gets + sets }
    static var translationAPIKeyReads: Int { lock.lock(); defer { lock.unlock() }; return translationReads }
    static func warm() throws {}
    static func get(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        gets += 1
        return nil
    }
    @discardableResult static func set(_ key: String, _ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sets += 1
        return false
    }
    static func translationAPIKey() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        translationReads += 1
        return nil
    }
    @discardableResult static func setTranslationAPIKey(_ value: String) -> Bool { false }
}

@MainActor enum MainWindow { static func show() {} }

private let allowed = "allowed@example.invalid"
private let skipped = "skipped@example.invalid"
private let proton = "proton@example.invalid"

private final class HoldingTranslator: SegmentTranslator, @unchecked Sendable {
    private var stored: [[String]] = []
    var hold = false
    var calls: [[String]] { stored }
    func setHold(_ hold: Bool) { self.hold = hold }

    func translate(_ segments: [TranslationSegment]) async throws -> [TranslationSegment] {
        stored.append(segments.map(\.text))
        if hold { try await Task.sleep(for: .seconds(8)) }
        return segments.map { TranslationSegment(id: $0.id, text: "译:" + $0.text) }
    }
}

private struct FrameNote: Codable {
    var id: String
    var minY: Double
    var maxY: Double
}

private struct RequestLog: Codable {
    var translationAPIKeyReads: Int
    var keychainGets: Int
    var calls: [[String]]
    var viewportHeight: Double
    var frames: [FrameNote]
    var visibleIDs: [String]
    var partialIDs: [String]
    var outsideIDs: [String]
    var edgeTouchIDs: [String]
    var notes: [String]
}

private let fixtureMails: [Mail] = (0..<24).map { index in
        let account: String
        let subject: String
        let snippet: String
        switch index {
        case 1:
            account = skipped
            subject = "Skipped 01"
            snippet = "Snippet 01"
        case 2:
            account = proton
            subject = "Proton 02"
            snippet = "Snippet 02"
        case 3:
            account = allowed
            subject = "中文主题"
            snippet = "中文摘要"
        default:
            account = allowed
            subject = String(format: "Allowed %02d", index)
            snippet = String(format: "Snippet %02d", index)
        }
        return Mail(id: "mail-\(index)", accountID: account, remoteID: "\(index)",
                    senderName: "Sender \(index)", senderEmail: "sender\(index)@example.invalid",
                    subject: subject, snippet: snippet, body: "",
                    date: Date().addingTimeInterval(-Double(index) * 60),
                    isUnread: index == 0 || index == 20, isStarred: false, bodyLoaded: false, isHTML: false,
                    labels: account == proton ? ["INBOX"] : nil)
}

@main
@MainActor
struct ListTranslationWindowRegression {
    static func main() {
        let evidence = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("FAIL: list translation window harness timed out\n", stderr)
            _exit(124)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(evidence: evidence) }
            catch {
                fputs("FAIL: \(error)\n", stderr)
                _exit(1)
            }
        }
        app.run()
    }

    private static func run(evidence: URL) async throws {
        let config = TranslationConfig(enabled: true, baseURL: "https://translate.example.invalid/v1",
                                       model: "fixture-model", systemPrompt: "fixture prompt")
        UserDefaults.standard.setVolatileDomain([
            "gmailAccounts": [allowed, skipped],
            "imapAccounts": [String](),
            "protonAccounts": [proton],
            "hiddenAccounts": [String](),
            "gmailAvatars": [String: String](),
            "accountAliases": [String: String](),
            "archiveURL": "",
            "listWidth": 320,
            "sidebarWidthV4": 147,
            "sidebarCollapsed": false,
        ], forName: UserDefaults.argumentDomain)
        TranslationConfigStore().save(config)
        let privacy = TranslationPrivacySettings.shared
        privacy.removeAccount(proton)
        privacy.grantServiceConsent(endpoint: config.baseURL)
        privacy.setEnabled(true, accountID: allowed, isProton: false)

        let translator = HoldingTranslator()
        let cache = SQLiteTranslationCache(path: ":memory:")
        let seeded = ListTranslationRow(id: "mail-0", accountID: allowed, subject: "Allowed 00", snippet: "Snippet 00")
        let seededKey = ListTranslationCache.key(row: seeded, configuration: config)
        try await cache.put(CachedTranslation(subject: "已缓存主题", body: "已缓存摘要"),
                            for: try await cache.begin(seededKey), validated: true)

        let indexEngine = try await seedOriginalMailIndex()
        let state = AppState()
        state.listTranslationSession = ListTranslationSession(
            credentialConfigured: { true },
            makeTranslator: { _ in translator },
            cache: cache)
        let frames = FrameBox()
        state.listViewportObserver = { next, height in
            frames.frames = next
            frames.height = height
        }
        guard Keychain.translationAPIKeyReads == 0, Keychain.getCount == 0 else {
            fail("keychain was touched while building the fixture")
        }

        let host = NSHostingView(rootView: RootView().environment(state).environment(LayoutState()))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1080, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        try await wait("list frames never appeared") { frames.height > 80 && frames.frames.count >= 4 }
        host.layoutSubtreeIfNeeded()
        try await fitViewport(window: window, host: host, frames: frames)
        guard translator.calls.isEmpty else { fail("opening the list sent a translation request") }
        guard Keychain.translationAPIKeyReads == 0, Keychain.getCount == 0 else { fail("keychain was read while showing the list") }
        save(window, evidence.appendingPathComponent("01-original.png"))

        try await press(window, identifier: "mail.list.translation")
        try await wait("confirmation dialog did not appear") { buttonExists(window, title: "发送并翻译") }
        guard translator.calls.isEmpty else { fail("the confirmation dialog sent a request before acceptance") }
        save(window, evidence.appendingPathComponent("02-confirm.png"))
        try await press(window, title: "取消", skipIdentifiers: ["mail.list.translation.cancel"])
        try await wait("cancel did not return the list to idle") { !state.listTranslationBusy && state.listTranslationPrompt == nil }
        guard translator.calls.isEmpty else { fail("cancelling the confirmation sent a request") }
        save(window, evidence.appendingPathComponent("03-after-cancel.png"))
        print("PASS: confirmation cancel performed zero requests")

        try await pinExactEdge(window: window, host: host, frames: frames, id: "mail-4")
        let edge = sampleViewport(frames)
        guard edge.touching.contains("mail-4"), !edge.visible.contains("mail-4") else {
            fail("mail-4 was not a stable edge; height=\(edge.height) frames=\(edge.frames)")
        }
        let callsBeforeEdge = translator.calls.count
        try await press(window, identifier: "mail.list.translation")
        try await Task.sleep(for: .milliseconds(300))
        guard translator.calls.count == callsBeforeEdge, state.listTranslationPrompt == nil, !state.listTranslationBusy else {
            fail("exact edge mail-4 caused confirmation or request")
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let edgeAfterPreference = sampleViewport(frames)
        if !edgeAfterPreference.touching.contains("mail-4") || edgeAfterPreference.visible.contains("mail-4") {
            try await pinExactEdge(window: window, host: host, frames: frames, id: "mail-4")
        }
        try await press(window, identifier: "mail.list.translation")
        try await Task.sleep(for: .milliseconds(300))
        guard translator.calls.count == callsBeforeEdge, state.listTranslationPrompt == nil, !state.listTranslationBusy else {
            fail("exact edge mail-4 caused confirmation or request after preference refresh")
        }
        let settled = sampleViewport(frames)
        guard settled.touching.contains("mail-4"), !settled.visible.contains("mail-4") else {
            fail("mail-4 did not stay on the edge after the second click; height=\(settled.height)")
        }
        let edgeRow = edge.frames.first(where: { $0.id == "mail-4" })
        save(window, evidence.appendingPathComponent("09-exact-edge.png"))
        print("PASS: exact edge stayed excluded across two clicks; mail-4 minY=\(edgeRow?.minY ?? -1) viewport=\(edge.height)")

        try await fitViewport(window: window, host: host, frames: frames)
        let viewport = try requireViewport(frames)
        try await press(window, identifier: "mail.list.translation")
        try await wait("second confirmation did not appear") { buttonExists(window, title: "发送并翻译") }
        try await press(window, title: "发送并翻译")
        try await wait("translation did not finish") { !state.listTranslationBusy && state.listTranslations["mail-4"] != nil }
        guard translator.calls.count == 1 else { fail("expected one request, got \(translator.calls.count)") }
        let requested = Set(translator.calls[0])
        try assertRequest(requested, viewport: viewport, extraExcluded: ["Allowed 00", "Snippet 00"])
        guard state.listTranslations["mail-0"]?.subject == "已缓存主题" else { fail("cached row was not shown from cache") }
        guard state.listTranslations["mail-1"] == nil, state.listTranslations["mail-2"] == nil else { fail("skipped account was translated") }
        guard state.listTranslations["mail-3"] == nil else { fail("Chinese row was sent") }
        guard state.mails.allSatisfy({ !$0.subject.hasPrefix("译:") && !$0.snippet.hasPrefix("译:") }) else { fail("original mail was replaced") }
        let found = state.filteredMails(scope: .all, readFilter: .all, stay: [], query: "Allowed 00")
        guard found.contains(where: { $0.id == "mail-0" && $0.subject == "Allowed 00" }) else { fail("search no longer matches the original subject") }
        let notes = MailNotifier.requests(for: state.mails)
        guard notes.allSatisfy({ !$0.content.body.hasPrefix("译:") && !$0.content.title.hasPrefix("译:") }) else { fail("notification text used a translation") }
        guard requested.allSatisfy({ !$0.contains("@") }) else { fail("a request contained an account address") }
        save(window, evidence.appendingPathComponent("04-translated.png"))
        print("PASS: visible batch showed translations and left originals in place")

        let callsAfterSuccess = translator.calls.count
        try await press(window, identifier: "mail.list.translation")
        try await Task.sleep(for: .milliseconds(700))
        guard translator.calls.count == callsAfterSuccess, state.listTranslationPrompt == nil, !state.listTranslationBusy else {
            fail("a fully cached viewport sent another request")
        }
        print("PASS: cached viewport performed zero requests and skipped confirmation")

        try await scroll(state, window: window, host: host, frames: frames, untilVisible: "mail-20")
        let afterScroll = try requireViewport(frames)
        guard translator.calls.count == callsAfterSuccess else { fail("scrolling sent a request") }
        save(window, evidence.appendingPathComponent("05-scrolled.png"))
        translator.setHold(true)
        let beforeScrollRequest = translator.calls.count
        try await press(window, identifier: "mail.list.translation")
        try await press(window, title: "发送并翻译")
        try await wait("scrolled request did not start") { translator.calls.count > beforeScrollRequest }
        let scrollRequest = Set(translator.calls[translator.calls.count - 1])
        try assertRequest(scrollRequest, viewport: afterScroll, extraExcluded: translator.calls[0] + ["Allowed 00", "Snippet 00", "已缓存主题", "已缓存摘要"])
        guard scrollRequest.contains("Allowed 20") || scrollRequest.contains("Snippet 20") else { fail("scrolled viewport did not request the newly visible row") }
        let appliedBeforeCancel = state.listTranslations
        state.select(.account(skipped))
        try await wait("scope change did not cancel the request") { !state.listTranslationBusy }
        guard translator.calls.count == beforeScrollRequest + 1 else { fail("scope change started another request") }
        guard state.listTranslations == appliedBeforeCancel else { fail("cancelled scope change applied translations") }
        guard state.visibleMails.allSatisfy({ $0.accountID == skipped && state.listTranslations[$0.id] == nil }) else {
            fail("skipped account list showed another account's translation")
        }
        let leaked = try await cache.get(ListTranslationCache.key(
            row: ListTranslationRow(id: "mail-20", accountID: allowed, subject: "Allowed 20", snippet: "Snippet 20"),
            configuration: config))
        guard leaked == nil else { fail("cancelled batch wrote a cache row") }
        save(window, evidence.appendingPathComponent("06-scope-cancelled.png"))
        print("PASS: scope change cancelled the request without writing cache or crossing accounts")

        state.select(.all)
        try await scroll(state, window: window, host: host, frames: frames, untilVisible: "mail-20")
        let beforeFilter = translator.calls.count
        let translationsBeforeFilter = state.listTranslations
        try await press(window, identifier: "mail.list.translation")
        try await press(window, title: "发送并翻译")
        try await wait("filter-change request did not start") { translator.calls.count > beforeFilter }
        state.readFilter = .unread
        try await wait("read filter did not cancel the request") { !state.listTranslationBusy }
        guard state.listTranslations == translationsBeforeFilter else { fail("cancelled filter change applied translations") }
        guard state.visibleMails.allSatisfy({ $0.isUnread }) else { fail("unread filter did not change the list") }
        guard state.mails.first(where: { $0.id == "mail-20" })?.subject == "Allowed 20" else { fail("unread row subject changed") }
        save(window, evidence.appendingPathComponent("07-filter-cancelled.png"))
        print("PASS: read filter cancelled the in-flight request without polluting the new list")

        state.readFilter = .all
        try await scroll(state, window: window, host: host, frames: frames, untilVisible: "mail-20")
        let beforeSearch = translator.calls.count
        let translationsBeforeSearch = state.listTranslations
        try await press(window, identifier: "mail.list.translation")
        try await press(window, title: "发送并翻译")
        try await wait("search-change request did not start") { translator.calls.count > beforeSearch }
        state.searchText = "Allowed 00"
        try await wait("search did not cancel the request") { !state.listTranslationBusy }
        guard state.listTranslations == translationsBeforeSearch else { fail("cancelled search applied translations") }
        guard state.visibleMails.allSatisfy({ $0.subject.contains("Allowed 00") || $0.snippet.contains("Allowed 00") }) else {
            fail("search did not narrow the list")
        }
        guard state.mails.contains(where: { $0.id == "mail-20" && $0.subject == "Allowed 20" }) else { fail("search replaced a stored subject") }
        save(window, evidence.appendingPathComponent("08-search-cancelled.png"))
        state.searchText = ""
        print("PASS: search cancelled the in-flight request and kept stored subjects")

        TranslationPrivacySettings.shared.setEnabled(true, accountID: proton, isProton: true, confirmingProtonConsent: true)
        state.select(.account(proton))
        try await wait("proton inbox did not appear") { state.visibleMails.contains { $0.id == "mail-2" } }
        let protonRow = ListTranslationRow(id: "mail-2", accountID: proton, subject: "Proton 02", snippet: "Snippet 02")
        let protonFrames = [ListRowFrame(id: "mail-2", minY: 10, maxY: 50)]
        translator.setHold(false)
        let callsBeforeConfirm = translator.calls.count
        state.translateVisibleList(frames: protonFrames, viewportHeight: 200)
        try await wait("proton confirmation did not appear") { state.listTranslationPrompt != nil }
        guard translator.calls.count == callsBeforeConfirm else { fail("proton confirmation sent a request") }
        state.selectedProtonLabel = "TRASH"
        try await wait("proton folder change during confirmation did not cancel") {
            !state.listTranslationBusy && state.listTranslationPrompt == nil
        }
        guard translator.calls.count == callsBeforeConfirm else { fail("switching Proton folder during confirmation sent a request") }
        guard state.listTranslations["mail-2"] == nil else { fail("confirmation cancel applied a proton translation") }
        let confirmCache = try await cache.get(ListTranslationCache.key(row: protonRow, configuration: config))
        guard confirmCache == nil else { fail("confirmation cancel wrote a proton cache row") }
        guard state.visibleMails.isEmpty else { fail("TRASH still showed the inbox row") }
        print("PASS: Proton folder change during confirmation performed zero requests")

        state.selectedProtonLabel = nil
        try await wait("proton inbox did not return") { state.visibleMails.contains { $0.id == "mail-2" } }
        translator.setHold(true)
        let callsBeforeFlight = translator.calls.count
        let translationsBeforeFlight = state.listTranslations
        state.translateVisibleList(frames: protonFrames, viewportHeight: 200)
        try await wait("in-flight proton confirmation did not appear") { state.listTranslationPrompt != nil }
        state.acceptListTranslation()
        state.finishListTranslationPrompt()
        try await wait("proton request did not start") { translator.calls.count > callsBeforeFlight }
        state.selectedProtonLabel = "TRASH"
        try await wait("proton folder change did not cancel the request") { !state.listTranslationBusy }
        guard state.listTranslations == translationsBeforeFlight else { fail("stale proton translation was displayed") }
        guard state.listTranslations["mail-2"] == nil else { fail("old proton translation was applied") }
        let flightCache = try await cache.get(ListTranslationCache.key(row: protonRow, configuration: config))
        guard flightCache == nil else { fail("stale proton translation wrote cache") }
        try await Task.sleep(for: .milliseconds(400))
        guard state.listTranslations == translationsBeforeFlight else { fail("late proton result was displayed") }
        let lateCache = try await cache.get(ListTranslationCache.key(row: protonRow, configuration: config))
        guard lateCache == nil else { fail("late proton result wrote cache") }
        guard state.mails.first(where: { $0.id == "mail-2" })?.subject == "Proton 02" else { fail("proton folder change replaced the stored subject") }
        print("PASS: Proton folder change dropped the in-flight result without cache or display")

        guard state.listTranslations.values.contains(where: { $0.subject.hasPrefix("译:") || $0.snippet.hasPrefix("译:") }) else {
            fail("list translation never produced a display translation to compare")
        }
        let readback = try await proveOriginalReadback(engine: indexEngine, evidence: evidence)
        print("PASS: persistent index and agent.sock returned originals; searchHits=\(readback.searchHits) socketSubject=\(readback.socketSubject)")

        guard Keychain.translationAPIKeyReads == 0, Keychain.getCount == 0 else {
            fail("keychain reads=\(Keychain.getCount) translationReads=\(Keychain.translationAPIKeyReads)")
        }
        let log = RequestLog(
            translationAPIKeyReads: Keychain.translationAPIKeyReads,
            keychainGets: Keychain.getCount,
            calls: translator.calls,
            viewportHeight: viewport.height,
            frames: viewport.frames.map { FrameNote(id: $0.id, minY: $0.minY, maxY: $0.maxY) },
            visibleIDs: viewport.visible,
            partialIDs: viewport.partial,
            outsideIDs: viewport.outside,
            edgeTouchIDs: viewport.touching,
            notes: [
                "Exact edge exclusion was clicked twice, including after a preference refresh.",
                "Persistent FTS and agent.sock readback is in original-readback.json.",
                "Proton folder changes during confirmation and during a request are asserted above.",
                "Exact boundary touch without overlap is asserted in ListBatchTranslationTests.",
                viewport.touching.isEmpty ? "This layout produced no exact edge-touch frame." : "Edge-touch frames were excluded from the request.",
                "No real keychain, mailbox, or translation service was contacted.",
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(log).write(to: evidence.appendingPathComponent("requests.json"))
        print("PASS: window harness keychain reads 0, evidence \(evidence.path)")
        window.orderOut(nil)
        exit(0)
    }
}

private final class FrameBox {
    var frames: [ListRowFrame] = []
    var height: CGFloat = 0
}

private struct ViewportSample {
    var frames: [ListRowFrame]
    var height: Double
    var visible: [String]
    var partial: [String]
    var outside: [String]
    var touching: [String]
}

private struct OriginalReadback {
    var searchHits: Int
    var socketSubject: String
}

private let indexSubject = "Index Subject Original"
private let indexSnippet = "Index snippet original"
private let indexBody = "Index body original stays unread"
private let indexID = "index-original"

@MainActor
private func seedOriginalMailIndex() async throws -> LocalEngine {
    let engine = LocalEngine()
    let store = try await engine.db()
    try store.run("INSERT INTO accounts(email,kind) VALUES(?,'imap')", [.text(allowed)])
    try await engine.save(LocalEngine.Draft(
        account: allowed, id: indexID, threadID: nil, date: 1_700_000_000_000,
        subject: indexSubject, name: "Index Sender", address: "sender@example.invalid",
        to: allowed, snippet: indexSnippet, labels: ["INBOX"], attachments: [],
        size: indexBody.utf8.count, html: "", text: indexBody, headers: [:]))
    let found = try await engine.search("Index", account: allowed)
    guard found.contains(where: { $0.id == indexID && $0.subject == indexSubject && $0.snippet == indexSnippet }) else {
        fail("persistent index did not store the original subject")
    }
    return engine
}

@MainActor
private func proveOriginalReadback(engine: LocalEngine, evidence: URL) async throws -> OriginalReadback {
    let found = try await engine.search("Index", account: allowed)
    guard found.contains(where: { $0.id == indexID && $0.subject == indexSubject && $0.snippet == indexSnippet }) else {
        fail("persistent index lost the original after list translation")
    }
    guard !found.contains(where: { ($0.subject ?? "").contains("译:") || ($0.snippet ?? "").contains("译:") }) else {
        fail("persistent index returned a list translation")
    }
    let translated = try await engine.search("译:Allowed", account: allowed)
    guard translated.isEmpty else { fail("persistent index matched a displayed translation") }
    let stored = try await engine.body(account: allowed, id: indexID)
    guard stored.text == indexBody else { fail("FTS body changed to \(stored.text)") }

    let directory = try AppSupport.pigiDirectory()
    let socket = directory.appendingPathComponent("agent.sock")
    let server = AgentSocketServer(engine: engine, url: socket)
    try server.start()
    defer { server.stop() }
    let listed = try agentExchange(socket.path, method: "list", params: ["account": allowed])
    guard listed.result?.items?.contains(where: { $0.messageID == indexID && $0.subject == indexSubject && $0.snippet == indexSnippet }) == true else {
        fail("agent.sock list did not return the original subject and snippet")
    }
    guard listed.result?.items?.contains(where: { ($0.subject ?? "").contains("译:") || ($0.snippet ?? "").contains("译:") }) != true else {
        fail("agent.sock list returned a translation")
    }
    let searched = try agentExchange(socket.path, method: "search", params: ["account": allowed, "query": "Index"])
    guard searched.result?.items?.contains(where: { $0.messageID == indexID && $0.subject == indexSubject }) == true else {
        fail("agent.sock search missed the original subject")
    }
    let missed = try agentExchange(socket.path, method: "search", params: ["account": allowed, "query": "译:Allowed"])
    guard missed.result?.items?.isEmpty == true else { fail("agent.sock search returned a displayed translation") }
    let got = try agentExchange(socket.path, method: "get", params: ["account": allowed, "messageID": indexID])
    guard got.result?.message?.subject == indexSubject, got.result?.message?.snippet == indexSnippet, got.result?.text == indexBody else {
        fail("agent.sock get did not return the original")
    }
    guard got.result?.contentTrust == "untrusted" else { fail("agent.sock get dropped the untrusted marker") }
    let record = OriginalReadbackFile(
        subject: indexSubject, snippet: indexSnippet, body: indexBody,
        searchCount: found.count, socketSubject: got.result?.message?.subject ?? "",
        socketText: got.result?.text ?? "")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: evidence.appendingPathComponent("original-readback.json"))
    return OriginalReadback(searchHits: found.count, socketSubject: got.result?.message?.subject ?? "")
}

private struct OriginalReadbackFile: Codable {
    var subject: String
    var snippet: String
    var body: String
    var searchCount: Int
    var socketSubject: String
    var socketText: String
}

private func agentExchange(_ path: String, method: String, params: [String: String]) throws -> AgentProtocol.Response {
    var payload = try JSONSerialization.data(withJSONObject: ["version": 1, "id": "readback", "method": method, "params": params])
    payload.append(10)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var noPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: Array(path.utf8) + [0])
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
    try payload.withUnsafeBytes { raw in
        var sent = 0
        while sent < payload.count {
            let n = write(fd, raw.baseAddress!.advanced(by: sent), payload.count - sent)
            guard n > 0 else { throw POSIXError(.EIO) }
            sent += n
        }
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { throw POSIXError(.EIO) }
        result.append(contentsOf: buffer[..<n])
        if result.last == 10 { break }
    }
    return try JSONDecoder().decode(AgentProtocol.Response.self, from: result)
}

@MainActor
private func pinExactEdge(window: NSWindow, host: NSView, frames: FrameBox, id: String) async throws {
    var contentHeight = window.contentRect(forFrameRect: window.frame).height
    for _ in 0..<24 {
        window.setContentSize(NSSize(width: 1080, height: contentHeight))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let sample = sampleViewport(frames)
        guard let row = sample.frames.first(where: { $0.id == id }) else {
            fail("\(id) was not laid out; frames=\(sample.frames.map(\.id))")
        }
        let delta = row.minY - sample.height
        if sample.touching.contains(id), !sample.visible.contains(id) {
            var held = 0
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                let next = sampleViewport(frames)
                if next.touching.contains(id), !next.visible.contains(id) { held += 1 } else { held = 0 }
            }
            if held == 4 { return }
        }
        contentHeight += abs(delta) < 0.5 ? (delta >= 0 ? 1 : -1) : delta
        if contentHeight < 220 || contentHeight > 900 {
            fail("could not place \(id) on the viewport edge; height=\(contentHeight) delta=\(delta) viewport=\(sample.height) minY=\(row.minY)")
        }
    }
    fail("exact edge did not stay put")
}

@MainActor
private func fitViewport(window: NSWindow, host: NSView, frames: FrameBox) async throws {
    var height = 460.0
    for _ in 0..<8 {
        window.setContentSize(NSSize(width: 1080, height: height))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        let sample = sampleViewport(frames)
        if !sample.partial.isEmpty && (!sample.outside.isEmpty || sample.frames.count < fixtureMails.count) { return }
        fputs("layout height=\(sample.height) frames=\(sample.frames.count) partial=\(sample.partial) outside=\(sample.outside)\n", stderr)
        for frame in sample.frames.prefix(8) {
            fputs("  \(frame.id) \(frame.minY)...\(frame.maxY)\n", stderr)
        }
        height -= 28
    }
    fail("layout never showed a partial row and a row outside the viewport")
}

private func sampleViewport(_ frames: FrameBox) -> ViewportSample {
    let height = Double(frames.height)
    let visible = ListViewport.visibleIDs(frames.frames, viewportMinY: 0, viewportMaxY: height)
    let partial = frames.frames.filter { ($0.minY < 0 && $0.maxY > 0) || ($0.minY < height && $0.maxY > height) }.map(\.id)
    let outside = frames.frames.filter { $0.maxY <= 0 || $0.minY >= height }.map(\.id)
    let touching = frames.frames.filter {
        ListViewport.touchesViewportBoundary($0, viewportMinY: 0, viewportMaxY: height)
    }.map(\.id)
    return ViewportSample(frames: frames.frames, height: height, visible: visible, partial: partial, outside: outside, touching: touching)
}

private func requireViewport(_ frames: FrameBox) throws -> ViewportSample {
    let sample = sampleViewport(frames)
    guard !sample.partial.isEmpty else { fail("no partial row in the measured viewport") }
    let missing = fixtureMails.map(\.id).filter { id in !sample.frames.contains(where: { $0.id == id }) }
    guard !sample.outside.isEmpty || !missing.isEmpty else { fail("every row was inside the measured viewport") }
    guard Set(sample.visible).isDisjoint(with: sample.outside) else { fail("an outside row was treated as visible") }
    guard Set(sample.visible).isDisjoint(with: sample.touching) else { fail("an edge-touch row was treated as visible") }
    return sample
}

private func assertRequest(_ requested: Set<String>, viewport: ViewportSample, extraExcluded: [String]) throws {
    let mailByID = Dictionary(uniqueKeysWithValues: fixtureMails.map { ($0.id, $0) })
    for id in viewport.partial {
        guard let mail = mailByID[id], mail.accountID == allowed, mail.subject != "中文主题" else { continue }
        if extraExcluded.contains(mail.subject) { continue }
        guard requested.contains(mail.subject) else { fail("partial row \(mail.subject) was not requested") }
    }
    let hidden = viewport.outside + viewport.touching + fixtureMails.map(\.id).filter { id in !viewport.visible.contains(id) }
    for id in hidden {
        guard let mail = mailByID[id] else { continue }
        guard !requested.contains(mail.subject), !requested.contains(mail.snippet) else { fail("outside row \(mail.subject) was requested") }
    }
    for banned in ["Skipped 01", "Snippet 01", "Proton 02", "Snippet 02", "中文主题", "中文摘要"] + extraExcluded {
        guard !requested.contains(banned) else { fail("request included excluded text \(banned)") }
    }
}

@MainActor
private func scroll(_ state: AppState, window: NSWindow, host: NSView, frames: FrameBox, untilVisible id: String) async throws {
    guard let root = window.contentView else { fail("window has no content") }
    state.listScrollTarget = nil
    state.listScrollTarget = id
    for step in 0..<16 {
        for scroll in scrollViews(in: root) where scroll.bounds.width > 200 {
            let documentHeight = scroll.documentView?.frame.height ?? 0
            guard documentHeight > scroll.contentView.bounds.height + 20 else { continue }
            let y = min(CGFloat(step) * 180, max(0, documentHeight - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        if sampleViewport(frames).visible.contains(id) { return }
    }
    fail("scrolling did not bring \(id) into the viewport; visible=\(sampleViewport(frames).visible)")
}

private func scrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    if let scroll = view as? NSScrollView { found.append(scroll) }
    for child in view.subviews { found.append(contentsOf: scrollViews(in: child)) }
    return found
}

@MainActor
private func press(_ window: NSWindow, identifier: String? = nil, title: String? = nil, skipIdentifiers: [String] = []) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if let root = window.contentView, press(in: root, identifier: identifier, title: title, skipIdentifiers: skipIdentifiers) {
            try await Task.sleep(for: .milliseconds(150))
            return
        }
        try await Task.sleep(for: .milliseconds(40))
    }
    if let root = window.contentView { dumpAX(root) }
    fail("could not press \(identifier ?? title ?? "control")")
}

private func buttonExists(_ window: NSWindow, title: String) -> Bool {
    guard let root = window.contentView else { return false }
    return exists(in: root, title: title)
}

private func press(in view: NSView, identifier: String?, title: String?, skipIdentifiers: [String]) -> Bool {
    if pressElement(view, identifier: identifier, title: title, skipIdentifiers: skipIdentifiers) { return true }
    return view.subviews.contains { press(in: $0, identifier: identifier, title: title, skipIdentifiers: skipIdentifiers) }
}

private struct AXNode {
    let object: NSObject
    func value(_ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    func boolean(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Method.self)(object, selector)
    }
    var identifier: String { (value("accessibilityIdentifier") as? String) ?? "" }
    var label: String { (value("accessibilityTitle") as? String) ?? (value("accessibilityLabel") as? String) ?? "" }
    var children: [NSObject] { (value("accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject } }
}

private func pressElement(_ element: NSObject, identifier: String?, title: String?, skipIdentifiers: [String]) -> Bool {
    let node = AXNode(object: element)
    if skipIdentifiers.contains(node.identifier) { return false }
    let matched = (identifier != nil && node.identifier == identifier) || (title != nil && node.label == title)
    if matched, node.boolean("accessibilityPerformPress") { return true }
    if let button = element as? NSButton, title != nil, button.title == title, !skipIdentifiers.contains(node.identifier) {
        button.performClick(nil)
        return true
    }
    return node.children.contains { pressElement($0, identifier: identifier, title: title, skipIdentifiers: skipIdentifiers) }
}

private func exists(in element: NSObject, title: String) -> Bool {
    let node = AXNode(object: element)
    if node.label == title { return true }
    if let button = element as? NSButton, button.title == title { return true }
    if node.children.contains(where: { exists(in: $0, title: title) }) { return true }
    if let view = element as? NSView {
        return view.subviews.contains { exists(in: $0, title: title) }
    }
    return false
}

private func dumpAX(_ element: NSObject, indent: String = "") {
    let node = AXNode(object: element)
    if !node.label.isEmpty || !node.identifier.isEmpty {
        fputs("\(indent)label=\(node.label) id=\(node.identifier)\n", stderr)
    }
    for child in node.children { dumpAX(child, indent: indent + "  ") }
}

@MainActor
private func save(_ window: NSWindow, _ url: URL) {
    guard let view = window.contentView else { return }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

@MainActor
private func wait(_ label: String, timeout: TimeInterval = 3, _ ready: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(40))
    }
    fail(label)
}

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    _exit(1)
}
