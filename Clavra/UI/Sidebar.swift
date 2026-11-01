import SwiftUI

struct Sidebar: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @AppStorage("SidebarGrouping") private var grouping = Grouping.place
    /// Groups folded shut, remembered between launches: "place:production", "tag:nginx".
    @AppStorage("SidebarCollapsed") private var collapsedText = ""

    enum Grouping: String, CaseIterable {
        case place, tag, none

        var label: String {
            switch self {
            case .place: "Place"
            case .tag: "Tag"
            case .none: "Nothing"
            }
        }
    }

    private var collapsed: Set<String> { Set(collapsedText.split(separator: "\n").map(String.init)) }

    private func toggle(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedText = set.sorted().joined(separator: "\n")
    }

    private var sections: [HostSection] { HostSection.make(model.store.grouped(matching: query), by: grouping) }

    /// Group by, and fold or unfold every group: in the "+" menu and on each group's header.
    @ViewBuilder private var viewMenu: some View {
        Picker("Group By", selection: $grouping) {
            ForEach(Grouping.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Button("Collapse All Groups") { collapsedText = sections.map(\.id).joined(separator: "\n") }
            .disabled(grouping == .none)
        Button("Expand All Groups") { collapsedText = "" }
            .disabled(collapsedText.isEmpty)
    }

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
                    Divider()
                    viewMenu
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
                    ForEach(sections) { section in
                        let isOpen = !query.isEmpty || !collapsed.contains(section.id)
                        GroupHeader(section: section, isOpen: isOpen) {
                            withAnimation(.easeOut(duration: 0.18)) { toggle(section.id) }
                        }
                        .contextMenu { viewMenu }
                        if isOpen {
                            ForEach(section.servers) { server in
                                HostRow(server: server, model: model)
                            }
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
                place("house", help: "Home: every host (⌘K)", page: .home)
                place("text.insert", help: "Snippets", page: .snippets)
                place("key", help: "Keys and identities", page: .keys)
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

/// A group of hosts in the sidebar: a place, a tag, or all of them.
struct HostSection: Identifiable {
    var id: String
    var title: String
    var tint: Color?
    var servers: [Server]

    static func make(_ byPlace: [(Server.Place, [Server])], by grouping: Sidebar.Grouping) -> [HostSection] {
        switch grouping {
        case .place:
            return byPlace.map { HostSection(id: "place:\($0.0.rawValue)", title: $0.0.label, tint: Theme.color(for: $0.0), servers: $0.1) }
        case .none:
            let all = byPlace.flatMap(\.1).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return all.isEmpty ? [] : [HostSection(id: "all", title: "Hosts", tint: nil, servers: all)]
        case .tag:
            let all = byPlace.flatMap(\.1)
            let tags = Set(all.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            var sections = tags.map { tag in
                HostSection(id: "tag:\(tag)", title: tag, tint: nil, servers: all.filter { $0.tags.contains(tag) })
            }
            let untagged = all.filter(\.tags.isEmpty)
            if !untagged.isEmpty { sections.append(HostSection(id: "tag:", title: "No tag", tint: nil, servers: untagged)) }
            return sections
        }
    }
}

/// A group's name and count; a click folds it shut or open.
private struct GroupHeader: View {
    var section: HostSection
    var isOpen: Bool
    var toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                if let tint = section.tint { Circle().fill(tint).frame(width: 5, height: 5) }
                Text(section.title).font(.system(size: 11, weight: .medium)).foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(section.servers.count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.tertiary)
                    .opacity(isOpen && !hovering ? 0 : 1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOpen ? "Collapse \(section.title)" : "Expand \(section.title)")
    }
}
