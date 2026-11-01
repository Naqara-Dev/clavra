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
        HStack(spacing: 8) {
            if let prefix {
                Text(prefix).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).frame(width: 74, alignment: .leading)
            }
            Group {
                if secure { SecureField(title, text: $text) } else { TextField(title, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: mono ? .monospaced : .default))
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }
}

struct BrassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
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

struct PlaceChip: View {
    var place: Server.Place

    var body: some View {
        let tint = Theme.color(for: place)
        Text(place.label.lowercased())
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}
