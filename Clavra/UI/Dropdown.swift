import AppKit
import SwiftUI

/// One line in a dropdown: a choice, a quiet heading, or a hairline.
struct DropdownEntry: Identifiable {
    enum Kind { case item, heading, divider }

    var id: String
    var kind = Kind.item
    var title = ""
    /// A second, quieter line: a key's path, an identity's user.
    var detail: String?
    var icon: String?
    var isOn = false
    var tint: Color?
    var action: () -> Void = {}

    static func item(_ title: String, detail: String? = nil, icon: String? = nil, isOn: Bool = false, tint: Color? = nil,
                     id: String? = nil, action: @escaping () -> Void) -> DropdownEntry {
        DropdownEntry(id: id ?? "item:\(title)", title: title, detail: detail, icon: icon, isOn: isOn, tint: tint, action: action)
    }

    static func heading(_ title: String) -> DropdownEntry { DropdownEntry(id: "heading:\(title)", kind: .heading, title: title) }

    static func divider(_ id: String = UUID().uuidString) -> DropdownEntry { DropdownEntry(id: "divider:\(id)", kind: .divider) }
}

/// A field that opens Clavra's own list under it, instead of the system menu: soft card, hover rows,
/// a check on the current choice, arrows and Return to move and pick, Escape to close.
struct Dropdown: View {
    var icon: String?
    var title: String
    var detail: String?
    var placeholder = false
    var height: CGFloat = 36
    var entries: () -> [DropdownEntry]

    @State private var menu = FloatingMenu()
    @State private var anchor = AnchorBox()

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(placeholder ? Theme.tertiary : Theme.ink).lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(menu.isOpen ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: detail == nil ? height : max(height, 44))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(menu.isOpen ? Theme.brass.opacity(0.55) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader(box: anchor))
        .animation(.easeOut(duration: 0.15), value: menu.isOpen)
        #if DEBUG
        // `-ClavraOpenDropdown Automatic` opens the dropdown showing that title, for screenshots.
        .onAppear {
            guard UserDefaults.standard.string(forKey: "ClavraOpenDropdown") == title else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { toggle() }
        }
        #endif
    }

    private func toggle() {
        if menu.isOpen { menu.close(); return }
        guard let view = anchor.view else { return }
        menu.show(entries(), below: view)
    }
}

/// A button of any look that opens Clavra's list under it: the "+" and "…" menus.
struct MenuButton<Label: View>: View {
    var minWidth: CGFloat = 220
    var alignRight = false
    var entries: () -> [DropdownEntry]
    @ViewBuilder var label: Label

    @State private var menu = FloatingMenu()
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            if menu.isOpen { return menu.close() }
            guard let view = anchor.view else { return }
            menu.show(entries(), below: view, minWidth: minWidth, alignRight: alignRight)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .background(AnchorReader(box: anchor))
    }
}

extension View {
    /// Right-click (or Control-click) opens Clavra's list here, instead of the system menu.
    func clavraContextMenu(_ entries: @escaping () -> [DropdownEntry]) -> some View {
        background(ContextAnchor(entries: entries))
    }
}

private struct ContextAnchor: NSViewRepresentable {
    var entries: () -> [DropdownEntry]

    func makeNSView(context: Context) -> ContextAnchorView {
        let view = ContextAnchorView()
        view.entries = entries
        return view
    }

    func updateNSView(_ view: ContextAnchorView, context: Context) { view.entries = entries }
}

/// Marks where a right-click opens a list. It never takes a click itself; one monitor finds the
/// innermost marked view under the pointer.
final class ContextAnchorView: NSView {
    var entries: () -> [DropdownEntry] = { [] }
    let list = FloatingMenu()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ContextMenus.watch(self) }
    }
}

@MainActor enum ContextMenus {
    private static let anchors = NSHashTable<ContextAnchorView>.weakObjects()
    private static var monitor: Any?

    static func watch(_ view: ContextAnchorView) {
        anchors.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control), let window = event.window else { return event }
            // In window coordinates: the frame it's drawn in, cut to what its scroll view shows.
            let hits = anchors.allObjects.filter { view in
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
                // visibleRect can be the whole scroll view for SwiftUI's views; only where the two meet counts.
                let shown = view.convert(view.bounds, to: nil).intersection(view.convert(view.visibleRect, to: nil))
                return !shown.isEmpty && shown.contains(event.locationInWindow)
            }
            guard let best = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return event }
            let entries = best.entries()
            guard !entries.isEmpty else { return event }
            best.list.show(entries, at: event.locationInWindow, in: window)
            return nil
        }
    }
}

/// Lets SwiftUI hand over the NSView a dropdown hangs from.
@MainActor final class AnchorBox {
    weak var view: NSView?
}

struct AnchorReader: NSViewRepresentable {
    var box: AnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// Where the keyboard is in an open list.
@MainActor @Observable final class DropdownState {
    var highlighted: String?
}

/// The open list: a borderless child window under the field, so it can reach past a sheet's edge.
@MainActor @Observable final class FloatingMenu {
    private(set) var isOpen = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resign: NSObjectProtocol?
    @ObservationIgnored private weak var parent: NSWindow?
    @ObservationIgnored private var entries: [DropdownEntry] = []
    @ObservationIgnored private let state = DropdownState()

    func show(_ entries: [DropdownEntry], below anchor: NSView, minWidth: CGFloat = 240, alignRight: Bool = false) {
        guard let window = anchor.window else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        present(entries, from: rect, in: window, width: max(rect.width, minWidth), alignRight: alignRight) { event in
            // A click on the button that opened it only closes it, like a menu.
            event.window === window && anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
    }

    /// Opens at a point in `window`, for a right-click.
    func show(_ entries: [DropdownEntry], at point: NSPoint, in window: NSWindow, width: CGFloat = 240) {
        let rect = window.convertToScreen(NSRect(x: point.x, y: point.y, width: 0, height: 0))
        present(entries, from: rect, in: window, width: width, alignRight: false) { _ in false }
    }

    private func present(_ entries: [DropdownEntry], from anchorRect: NSRect, in window: NSWindow, width: CGFloat, alignRight: Bool,
                         swallow: @escaping (NSEvent) -> Bool) {
        close()
        self.entries = entries
        parent = window
        state.highlighted = entries.first { $0.kind == .item && $0.isOn }?.id
        let list = DropdownList(entries: entries, state: state, width: width) { [weak self] entry in self?.pick(entry) }
        let host = NSHostingView(rootView: list.environment(\.colorScheme, window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        let size = host.fittingSize

        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: alignRight ? anchorRect.maxX - size.width : anchorRect.minX, y: anchorRect.minY - 6 - size.height)
        if origin.y < screen.minY + 8 { origin.y = anchorRect.maxY + 6 }
        origin.x = max(min(origin.x, screen.maxX - size.width - 8), screen.minX + 8)

        let panel = KeyPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.appearance = window.effectiveAppearance
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isOpen = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown { return self.key(event) ? nil : event }
            if event.window !== panel {
                self.close()
                return swallow(event) ? nil : event
            }
            return event
        }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Clicking another app, or the window behind, closes the list.
                if let self, self.panel?.isVisible == true, NSApp.keyWindow !== self.panel { self.close() }
            }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            parent?.makeKey()
        }
        panel = nil
        isOpen = false
    }

    private func pick(_ entry: DropdownEntry) {
        close()
        entry.action()
    }

    /// Arrows move, Return picks, Escape closes. Everything else is left alone.
    private func key(_ event: NSEvent) -> Bool {
        let items = entries.filter { $0.kind == .item }
        switch event.keyCode {
        case 53:
            close()
            return true
        case 125, 126:
            guard !items.isEmpty else { return true }
            let current = items.firstIndex { $0.id == state.highlighted }
            let next = switch (current, event.keyCode) {
            case (nil, 125): 0
            case (nil, _): items.count - 1
            case (let i?, 125): min(i + 1, items.count - 1)
            case (let i?, _): max(i - 1, 0)
            }
            state.highlighted = items[next].id
            return true
        case 36, 76:
            if let entry = items.first(where: { $0.id == state.highlighted }) { pick(entry) }
            return true
        default:
            return false
        }
    }
}

/// A borderless panel that can still take the keyboard, so arrows and Escape reach the list.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct DropdownList: View {
    var entries: [DropdownEntry]
    var state: DropdownState
    var width: CGFloat
    var pick: (DropdownEntry) -> Void

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                switch entry.kind {
                case .divider:
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
                case .heading:
                    Text(entry.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                case .item:
                    DropdownRow(entry: entry, isHighlighted: state.highlighted == entry.id) { pick(entry) }
                        .onHover { if $0 { state.highlighted = entry.id } }
                }
            }
        }
        .padding(5)
    }

    var body: some View {
        Group {
            if entries.count > 10 {
                ScrollView { rows }.scrollIndicators(.never).frame(height: 340)
            } else {
                rows
            }
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DropdownRow: View {
    var entry: DropdownEntry
    var isHighlighted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon = entry.icon {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(entry.tint ?? Theme.secondary).frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 13)).foregroundStyle(entry.tint ?? Theme.ink).lineLimit(1)
                    if let detail = entry.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if entry.isOn {
                    Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.brass)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: entry.detail == nil ? 30 : 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHighlighted ? Theme.cardHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
