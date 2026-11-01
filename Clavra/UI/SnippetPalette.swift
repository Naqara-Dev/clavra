import SwiftUI

/// ⌘; over the terminal: type to filter, Return types the command into the shell.
struct SnippetPalette: View {
    var store: SnippetStore
    var done: (Snippet?) -> Void
    @State private var query = ""
    @State private var index = 0
    @State private var listHeight: CGFloat = 0
    @FocusState private var focused: Bool

    private var found: [Snippet] { store.matching(query) }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(Array(found.enumerated()), id: \.element.id) { offset, snippet in
                Button { done(snippet) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                            Spacer()
                            if !snippet.runs { Text("types only").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
                            if offset == index { KeyHint(text: "↩") }
                        }
                        Text(snippet.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(offset == index ? Theme.cardHover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if found.isEmpty {
                Text(store.snippets.isEmpty ? "No snippets yet. Add some from the sidebar." : "Nothing matches.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(14)
            }
        }
        .padding(6)
    }

    var body: some View {
        VStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "text.insert").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                    TextField("Snippet", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit { done(found[safe: index]) }
                        .onKeyPress(.downArrow) { index = min(index + 1, max(found.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { done(nil); return .handled }
                    KeyHint(text: "esc")
                }
                .padding(.horizontal, 14)
                .frame(height: 44)

                Rectangle().fill(Theme.line).frame(height: 1)
                // As tall as the list, up to 320 points; longer lists scroll.
                ScrollView {
                    list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 44), 320))
            }
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 50)
            Spacer()
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
        .transition(.opacity)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
