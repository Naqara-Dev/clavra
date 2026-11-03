import SwiftUI

/// The host's two letters on a faint wash of its place's colour.
struct HostTile: View {
    var server: Server
    var size: CGFloat = 28

    var body: some View {
        let tint = Theme.color(for: server.place)
        Text(server.monogram)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// A rounded, borderless input on a soft field colour.
struct SoftField<Trailing: View>: View {
    var title: String
    @Binding var text: String
    var secure = false
    var mono = false
    /// A quiet label inside the field, so a filled-in field still says what it is.
    var prefix: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, text: Binding<String>, secure: Bool = false, mono: Bool = false, prefix: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        _text = text
        self.secure = secure
        self.mono = mono
        self.prefix = prefix
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let prefix {
                Text(prefix).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).frame(width: 74, alignment: .leading)
                // A hairline between what the field is and what's in it, so the two never read as one.
                Rectangle().fill(Theme.line).frame(width: 1, height: 18)
            }
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: mono ? .monospaced : .default))
            // The hint is drawn by hand, a clear step quieter than anything typed.
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.tertiary).lineLimit(1).allowsHitTesting(false)
                }
            }
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }
}

/// A form field with its name above it, and an optional note below.
struct FormField<Content: View>: View {
    var label: String
    var note: String?
    @ViewBuilder var content: Content

    init(_ label: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            content
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays chips out in rows, wrapping when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

struct BrassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onBrass)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brass))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Small key hint, like ⌘K.
struct KeyHint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

/// A card that lights up a little under the pointer.
struct HoverCard<Content: View>: View {
    var action: () -> Void
    var content: Content
    @State private var hovering = false

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.action = action
        self.content = label()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Where the title bar would be: dragging moves the window, and a double-click zooms it (or
/// minimizes it, whichever System Settings › Desktop & Dock says), as on any Mac window. Sits
/// behind the tab strip and the tops of pages, so the controls there still get their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
