import SwiftUI
import UniformTypeIdentifiers

/// The server's files beside the terminal. Drop files from Finder to upload; downloads go to
/// ~/Downloads.
struct FilesPanel: View {
    var session: Session
    @State private var renaming: FileBrowser.Entry?
    @State private var deleting: FileBrowser.Entry?
    @State private var newFolder = false
    @State private var name = ""
    @State private var dropping = false
    @State private var selection: FileBrowser.Entry.ID?

    private var browser: FileBrowser { session.files }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            list
            if !browser.transfers.isEmpty {
                Rectangle().fill(Theme.line).frame(height: 1)
                transfers
            }
        }
        .task { await browser.start() }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task { browser.upload(await Self.urls(from: providers)) }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.brass.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $renaming) { entry in
            NameSheet(title: "Rename", action: "Rename", name: entry.name) { new in Task { await browser.rename(entry, to: new) } }
        }
        .sheet(isPresented: $newFolder) {
            NameSheet(title: "New Folder", action: "Create", name: "") { new in Task { await browser.makeFolder(new) } }
        }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { entry in
            Button("Delete", role: .destructive) { Task { await browser.delete(entry) } }
        } message: { entry in
            Text(entry.isFolder ? "Only an empty folder can be deleted." : "It's removed from \(session.server.title) for good.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Files").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                iconButton("arrow.up", help: "Enclosing folder") { Task { await browser.up() } }
                iconButton("arrow.clockwise", help: "Refresh") { Task { await browser.load() } }
                iconButton("folder.badge.plus", help: "New folder") { newFolder = true }
                iconButton("square.and.arrow.up", help: "Upload files") { chooseUploads() }
                iconButton(browser.showsHidden ? "eye" : "eye.slash", help: "Show hidden files") { browser.showsHidden.toggle() }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(browser.crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 1 { Text("/").foregroundStyle(Theme.tertiary) }
                        Button(crumb.name) { Task { await browser.go(to: crumb.path) } }
                            .buttonStyle(.plain)
                            .foregroundStyle(index == browser.crumbs.count - 1 ? Theme.ink : Theme.secondary)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if let error = browser.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.color(for: .production))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                if browser.loading && browser.entries.isEmpty {
                    ProgressView().controlSize(.small).padding(20)
                }
                ForEach(browser.visible) { entry in
                    FileRow(entry: entry, isSelected: selection == entry.id)
                        .onTapGesture(count: 2) {
                            if entry.isFolder || entry.isLink { Task { await browser.open(entry) } } else { browser.download(entry) }
                        }
                        .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
                        .contextMenu {
                            if entry.isFolder {
                                Button("Open") { Task { await browser.open(entry) } }
                            } else {
                                Button("Download") { browser.download(entry) }
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(browser.join(entry.name), forType: .string)
                            }
                            Button("cd Here in Terminal") {
                                let path = entry.isFolder ? browser.join(entry.name) : browser.path
                                session.type("cd " + Self.quoted(path), run: true)
                            }
                            Divider()
                            Button("Rename…") { renaming = entry }
                            Button("Delete…", role: .destructive) { deleting = entry }
                        }
                }
                if !browser.loading, browser.error == nil, browser.visible.isEmpty, !browser.path.isEmpty {
                    Text("Empty folder. Drop files here to upload.").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(20)
                }
            }
            .padding(6)
        }
        .scrollIndicators(.automatic)
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transfers").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                if browser.transfers.contains(where: \.finished) {
                    Button("Clear") { browser.clearFinished() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            ForEach(browser.transfers.prefix(4)) { transfer in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: transfer.direction == .up ? "arrow.up" : "arrow.down").font(.system(size: 9.5, weight: .semibold))
                        Text(transfer.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let failed = transfer.failed {
                            Text("failed").foregroundStyle(Theme.color(for: .production)).help(failed)
                        } else if transfer.finished {
                            Text("done")
                        } else {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(transfer.done), countStyle: .file)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    if !transfer.finished, let fraction = transfer.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.brass).controlSize(.mini)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        browser.upload(panel.urls)
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                urls.append(fileURL)
            }
        }
        return urls
    }
}

private struct FileRow: View {
    var entry: FileBrowser.Entry
    var isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.isFolder ? "folder.fill" : entry.isLink ? "arrow.turn.up.right" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(entry.isFolder ? Theme.brass.opacity(0.85) : Theme.tertiary)
                .frame(width: 16)
            Text(entry.name).font(.system(size: 12.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if !entry.isFolder, let size = entry.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? Theme.card : hovering ? Theme.card.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A small sheet that asks for one name.
struct NameSheet: View {
    var title: String
    var action: String
    @State var name: String
    var done: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            SoftField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(action) { done(name.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 340)
        .background(Theme.window)
    }
}
