import SwiftUI

struct Sidebar: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 34)

            // Find a host, or add one.
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    TextField("Search hosts", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))

                Menu {
                    Button("New Host…") { model.newHost() }
                    Button("Import from ~/.ssh/config") { model.store.importSSHConfig() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("New host or import (⌘N)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.store.grouped(matching: query), id: \.0) { place, servers in
                        Text(place.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                        ForEach(servers) { server in
                            HostRow(server: server, model: model)
                        }
                    }
                    if model.store.hosts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hosts you save show up here.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiary)
                            Button("Import ~/.ssh/config") { model.store.importSSHConfig() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.brass)
                        }
                        .padding(10)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            if let version = Updates.shared.available {
                Button { Updates.shared.checkNow() } label: {
                    Label("Clavra \(version) is ready", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.brass)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brass.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Download and install Clavra \(version)")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            // The places that aren't hosts: one quiet row of icons.
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 4) {
                place("text.insert", help: "Snippets", page: .snippets)
                place("key", help: "Keys", page: .keys)
                place("iphone", help: model.remote.isOn ? "Phone Access is on" : "Phone Access", page: .remote, dot: model.remote.isOn)
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .frame(width: 34, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("general", forKey: "SettingsTab") })
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
        }
        .frame(width: 236)
        .background(Theme.sidebar)
    }

    /// One icon in the bottom row; the page it opens is lifted onto a card while it's showing.
    private func place(_ icon: String, help: String, page: AppModel.Page, dot: Bool = false) -> some View {
        let isOn = isShowing(page)
        return Button { model.show(page) } label: {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(isOn ? Theme.ink : Theme.secondary)
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Theme.card : .clear))
                .overlay(alignment: .topTrailing) {
                    if dot { Circle().fill(Theme.color(for: .personal)).frame(width: 6, height: 6).padding(6) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func isShowing(_ page: AppModel.Page) -> Bool { model.selection == nil && model.page == page }

}

private struct HostRow: View {
    var server: Server
    var model: AppModel
    @State private var hovering = false

    private var openSession: Session? { model.sessions.first { $0.server.id == server.id && $0.isLive } }
    private var isFront: Bool { model.current?.server.id == server.id }

    private var subtitle: String {
        guard let jump = model.jumpHost(for: server) else { return server.target }
        return "\(server.target) via \(jump.title)"
    }

    var body: some View {
        Button {
            if let openSession { model.focus(openSession) } else { model.open(server) }
        } label: {
            HStack(spacing: 10) {
                HostTile(server: server)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering {
                    Button { model.editing = server } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit")
                } else {
                    HStack(spacing: 6) {
                        switch model.health.reach[server.id] {
                        case .up(let ms): Text(verbatim: "\(ms) ms").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.tertiary)
                        case .down: Text("down").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.color(for: .production))
                        case nil: EmptyView()
                        }
                        if openSession != nil {
                            Circle().fill(Theme.color(for: .personal)).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isFront ? Theme.card : hovering ? Theme.card.opacity(0.55) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(server.notes)
        .contextMenu {
            Button("Open in New Tab") { model.open(server) }
            Button("Edit…") { model.editing = server }
            Button("Duplicate") { model.store.save(server.duplicate()) }
            Button("Copy ssh Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.sshCommand(for: server), forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { model.store.delete(server) }
        }
    }
}
