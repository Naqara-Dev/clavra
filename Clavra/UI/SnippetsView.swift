import SwiftUI

/// The commands you keep reaching for. ⌘; in any tab types one in.
struct SnippetsView: View {
    @Bindable var model: AppModel
    @State private var editing: Snippet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Snippets").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Press ⌘; in a terminal to type one. Guarded hosts still ask before risky ones.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("New Snippet") { editing = Snippet(name: "", command: "") }.buttonStyle(BrassButtonStyle())
                }
                .padding(.bottom, 22)

                VStack(spacing: 8) {
                    ForEach(model.snippets.snippets) { snippet in
                        HoverCard { editing = snippet } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(snippet.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                                    Spacer()
                                    if !snippet.runs { Text("types only").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                                }
                                Text(snippet.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(2)
                            }
                        }
                        .contextMenu {
                            Button("Edit…") { editing = snippet }
                            Button("Delete", role: .destructive) { model.snippets.delete(snippet) }
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .background(Theme.window)
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet, isNew: !model.snippets.snippets.contains { $0.id == snippet.id },
                          save: { model.snippets.save($0) }, delete: { model.snippets.delete(snippet) })
        }
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    var isNew: Bool
    var save: (Snippet) -> Void
    var delete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var ready: Bool { !snippet.name.trimmingCharacters(in: .whitespaces).isEmpty && !snippet.command.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Snippet" : "Edit Snippet").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            SoftField("Restart the app", text: $snippet.name, prefix: "Name")
            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                TextEditor(text: $snippet.command)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            }
            Toggle("Press Return after typing it", isOn: $snippet.runs).toggleStyle(.checkbox).font(.system(size: 12.5))
            HStack {
                if !isNew {
                    Button("Delete") { delete(); dismiss() }.buttonStyle(QuietButtonStyle(tint: Theme.color(for: .production)))
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    snippet.name = snippet.name.trimmingCharacters(in: .whitespaces)
                    save(snippet)
                    dismiss()
                }
                .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction).disabled(!ready).opacity(ready ? 1 : 0.5)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.window)
    }
}
