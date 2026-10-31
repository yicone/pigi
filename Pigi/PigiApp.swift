import AppKit
import SwiftUI
#if canImport(PigiCore)
import PigiCore
#endif

private final class TransparentPigiDockIcon: NSView {
    let artwork: NSImage
    init(image: NSImage) { artwork = image; super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128)); autoresizingMask = [.width, .height] }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        let tile = bounds.insetBy(dx: bounds.width * 0.06, dy: bounds.height * 0.06)
        NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22).fill()
        let content = bounds.insetBy(dx: bounds.width * 0.09, dy: bounds.height * 0.09)
        artwork.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

@main
struct PigiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: AppState
    @State private var layout: LayoutState
    @State private var updater = Updater()
    @AppStorage("appearanceMode") private var appearance: AppAppearance = .system

    init() {
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system).apply()
        let appState = AppState()
        _state = State(initialValue: appState)
        // Syncing belongs to the app, not the window: the menu bar keeps counting after the window closes.
        Task { await appState.runSyncLoop() }
        Task { await LocalEngine.shared.start() }
        PanelHotKey.shared.start()
        MailNotifier.shared.start()
        MailNotifier.shared.onOpenMail = { id in
            guard let mail = appState.mails.first(where: { $0.id == id }) else { return }
            appState.scope = .all
            appState.readFilter = .all
            appState.endSearch()
            appState.open(mail)
        }
        if !DockPolicy.shown { NSApplication.shared.setActivationPolicy(.accessory) }
        _layout = State(initialValue: LayoutState())
        // Keep the Dock tile background consistent with the other apps.
        if let logo = NSImage(named: "Logo") {
            NSApplication.shared.applicationIconImage = logo
            NSApplication.shared.dockTile.contentView = TransparentPigiDockIcon(image: logo)
            NSApplication.shared.dockTile.display()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(state)
                .environment(layout)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            Image(systemName: "envelope")
            Text("\(state.unreadTotal)")
                .modifier(WindowOpener())
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "main") {
            RootView()
                .environment(state)
                .environment(layout)
                .environment(updater)
                .preferredColorScheme(appearance.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await state.syncFromArchive() }
                }
                .task { await updater.check() }
                .frame(minWidth: 1020, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .onChange(of: appearance) { appearance.apply() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    MainWindow.show()
                    layout.showingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("视图") {
                Button("收起邮箱栏") { layout.setSidebarCollapsed(true) }.shortcut(.collapseSidebar)
                Button("展开邮箱栏") { layout.setSidebarCollapsed(false) }.shortcut(.expandSidebar)
            }
            CommandGroup(after: .newItem) {
                Button("刷新") { Task { await state.reloadAll() } }
                    .shortcut(.refresh)
            }
        }
    }
}

/// Lets AppKit open the main window, which only SwiftUI's openWindow can do.
@MainActor
enum MainWindow {
    static var open: (() -> Void)?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

private struct WindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task { MainWindow.open = { openWindow(id: "main") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A click on the Dock icon with every window closed brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }
}
