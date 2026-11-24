import AppKit
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 50) {
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
        privacy.grantServiceConsent(endpoint: config.baseURL)
        privacy.setEnabled(true, accountID: allowed, isProton: false)

        let translator = HoldingTranslator()
        let cache = SQLiteTranslationCache(path: ":memory:")
        let seeded = ListTranslationRow(id: "mail-0", accountID: allowed, subject: "Allowed 00", snippet: "Snippet 00")
        let seededKey = ListTranslationCache.key(row: seeded, configuration: config)
        try await cache.put(CachedTranslation(subject: "已缓存主题", body: "已缓存摘要"),
                            for: try await cache.begin(seededKey), validated: true)

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
    let touching = frames.frames.filter { $0.maxY == 0 || $0.minY == height }.map(\.id)
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
