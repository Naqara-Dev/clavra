import SwiftUI

/// Tunnels for this tab: the ones saved with the host, ones opened by hand, and ports the server is
/// listening on that could use one.
struct PortsPanel: View {
    var session: Session
    @Bindable var model: AppModel
    @State private var local = ""
    @State private var remote = ""
    @State private var kind = Server.Forward.Kind.local

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
                    Segments(options: Server.Forward.Kind.allCases, selection: $kind) {
                        switch $0 { case .local: "To server"; case .remote: "To Mac"; case .socks: "SOCKS" }
                    }
                    ForwardFields(kind: kind, local: $local, remote: $remote)
                    Button(kind == .socks ? "Start Proxy" : "Forward") { addManual() }
                        .buttonStyle(QuietButtonStyle()).disabled(ForwardFields.parse(kind: kind, local: local, remote: remote) == nil)
                    Text(ForwardFields.note(kind))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func addManual() {
        guard var forward = ForwardFields.parse(kind: kind, local: local, remote: remote) else { return }
        if forward.kind != .remote { forward.localPort = ForwardList.freePort(from: forward.localPort) }
        session.openForward(forward)
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
                Text(verbatim: item.forward.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu {
                    if case .open = item.status, item.forward.kind == .local, let url = URL(string: "http://localhost:\(item.forward.localPort)") {
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

/// The two fields for a new tunnel, labelled for its kind, and how they read.
struct ForwardFields: View {
    var kind: Server.Forward.Kind
    @Binding var local: String
    @Binding var remote: String

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .local:
                SoftField("Mac port", text: $local, mono: true).frame(width: 96)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                SoftField("host:port or port", text: $remote, mono: true)
            case .remote:
                SoftField("Server port", text: $remote, mono: true).frame(width: 110)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                SoftField("Mac port, or host:port", text: $local, mono: true)
            case .socks:
                SoftField("Mac port, e.g. 1080", text: $local, mono: true)
            }
        }
    }

    static func note(_ kind: Server.Forward.Kind) -> String {
        switch kind {
        case .local: "A port on this Mac reaches the server. localhost on the right means the server itself; another name reaches a machine behind it."
        case .remote: "The server listens on its own loopback and each connection comes back to this Mac, like ssh -R. Handy for webhooks and showing a local app."
        case .socks: "A SOCKS5 proxy on this Mac, like ssh -D. Point a browser at it and its traffic leaves from the server."
        }
    }

    static func parse(kind: Server.Forward.Kind, local: String, remote: String) -> Server.Forward? {
        func split(_ text: String) -> (host: String, port: Int)? {
            let text = text.trimmingCharacters(in: .whitespaces)
            if let port = Int(text), port > 0, port < 65_536 { return ("localhost", port) }
            guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]), port > 0, port < 65_536 else { return nil }
            let host = String(text[..<colon])
            return host.isEmpty ? nil : (host, port)
        }
        switch kind {
        case .local:
            guard let target = split(remote) else { return nil }
            let mac = Int(local.trimmingCharacters(in: .whitespaces)) ?? target.port
            return Server.Forward(kind: .local, localPort: mac, host: target.host, port: target.port)
        case .remote:
            guard let serverPort = Int(remote.trimmingCharacters(in: .whitespaces)), serverPort > 0,
                  let mac = split(local) else { return nil }
            return Server.Forward(kind: .remote, localPort: mac.port, host: mac.host, port: serverPort)
        case .socks:
            guard let mac = Int(local.trimmingCharacters(in: .whitespaces)), mac > 0, mac < 65_536 else { return nil }
            return Server.Forward(kind: .socks, localPort: mac, port: 0)
        }
    }
}
