import AppKit
import SwiftUI

enum SidebarMetrics {
    /// Height of the row holding the window buttons.
    static let headerHeight: CGFloat = 52
    static let trafficLightsX: CGFloat = 22
    /// Window buttons are 54 wide; with an 8 gap and the 16-wide unfold icon the group is 78, centred in the folded rail.
    static let foldedLightsX: CGFloat = (LayoutState.railWidth - 78) / 2
    /// The unfold icon's box is as wide as the hover strip (24) and sits exactly on it, at the rail's right edge.
    static let foldedIconX: CGFloat = LayoutState.railWidth - 24
}

/// Wraps NSVisualEffectView so the window background blurs what is behind it.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Makes the window transparent and lets the content run under the title bar.
struct WindowConfigurator: NSViewRepresentable {
    var lightsX: CGFloat = SidebarMetrics.trafficLightsX
    nonisolated(unsafe) fileprivate static var currentX = SidebarMetrics.trafficLightsX

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.currentX = lightsX
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            Self.placeTrafficLights(in: window)
            // AppKit puts the buttons back whenever the window lays out again.
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    guard let window = note.object as? NSWindow else { return }
                    Self.placeTrafficLights(in: window)
                }
            }
        }
        return view
    }

    /// Moves the close/minimise/zoom buttons down and to the right, so they sit
    /// above the first sidebar row instead of hugging the corner.
    private static func placeTrafficLights(in window: NSWindow) {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = kinds.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let container = buttons[0].superview?.superview,
              let host = container.superview else { return }
        let barHeight = SidebarMetrics.headerHeight
        container.setFrameSize(NSSize(width: container.frame.width, height: barHeight))
        container.setFrameOrigin(NSPoint(x: container.frame.origin.x, y: host.bounds.height - barHeight))
        for (index, button) in buttons.enumerated() {
            let x = currentX + CGFloat(index) * 20
            let y = (barHeight - button.frame.height) / 2
            button.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard Self.currentX != lightsX else { return }
        Self.currentX = lightsX
        if let window = view.window { Self.placeTrafficLights(in: window) }
    }
}

/// The floating rounded panel that holds the mail list and the reader.
struct PaneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
    }
}

/// Round glass button used in the pane headers.
struct GlassCircleButton: View {
    let systemImage: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06)))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}

enum AvatarPalette {
    static let colors: [Color] = [
        .blue, .indigo, .teal, .orange, .pink, .purple, .green, .red, .brown, .cyan,
    ]

    static func color(for key: String) -> Color {
        let sum = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 36
    var imageURL: URL?

    var body: some View {
        let color = AvatarPalette.color(for: name)
        let letter = Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: Circle())
        if let imageURL {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    letter
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            letter
        }
    }
}


/// A small frosted-glass capsule button with an icon and a label.
struct GlassPill: View {
    let title: String
    let systemImage: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: systemImage).font(.system(size: compact ? 10 : 12, weight: .semibold))
                Text(title).font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            }
            .padding(.horizontal, compact ? 9 : 13)
            .frame(height: compact ? 24 : 32)
        }
        .buttonStyle(GlassPillStyle())
    }
}

struct GlassPillStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.accentColor : Color.primary.opacity(0.82))
            .background(.regularMaterial, in: Capsule())
            .background(Color.white.opacity(hovering ? 0.22 : 0.08), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(hovering ? 0.16 : 0.09), radius: hovering ? 8 : 5, y: 2)
            .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.04 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The message shown at the bottom of the window (`AppState.toast`).
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
            .allowsHitTesting(false)
    }
}


/// A centred frosted-glass confirmation card; the cancel action is plain text without a border.
struct GlassDialog: View {
    struct Action: Identifiable {
        let id = UUID()
        let label: String
        var isCancel = false
        let run: () -> Void
    }

    let title: String
    let message: String
    let actions: [Action]
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                ForEach(actions) { action in
                    DialogButton(label: action.label, isCancel: action.isCancel) {
                        action.run()
                        dismiss()
                    }
                }
            }
            .padding(22)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct DialogButton: View {
    let label: String
    let isCancel: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: isCancel ? .regular : .medium))
                .foregroundStyle(isCancel ? Color.secondary : Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    Capsule().fill(isCancel
                        ? Color.primary.opacity(hovering ? 0.06 : 0)
                        : Color.accentColor.opacity(hovering ? 0.2 : 0.12))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isCancel ? .cancelAction : nil)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}


/// The same refresh operation and progress state in both mail lists.
struct MailRefreshButton: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Button { Task { await state.reloadAll() } } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(state.isRefreshing ? 0 : 1)
                if state.isRefreshing { ProgressView().controlSize(.small) }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(state.isRefreshing)
        .help(state.isRefreshing ? "正在拉取最新邮件…" : "刷新邮件")
        .accessibilityLabel("刷新邮件")
    }
}

extension View {
    /// The confirmation card and the toast, shown over the main window and the menu bar panel alike.
    func feedbackOverlays() -> some View {
        modifier(FeedbackOverlays())
    }
}

private struct FeedbackOverlays: ViewModifier {
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        content
            .overlay {
                if let mail = state.unsubTarget {
                    GlassDialog(
                        title: "退订 \(mail.senderName)?",
                        message: mail.unsubKind == "one_click"
                            ? "将代你向发件人提交退订,成功后这封邮件会归档。"
                            : "该发件人没有一键退订。可以打开退订页面自己确认,或屏蔽该发件人(之后它的邮件会自动归档)。",
                        actions: (mail.unsubKind == "one_click"
                            ? [GlassDialog.Action(label: "退订") { state.unsubscribe(mail) }]
                            : (mail.unsubKind == "link" ? [GlassDialog.Action(label: "打开退订页面") { state.unsubscribe(mail) }] : [])
                                + [GlassDialog.Action(label: "屏蔽此发件人") { state.muteSender(mail) }])
                            + [GlassDialog.Action(label: "取消", isCancel: true) {}],
                        dismiss: { state.unsubTarget = nil })
                } else if let ids = state.markAllReadIDs {
                    GlassDialog(
                        title: "要把 \(ids.count) 封未读邮件都标记为已读吗?",
                        message: "当前列表里的所有未读邮件都会变为已读。",
                        actions: [GlassDialog.Action(label: "标记已读") { state.markAllRead(ids: ids) },
                                  GlassDialog.Action(label: "取消", isCancel: true) {}],
                        dismiss: { state.markAllReadIDs = nil })
                } else if let prompt = state.listTranslationPrompt {
                    GlassDialog(
                        title: "翻译当前可见的 \(prompt.sending) 封邮件？",
                        message: prompt.message,
                        actions: [GlassDialog.Action(label: "发送并翻译") { state.acceptListTranslation() },
                                  GlassDialog.Action(label: "取消", isCancel: true) {}],
                        dismiss: { state.finishListTranslationPrompt() })
                }
            }
            .overlay {
                if let toast = state.toast {
                    ToastView(text: toast)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.toast)
            .animation(.easeOut(duration: 0.18), value: state.unsubTarget?.id)
            .animation(.easeOut(duration: 0.18), value: state.markAllReadIDs != nil)
            .animation(.easeOut(duration: 0.18), value: state.listTranslationPrompt != nil)
    }
}
