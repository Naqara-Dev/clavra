import SwiftUI

/// "Where to?": one field that takes a saved name or `user@server`, and the hosts you opened last.
struct HomeView: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var matches: [Server] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return model.store.hosts.filter {
            $0.title.lowercased().contains(q) || $0.address.lowercased().contains(q)
        }.prefix(5).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Where to?")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 84)
                Text("Type a host or a name. Clavra remembers the rest.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 6)

                field.padding(.top, 26)

                if !model.store.recent.isEmpty && matches.isEmpty {
                    Text("Recent")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 34)
                        .padding(.bottom, 10)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(model.store.recent.prefix(6)) { server in
                            HoverCard { model.open(server) } label: {
                                HStack(spacing: 12) {
                                    HostTile(server: server, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                        Text(server.lastConnected.map { $0.formatted(.relative(presentation: .named)) } ?? server.target)
                                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                    if server.place != .personal { PlaceChip(place: server.place) }
                                }
                            }
                        }
                    }
                }

                if matches.isEmpty {
                    HStack(spacing: 10) {
                        Button("New Host") { model.newHost() }.buttonStyle(BrassButtonStyle())
                        Text("or")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button("import from ~/.ssh/config") { model.store.importSSHConfig() }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink)
                            .underline(color: Theme.line)
                    }
                    .padding(.top, 30)
                }
            }
            .frame(width: 560)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .background(Theme.window)
        .onAppear { focused = true }
        .onChange(of: model.focusQuick) { focused = true }
    }

    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                TextField("user@server, or search \(model.store.hosts.count) hosts", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(submit)
                KeyHint(text: "⌘K")
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            if !matches.isEmpty {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, server in
                        Button { model.open(server); text = "" } label: {
                            HStack(spacing: 10) {
                                HostTile(server: server, size: 24)
                                Text(server.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                                Text(server.target).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                Spacer()
                                if index == 0 { KeyHint(text: "↩") }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(index == 0 ? Theme.cardHover : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
        .animation(.easeOut(duration: 0.15), value: matches.map(\.id))
    }

    private func submit() {
        if let first = matches.first { model.open(first) } else { model.quickConnect(text) }
        text = ""
    }
}
