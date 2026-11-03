import AppKit
import SwiftUI

/// Which of the three columns are shown and how wide they are. Persisted.
@Observable
@MainActor
final class LayoutState {
    /// Default width when unfolding: wide enough for full addresses if the setting asks for them.
    static var defaultWidth: CGFloat { UserDefaults.standard.bool(forKey: "showFullEmail") ? 224 : 147 }
    static let sidebarRange: ClosedRange<CGFloat> = 80...380
    /// Below this the sidebar shows avatars only; letting go there folds it completely.
    static let avatarOnlyBelow: CGFloat = 112
    /// Below this the addresses lose their domain.
    static let shortNamesBelow: CGFloat = 240
    static let listRange: ClosedRange<CGFloat> = 280...560
    /// Width of the folded sidebar: the narrowest dragged sidebar (80) plus the handle, so letting go there doesn't move anything.
    nonisolated static let handleWidth: CGFloat = 22
    nonisolated static let railWidth: CGFloat = 80 + handleWidth

    var sidebarWidth: CGFloat = LayoutState.stored("sidebarWidthV4", LayoutState.defaultWidth) { didSet { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidthV4") } }
    var listWidth: CGFloat = LayoutState.stored("listWidth", 360) { didSet { UserDefaults.standard.set(listWidth, forKey: "listWidth") } }
    var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") { didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }
    var showingSettings = false

    private static func stored(_ key: String, _ fallback: CGFloat) -> CGFloat {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? CGFloat(value) : fallback
    }

    /// ⌥1 folds the sidebar into a column of avatars, ⌥2 unfolds it.
    func setSidebarCollapsed(_ collapsed: Bool) {
        withAnimation(.snappy(duration: 0.28)) { sidebarCollapsed = collapsed }
    }

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.28)) { sidebarCollapsed.toggle() }
    }
}

/// The draggable divider right of the sidebar: hover shows a soft tint, a click folds the sidebar.
struct SidebarHandle: View {
    @Environment(LayoutState.self) private var layout
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: LayoutState.handleWidth)
            .overlay {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.primary.opacity(hovering || startWidth != nil ? 0.07 : 0))
            }
            .background(CursorArea(cursor: .resizeLeftRight))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onTapGesture { layout.setSidebarCollapsed(true) }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = layout.sidebarWidth }
                        let range = LayoutState.sidebarRange
                        layout.sidebarWidth = min(max((startWidth ?? 0) + value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        if layout.sidebarWidth < LayoutState.avatarOnlyBelow {
                            layout.sidebarWidth = LayoutState.defaultWidth
                            layout.setSidebarCollapsed(true)
                        }
                    }
            )
            .help("拖拽调整宽度,点击收起")
    }
}

/// Divider between the list and the reader: drag to resize, no visual.
struct ListHandle: View {
    @Binding var width: CGFloat
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 10)
            .background(CursorArea(cursor: .resizeLeftRight))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = width }
                        let range = LayoutState.listRange
                        width = min(max((startWidth ?? width) + value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// The strip that stands in for the folded sidebar, as wide as the divider it replaces; hover tints it, a click unfolds.
struct EdgeStrip: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Color.clear
                .frame(width: LayoutState.handleWidth)
                .overlay { Rectangle().fill(Color.primary.opacity(hovering ? 0.07 : 0)) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(CursorArea(cursor: .pointingHand))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("展开邮箱栏")
    }
}

/// Sets the cursor over a view and stops the window from being dragged from it.
private class CursorView: NSView {
    var cursor: NSCursor = .arrow
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // Cursor rects alone stay stale after a drag; tracking makes the cursor follow the pointer at once.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func viewDidMoveToWindow() { window?.invalidateCursorRects(for: self) }
}

private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> NSView { let v = CursorView(); v.cursor = cursor; return v }
    func updateNSView(_ view: NSView, context: Context) {}
}
