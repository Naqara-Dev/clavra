import SwiftUI

/// Tunnels for this tab: the ones saved with the host, ones opened by hand, and ports the server is
/// listening on that could use one.
struct PortsPanel: View {
    var session: Session
    @Bindable var model: AppModel
    @State private var local = ""
    @State private var remote = ""

    private var suggestions: [Int] {
        (session.stats?.ports ?? []).filter { !session.forwards.isOpen(remotePort: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ports").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)

                section("Open now") {
                    if session.forwards.items.isEmpty {
                        Text("Nothing forwarded yet.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    }
                    ForEach(session.forwards.items) { item in
                        ForwardRow(item: item, saved: isSaved(item.forward),
                                   keep: { keep(item.forward) }, close: { session.forwards.close(item.id) })
                    }
                }

                section("Listening on \(session.server.title)") {
                    if session.stats == nil {
                        Text("Looking…").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    } else if suggestions.isEmpty {
                        Text("No other ports to forward.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    }
                    ForEach(suggestions, id: \.self) { port in
                        HStack(spacing: 8) {
                            Text(verbatim: ":\(port)").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
                            Text(Self.guess(port)).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            Spacer()
                            Button("Forward") { forward(remotePort: port) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.brass)
                        }
                        .frame(height: 26)
                    }
                }

                section("Add") {
                    HStack(spacing: 6) {
                        SoftField("Mac port", text: $local, mono: true).frame(width: 96)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        SoftField("host:port or port", text: $remote, mono: true)
                    }
                    Button("Forward") { addManual() }.buttonStyle(QuietButtonStyle()).disabled(parsedRemote == nil)
                    Text("localhost on the right means the server itself. Use another host name to reach a machine behind it.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private var parsedRemote: (host: String, port: Int)? {
        let text = remote.trimmingCharacters(in: .whitespaces)
        if let port = Int(text) { return ("localhost", port) }
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        let host = String(text[..<colon])
        return host.isEmpty ? nil : (host, port)
    }

    private func addManual() {
        guard let target = parsedRemote else { return }
        let wanted = Int(local.trimmingCharacters(in: .whitespaces)) ?? target.port
        session.openForward(Server.Forward(localPort: ForwardList.freePort(from: wanted), host: target.host, port: target.port))
        local = ""
        remote = ""
    }

    private func forward(remotePort: Int) {
        session.openForward(Server.Forward(localPort: ForwardList.freePort(from: remotePort), port: remotePort))
    }

    private func isSaved(_ forward: Server.Forward) -> Bool {
        model.store.host(session.server.id)?.forwards.contains { $0.id == forward.id } ?? false
    }

    /// Saves the tunnel with the host so it opens every time.
    private func keep(_ forward: Server.Forward) {
        guard var server = model.store.host(session.server.id) else { return }
        server.forwards.removeAll { $0.id == forward.id }
        server.forwards.append(forward)
        model.store.save(server)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            content()
        }
    }

    static func guess(_ port: Int) -> String {
        switch port {
        case 80, 8080, 8000, 3000, 4000, 5000, 5173, 8888: "web"
        case 443, 8443: "https"
        case 5432: "PostgreSQL"
        case 3306: "MySQL"
        case 6379: "Redis"
        case 27017: "MongoDB"
        case 9200: "Elasticsearch"
        case 11211: "Memcached"
        case 5672, 15672: "RabbitMQ"
        case 9090: "Prometheus"
        case 3001: "Grafana or web"
        default: ""
        }
    }
}

private struct ForwardRow: View {
    var item: ForwardList.Item
    var saved: Bool
    var keep: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("localhost:\(String(item.forward.localPort))").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                Text(item.forward.label).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    if case .open = item.status, let url = URL(string: "http://localhost:\(item.forward.localPort)") {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("localhost:\(item.forward.localPort)", forType: .string)
                        }
                    }
                    if !saved { Button("Open Every Time", action: keep) }
                    Divider()
                    Button("Close", action: close)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if case .failed(let message) = item.status {
                Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.color(for: .production))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
    }

    private var color: Color {
        switch item.status {
        case .open: Theme.color(for: .personal)
        case .opening: Theme.brass
        case .failed: Theme.color(for: .production)
        }
    }
}
