import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network

/// Clavra's tabs on a phone. Off until you turn it on; the phone scans a QR code holding a fresh
/// 256-bit key, and every phone has to be allowed here.
///
/// Two ways in. Through clavra.naqara.dev (the default), the page loads over HTTPS and phone and Mac
/// meet in a relay room, from anywhere. On the same Wi-Fi only, this Mac serves the page itself over
/// plain HTTP. Either way, everything is sealed with ChaCha20-Poly1305 under the key from the QR code;
/// the key sits after the `#` in the URL and never crosses the network, so the relay sees only
/// ciphertext. Each connection gets a random challenge that every message is bound to, and carries a
/// sequence number, so nothing can be replayed.
@MainActor @Observable
final class RemoteAccess {
    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var allowed: Bool
    }

    private(set) var isOn = false
    private(set) var url: URL?
    private(set) var qr: NSImage?
    private(set) var devices: [Device] = []
    private(set) var problem: String?
    /// Production tabs are view-only from a phone unless this is on.
    var typingInProduction = false
    /// True while the relay room is open and this Mac is in it.
    private(set) var relayConnected = false

    /// Through clavra.naqara.dev (any network) or straight to this Mac (same Wi-Fi only).
    static var throughRelay: Bool {
        get { UserDefaults.standard.object(forKey: "PhoneRelay") == nil || UserDefaults.standard.bool(forKey: "PhoneRelay") }
        set { UserDefaults.standard.set(newValue, forKey: "PhoneRelay") }
    }

    /// The relay's WebSocket origin. `-ClavraRelay ws://127.0.0.1:8790` points Debug builds at
    /// Tests/relay-mock.js.
    static var relayOrigin: String {
        #if DEBUG
        if let custom = UserDefaults.standard.string(forKey: "ClavraRelay") { return custom }
        #endif
        return "wss://clavra.naqara.dev"
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var page: NWListener?
    @ObservationIgnored private var socket: NWListener?
    @ObservationIgnored private var key = SymmetricKey(size: .bits256)
    @ObservationIgnored private var links: [UUID: Link] = [:]
    /// Tokens this Mac handed to phones it allowed, mapped to the phone that holds each.
    @ObservationIgnored private var tokens: [String: String] = [:]
    /// Phones told no; they stay out until access is turned off.
    @ObservationIgnored private var refused: Set<String> = []
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = Date.now
    @ObservationIgnored private var relay: RelayClient?
    /// Relay phone numbers to the links they became.
    @ObservationIgnored private var relayed: [UInt32: UUID] = [:]

    static let idleLimit: TimeInterval = 30 * 60

    // MARK: On and off

    func start() {
        guard !isOn else { return }
        problem = nil
        key = SymmetricKey(size: .bits256)
        tokens = [:]
        refused = []
        if Self.throughRelay { return startRelay() }
        guard let address = Self.localAddress() else {
            problem = "This Mac isn't on a local network. Join Wi-Fi first."
            return
        }
        do {
            let socket = try listener(on: address, webSocket: true)
            let page = try listener(on: address, webSocket: false)
            self.socket = socket
            self.page = page
            socket.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            page.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.serve(connection) }
            }
            socket.stateUpdateHandler = { [weak self] _ in MainActor.assumeIsolated { self?.ready(address) } }
            page.stateUpdateHandler = { [weak self] _ in MainActor.assumeIsolated { self?.ready(address) } }
            socket.start(queue: .main)
            page.start(queue: .main)
            isOn = true
            lastActivity = .now
            watchIdle()
        } catch {
            problem = "Couldn't open a port: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        for link in links.values { link.cancel() }
        links = [:]
        relay?.stop()
        relay = nil
        relayed = [:]
        relayConnected = false
        devices = []
        page?.cancel()
        socket?.cancel()
        page = nil
        socket = nil
        idle?.cancel()
        isOn = false
        url = nil
        qr = nil
        tokens = [:]
        refused = []
    }

    private func listener(on address: String, webSocket: Bool) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        parameters.allowLocalEndpointReuse = true
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.maximumMessageSize = 1 << 20
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        return try NWListener(using: parameters)
    }

    /// Both ports known: the QR code can be drawn.
    private func ready(_ address: String) {
        guard let pagePort = page?.port?.rawValue, let socketPort = socket?.port?.rawValue, url == nil else { return }
        show(URL(string: "http://\(address):\(pagePort)/#\(socketPort).\(Self.base64url(key.withUnsafeBytes { Data($0) }))"))
    }

    /// Opens a room on the relay, named after a secret only this Mac knows. Phones find it from the
    /// QR code: `https://clavra.naqara.dev/connect#r=<room>&k=<key>`.
    private func startRelay() {
        let secret = Self.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let room = Self.base64url(Data(SHA256.hash(data: Data(secret.utf8))))
        guard let socketURL = URL(string: "\(Self.relayOrigin)/relay/\(room)?role=mac&s=\(secret)") else { return }
        let page = Self.relayOrigin.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://")
        let client = RelayClient(url: socketURL)
        client.onEvent = { [weak self] event in self?.relayEvent(event) }
        relay = client
        isOn = true
        lastActivity = .now
        watchIdle()
        client.start()
        show(URL(string: "\(page)/connect#r=\(room)&k=\(Self.base64url(key.withUnsafeBytes { Data($0) }))"))
    }

    private func relayEvent(_ event: RelayClient.Event) {
        switch event {
        case .connected:
            relayConnected = true
            problem = nil
        case .disconnected(let why):
            relayConnected = false
            problem = why
            // Phones on the relay went with it; they'll come back when the room does.
            for (_, id) in relayed { links[id]?.cancel(); links.removeValue(forKey: id); devices.removeAll { $0.id == id } }
            relayed = [:]
        case .joined(let number):
            let client = relay
            let link = Link(write: { data in client?.send(kind: 0, phone: number, data) },
                            close: { client?.send(kind: 2, phone: number, Data()) })
            links[link.id] = link
            relayed[number] = link.id
            link.write(Data("CLV1".utf8) + link.challenge)
        case .data(let number, let data):
            if let id = relayed[number], let link = links[id] { handle(data, from: link) }
        case .left(let number):
            if let id = relayed.removeValue(forKey: number) {
                links.removeValue(forKey: id)
                devices.removeAll { $0.id == id }
            }
        }
    }

    private func show(_ link: URL?) {
        url = link
        qr = link.flatMap { Self.code(for: $0.absoluteString) }
        #if DEBUG
        // `-ClavraRemote YES` turns this on at launch and prints the link, for testing without a phone.
        if UserDefaults.standard.bool(forKey: "ClavraRemote"), let link { print("CLAVRA_REMOTE \(link.absoluteString)"); fflush(stdout) }
        #endif
    }

    private func watchIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if Date.now.timeIntervalSince(self.lastActivity) > Self.idleLimit { self.stop() }
            }
        }
    }

    // MARK: Devices

    /// Lets the phone in, and hands it a random token so it can come back after a dropped
    /// connection without asking again. The token is ours, not something the phone chose.
    func allow(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), let link = links[id] else { return }
        devices[index].allowed = true
        link.allowed = true
        let token = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        tokens[token] = link.deviceID
        link.send(["t": "token", "token": token], key: key)
        sendSessions(to: link)
        sendScreen(to: link, full: true)
    }

    /// "Don't Allow" and "Remove": that phone is out, on every connection it has, until access is
    /// turned off. Its page stops reconnecting.
    func disconnect(_ id: UUID) {
        guard let link = links[id] else { return devices.removeAll { $0.id == id } }
        let phone = link.deviceID
        if !phone.isEmpty { refused.insert(phone) }
        tokens = tokens.filter { $0.value != phone || phone.isEmpty }
        for other in links.values where other.id == id || (!phone.isEmpty && other.deviceID == phone) {
            other.send(["t": "bye"], key: key)
            other.cancel()
            links.removeValue(forKey: other.id)
            devices.removeAll { $0.id == other.id }
        }
    }

    var waiting: Device? { devices.first { !$0.allowed } }

    // MARK: The page

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self?.respond(to: path, on: connection)
            }
        }
    }

    private func respond(to path: String, on connection: NWConnection) {
        let files = ["/": ("remote", "html", "text/html"), "/aead.js": ("aead", "js", "text/javascript"),
                     "/remote.js": ("remote", "js", "text/javascript")]
        var status = "404 Not Found"
        var type = "text/plain"
        var body = Data("Not here.".utf8)
        if let (name, ext, mime) = files[path], let file = Bundle.main.url(forResource: name, withExtension: ext),
           let contents = try? Data(contentsOf: file) {
            status = "200 OK"
            type = mime + "; charset=utf-8"
            body = contents
        }
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Referrer-Policy: no-referrer\r
        X-Content-Type-Options: nosniff\r
        Content-Security-Policy: default-src 'self'; connect-src ws: ; style-src 'self' 'unsafe-inline'; img-src 'self' data:\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: The socket

    /// One phone's WebSocket: its challenge, sequence numbers, and what it has seen of each screen.
    // Only touched on the main queue, where the listeners deliver.
    final class Link: @unchecked Sendable {
        let id = UUID()
        private let writer: (Data) -> Void
        private let closer: () -> Void
        let challenge = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var deviceID = ""
        var allowed = false
        var received = 0
        var sent = 0
        var session: Session.ID?
        /// What this phone has of the tab it watches, by scroll-invariant line number.
        var seen: [Int: String] = [:]
        var signature = ""
        var oldest = 0
        /// The screen's top line when this phone was last sent it.
        var top = 0
        var cols = 0
        var alternate = false

        init(write: @escaping (Data) -> Void, close: @escaping () -> Void) {
            writer = write
            closer = close
        }

        /// A phone on this Mac's own listener.
        convenience init(_ connection: NWConnection) {
            self.init(write: { data in
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
            }, close: { connection.cancel() })
            self.connection = connection
        }

        /// Only for phones on this Mac's own listener.
        private(set) var connection: NWConnection?

        func send(_ object: [String: Any], key: SymmetricKey) {
            sent += 1
            var message = object
            message["n"] = sent
            guard let json = try? JSONSerialization.data(withJSONObject: message),
                  let box = try? ChaChaPoly.seal(json, using: key, authenticating: challenge) else { return }
            write(box.combined)
        }

        func write(_ data: Data) { writer(data) }

        func cancel() { closer() }
    }

    private func accept(_ connection: NWConnection) {
        let link = Link(connection)
        links[link.id] = link
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    // The challenge goes first, in the clear; it's not a secret, only fresh.
                    link.write(Data("CLV1".utf8) + link.challenge)
                    self?.receive(on: link)
                case .failed, .cancelled:
                    self?.links.removeValue(forKey: link.id)
                    self?.devices.removeAll { $0.id == link.id }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on link: Link) {
        link.connection?.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return }
                if let data { self.handle(data, from: link) }
                if self.links[link.id] != nil { self.receive(on: link) }
            }
        }
    }

    private func handle(_ data: Data, from link: Link) {
        guard let box = try? ChaChaPoly.SealedBox(combined: data),
              let json = try? ChaChaPoly.open(box, using: key, authenticating: link.challenge),
              let message = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let number = message["n"] as? Int, number > link.received else {
            // Not sealed with our key, or replayed: this isn't a phone that scanned the code.
            link.cancel()
            return
        }
        link.received = number
        lastActivity = .now
        switch message["t"] as? String {
        case "hello":
            link.deviceID = String(((message["device"] as? String) ?? "").prefix(64))
            if link.deviceID == "anonymous" { link.deviceID = "" }
            if refused.contains(link.deviceID) {
                link.send(["t": "bye"], key: key)
                return link.cancel()
            }
            let name = String(((message["name"] as? String) ?? "Phone").prefix(40))
            let known = (message["token"] as? String).map { tokens[$0] != nil } ?? false
            link.allowed = known
            devices.append(Device(id: link.id, name: name, allowed: known))
            if known {
                sendSessions(to: link)
                sendScreen(to: link, full: true)
            } else {
                link.send(["t": "wait"], key: key)
                NSApp.requestUserAttention(.criticalRequest)
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "ClavraRemoteAllow") {
                    Task { try? await Task.sleep(for: .seconds(1)); self.allow(link.id) }
                }
                #endif
            }
        case "select":
            guard link.allowed, let raw = message["session"] as? String, let id = UUID(uuidString: raw),
                  model?.session(id) != nil else { return }
            link.session = id
            link.seen = [:]
            link.oldest = 0
            sendSessions(to: link)
            sendScreen(to: link, full: true)
        case "open":
            // A saved host, opened in a new tab on the Mac; the phone moves to it.
            guard link.allowed, let raw = message["host"] as? String, let id = UUID(uuidString: raw),
                  let model, let server = model.store.host(id) else { return }
            model.open(server)
            link.session = model.current?.id
            link.seen = [:]
            link.oldest = 0
            sendSessions(to: link)
            sendScreen(to: link, full: true)
        case "input":
            // Only into the tab the phone is looking at; if that one has gone, nowhere.
            guard link.allowed, let text = message["data"] as? String else { return }
            guard let id = link.session, (message["session"] as? String) == id.uuidString, let session = model?.session(id) else {
                sendSessions(to: link)
                return link.send(["t": "readonly"], key: key)
            }
            guard canType(in: session) else { return link.send(["t": "readonly"], key: key) }
            session.receiveRemote(text)
        default:
            break
        }
    }

    private func canType(in session: Session) -> Bool {
        session.isLive && (session.server.place != .production || typingInProduction)
    }

    /// The tab a phone is watching. When it has gone, the phone is moved to the front tab and told,
    /// so what it shows and where it types never differ.
    private func target(of link: Link) -> Session? {
        guard let model else { return nil }
        if let id = link.session, let session = model.session(id) { return session }
        let session = model.current ?? model.sessions.first
        if link.session != session?.id {
            link.session = session?.id
            link.seen = [:]
            link.oldest = 0
            link.signature = ""
        }
        return session
    }

    // MARK: Telling phones what changed

    /// Tabs or panes opened, closed or renamed.
    func sessionsChanged() {
        for link in links.values where link.allowed { sendSessions(to: link) }
    }

    /// What a phone's tab list shows; when it changes, the list is sent again.
    private func signature() -> String {
        (model?.sessions ?? []).map { "\($0.id)|\($0.title)|\($0.isLive)|\($0.held?.command ?? "")|\(canType(in: $0))" }.joined(separator: "\n")
            + (model?.store.hosts ?? []).map { "\($0.id)|\($0.title)" }.joined()
    }

    /// A terminal printed something; phones watching it get the changed rows, at most ~15 times a second.
    func screenChanged(_ id: Session.ID) {
        guard isOn, links.values.contains(where: \.allowed), flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(66))
            guard let self else { return }
            self.flush = nil
            let now = self.signature()
            for link in self.links.values where link.allowed {
                if link.signature != now { self.sendSessions(to: link) }
                self.sendScreen(to: link, full: false)
            }
        }
    }

    private func sendSessions(to link: Link) {
        guard let model else { return }
        let current = target(of: link)
        link.signature = signature()
        let list: [[String: Any]] = model.sessions.map { session in
            ["id": session.id.uuidString, "title": session.title, "host": session.server.target,
             "place": LabelStore.shared.resolve(session.server.place).rawValue, "placeName": session.server.place.label, "live": session.isLive, "typing": canType(in: session),
             "held": session.held?.command ?? ""]
        }
        let hosts: [[String: Any]] = model.store.hosts
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { ["id": $0.id.uuidString, "title": $0.title, "host": model.resolved($0).target, "place": LabelStore.shared.resolve($0.place).rawValue,
                    "placeName": $0.place.label] }
        link.send(["t": "sessions", "list": list, "hosts": hosts, "selected": current?.id.uuidString ?? ""], key: key)
    }

    private func sendScreen(to link: Link, full: Bool) {
        guard let session = target(of: link) else { return link.send(["t": "screen", "empty": true], key: key) }
        let term = session.terminal.getTerminal()
        let alternate = term.isCurrentBufferAlternate
        var full = full || link.cols != term.cols || link.alternate != alternate
        let oldest = ScreenSnapshot.oldestLine(of: term, hint: link.oldest)
        if oldest < link.oldest { full = true }
        if full { link.seen = [:] }
        link.oldest = alternate ? 0 : oldest
        link.cols = term.cols
        link.alternate = alternate

        let top = ScreenSnapshot.screenTop(of: term, oldest: oldest)
        let end = top + term.rows
        let start = alternate ? top : max(oldest, top - ScreenSnapshot.history)
        var changed: [[Any]] = []
        var seen: [Int: String] = [:]
        for row in start..<end {
            // Lines that were already above the screen last time don't change any more; anything
            // that was on screen then is checked again, since it may have changed on its way up.
            if row < link.top, let known = link.seen[row] {
                seen[row] = known
                continue
            }
            let json = ScreenSnapshot.render(term.getScrollInvariantLine(row: row), of: term)
            seen[row] = json
            if link.seen[row] != json { changed.append([row, json]) }
        }
        link.seen = seen
        link.top = top
        let cursor = term.getCursorLocation()
        link.send(["t": "screen", "session": session.id.uuidString, "cols": term.cols, "start": start, "end": end,
                   "rows": changed, "cursor": [cursor.x, top + cursor.y], "full": full,
                   "held": session.held?.command ?? "", "typing": canType(in: session)], key: key)
    }

    // MARK: Helpers

    /// The Mac's IPv4 address on Wi-Fi or Ethernet.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: entry.ifa_name)
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("en") { found.append((name, address)) }
        }
        return found.sorted { $0.name < $1.name }.first?.address
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func code(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
