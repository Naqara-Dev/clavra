import AppKit
import SwiftUI

/// "Where to?": one field that takes `user@server` or filters every saved host below it, the hosts
/// opened last, and every host by place with Connect, Test and Edit one click away.
struct HomeView: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @State private var tests: [Server.ID: HostTest] = [:]
    @FocusState private var focused: Bool

    private var query: String { text.trimmingCharacters(in: .whitespaces) }
    private var groups: [(Server.Place, [Server])] { model.store.grouped(matching: query) }
    private var firstMatch: Server? { groups.first?.1.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 6) {
                    Text("Where to?")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Type a host or a name. Clavra remembers the rest.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)

                field.padding(.top, 24)

                if model.store.hosts.isEmpty {
                    empty
                } else {
                    if query.isEmpty && !model.store.recent.isEmpty { recent }
                    hosts
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.never)
        .background(Theme.window)
        .onAppear { focused = true }
        .onChange(of: model.focusQuick) { focused = true }
    }

    // MARK: The field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
            TextField("user@server, or search \(model.store.hosts.count) hosts", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { text = "" }
            if !query.isEmpty {
                Text(firstMatch.map { "Return opens \($0.title)" } ?? "Return connects")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            } else {
                KeyHint(text: "⌘K")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    private func submit() {
        guard !query.isEmpty else { return }
        if let firstMatch { model.open(firstMatch) } else { model.quickConnect(query) }
        text = ""
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Recent")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.store.recent.prefix(6)) { server in
                        RecentChip(server: server) { model.open(server) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 28)
    }

    // MARK: Every host

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                heading(query.isEmpty ? "All hosts" : "Matching “\(query)”")
                Spacer()
                Menu {
                    Button("New Host…") { model.newHost() }
                    Button("Import from ~/.ssh/config") { model.importing = true }
                } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .padding(.top, 28)

            if groups.isEmpty {
                Text("No saved host matches. Press Return to connect to \(query) as typed.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .padding(.top, 10)
            }

            ForEach(groups, id: \.0) { place, servers in
                HStack(spacing: 6) {
                    Text(place.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.color(for: place).opacity(0.9))
                    Text(verbatim: "\(servers.count)").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                .padding(.top, 18)
                .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 54) }
                        HomeRow(server: server, model: model, test: tests[server.id],
                                runTest: { runTest(server) }, trust: { trust($0, then: server) })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("No hosts yet. Save one, or bring in the ones you already have.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Button("New Host") { model.newHost() }.buttonStyle(BrassButtonStyle())
                Button("Import ~/.ssh/config") { model.importing = true }.buttonStyle(QuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
    }

    // MARK: Testing

    private func runTest(_ server: Server) {
        tests[server.id] = .running
        let target = model.resolved(server)
        let jump = model.jumpHost(for: server)
        Task {
            let outcome = await ConnectionTest.run(target, through: jump)
            tests[server.id] = .done(outcome)
        }
    }

    private func trust(_ outcome: ConnectionTest.Outcome, then server: Server) {
        guard case .newKey(_, let key, let host, let port) = outcome else { return }
        KnownHosts.trust(host: host, port: port, key: key)
        runTest(server)
    }
}

enum HostTest: Equatable {
    case running
    case done(ConnectionTest.Outcome)
}

/// One host in the full list: who it is, how it's doing, and what you can do with it.
private struct HomeRow: View {
    var server: Server
    var model: AppModel
    var test: HostTest?
    var runTest: () -> Void
    var trust: (ConnectionTest.Outcome) -> Void
    @State private var hovering = false

    private var openSession: Session? { model.sessions.first { $0.server.id == server.id && $0.isLive } }

    private var subtitle: String {
        var text = model.resolved(server).target
        if let jump = model.jumpHost(for: server) { text += " via \(jump.title)" }
        if let identity = model.identities.identity(server.identity) { text += ", as \(identity.title)" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HostTile(server: server, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        ForEach(server.tags.prefix(3), id: \.self) { tag in
                            Text(tag).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.line))
                        }
                    }
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    status.opacity(hovering ? 0 : 1)
                    actions.opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let test { result(test).padding(.leading, 54).padding(.trailing, 12).padding(.bottom, 10) }
        }
        .background(hovering ? Theme.cardHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { connect() }
        .contextMenu { menuItems }
        .help(server.notes)
    }

    private var status: some View {
        HStack(spacing: 8) {
            switch model.health.reach[server.id] {
            case .up(let ms): Text(verbatim: "\(ms) ms").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
            case .down: Text("down").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.color(for: .production))
            case nil: EmptyView()
            }
            if openSession != nil {
                Text("open").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.color(for: .personal))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            icon("checkmark.shield", help: "Test Connection", action: runTest).disabled(test == .running)
            icon("slider.horizontal.3", help: "Edit") { model.editing = server }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More")
            Button(openSession == nil ? "Connect" : "Show", action: connect)
                .buttonStyle(BrassButtonStyle())
                .padding(.leading, 4)
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Connect") { connect() }
        Button("Open in New Tab") { model.open(server) }
        Button("Test Connection", action: runTest)
        Button("Edit…") { model.editing = server }
        Divider()
        Button("Duplicate") { model.store.save(server.duplicate()) }
        Button("Copy ssh Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.sshCommand(for: server), forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { model.store.delete(server) }
    }

    private func connect() {
        if let openSession { model.focus(openSession) } else { model.open(server) }
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private func result(_ test: HostTest) -> some View {
        switch test {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Testing…").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
        case .done(let outcome):
            switch outcome {
            case .ok(let text):
                line("checkmark.circle", text, tint: Theme.color(for: .personal))
            case .failed(let text):
                line("exclamationmark.triangle", text, tint: Theme.color(for: .production))
            case .changedKey(let fingerprint):
                line("exclamationmark.triangle", "This server's key changed. It now shows \(fingerprint).", tint: Theme.color(for: .production))
            case .newKey(let fingerprint, _, _, _):
                VStack(alignment: .leading, spacing: 6) {
                    line("key", "First time seeing this server's key: \(fingerprint)", tint: Theme.brass)
                    Button("Trust This Key and Test Again") { trust(outcome) }.buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private func line(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).padding(.top, 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A host opened lately, small enough that six fit in a row.
private struct RecentChip: View {
    var server: Server
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                HostTile(server: server, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(server.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(server.lastConnected.map { $0.formatted(.relative(presentation: .named)) } ?? server.target)
                        .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
