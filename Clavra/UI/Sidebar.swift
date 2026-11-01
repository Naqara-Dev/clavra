import SwiftUI

struct Sidebar: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 34)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                TextField("Search hosts", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
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
                        Text("Hosts you save show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                footerButton("Snippets", icon: "text.insert", isOn: isShowing(.snippets)) { model.show(.snippets) }
                footerButton("Keys", icon: "key", isOn: isShowing(.keys)) { model.show(.keys) }
                footerButton("New Host", icon: "plus") { model.newHost() }
                footerButton("Import ~/.ssh/config", icon: "square.and.arrow.down") { model.store.importSSHConfig() }
            }
            .padding(8)
        }
        .frame(width: 236)
        .background(Theme.sidebar)
    }

    private func isShowing(_ page: AppModel.Page) -> Bool { model.selection == nil && model.page == page }

    private func footerButton(_ title: String, icon: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5))
                .foregroundStyle(isOn ? Theme.ink : Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Theme.card : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
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
