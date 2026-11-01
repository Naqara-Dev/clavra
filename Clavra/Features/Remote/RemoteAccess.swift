import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network

/// Clavra's tabs on a phone, over the local network. Off until you turn it on; the phone scans a QR
/// code holding this Mac's address and a fresh 256-bit key, and every phone has to be allowed here.
///
/// The page is plain HTTP (a phone won't trust a certificate this Mac makes up), so everything after
/// it loads is sealed with ChaCha20-Poly1305 under the key from the QR code. The key sits after the
/// `#` in the URL and never crosses the network. Each WebSocket gets a random challenge that every
/// message is bound to, and carries a sequence number, so nothing can be replayed. What this can't
/// stop is someone on the same network who rewrites the page as it loads; use it on networks you trust.
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

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var page: NWListener?
    @ObservationIgnored private var socket: NWListener?
    @ObservationIgnored private var key = SymmetricKey(size: .bits256)
    @ObservationIgnored private var links: [UUID: Link] = [:]
    @ObservationIgnored private var allowedDevices: Set<String> = []
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = Date.now

    static let idleLimit: TimeInterval = 30 * 60

    // MARK: On and off

    func start() {
        guard !isOn else { return }
        problem = nil
        guard let address = Self.localAddress() else {
            problem = "This Mac isn't on a local network. Join Wi-Fi first."
            return
        }
        key = SymmetricKey(size: .bits256)
        allowedDevices = []
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
        for link in links.values { link.connection.cancel() }
        links = [:]
        devices = []
        page?.cancel()
        socket?.cancel()
        page = nil
        socket = nil
        idle?.cancel()
        isOn = false
        url = nil
        qr = nil
        allowedDevices = []
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
        let secret = key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let link = URL(string: "http://\(address):\(pagePort)/#\(socketPort).\(secret)")
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

    func allow(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), let link = links[id] else { return }
        devices[index].allowed = true
        link.allowed = true
        allowedDevices.insert(link.deviceID)
        sendSessions(to: link)
        sendScreen(to: link, full: true)
    }

    func disconnect(_ id: UUID) {
        if let link = links.removeValue(forKey: id) {
            link.send(["t": "bye"], key: key)
            allowedDevices.remove(link.deviceID)
            link.connection.cancel()
        }
        devices.removeAll { $0.id == id }
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
        let connection: NWConnection
        let challenge = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var deviceID = ""
        var allowed = false
        var received = 0
        var sent = 0
        var session: Session.ID?
        var seen: [String] = []

        init(_ connection: NWConnection) { self.connection = connection }

        func send(_ object: [String: Any], key: SymmetricKey) {
            sent += 1
            var message = object
            message["n"] = sent
            guard let json = try? JSONSerialization.data(withJSONObject: message),
                  let box = try? ChaChaPoly.seal(json, using: key, authenticating: challenge) else { return }
            write(box.combined)
        }

        func write(_ data: Data) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
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
        link.connection.receiveMessage { [weak self] data, _, _, error in
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
            link.connection.cancel()
            return
        }
        link.received = number
        lastActivity = .now
        switch message["t"] as? String {
        case "hello":
            link.deviceID = (message["device"] as? String) ?? ""
            let name = String(((message["name"] as? String) ?? "Phone").prefix(40))
            let known = allowedDevices.contains(link.deviceID)
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
            guard link.allowed, let raw = message["session"] as? String, let id = UUID(uuidString: raw) else { return }
            link.session = id
            link.seen = []
            sendSessions(to: link)
            sendScreen(to: link, full: true)
        case "input":
            guard link.allowed, let text = message["data"] as? String, let session = target(of: link) else { return }
            guard canType(in: session) else { return link.send(["t": "readonly"], key: key) }
            session.receiveRemote(text)
        default:
            break
        }
    }

    private func canType(in session: Session) -> Bool {
        session.isLive && (session.server.place != .production || typingInProduction)
    }

    private func target(of link: Link) -> Session? {
        guard let model else { return nil }
        if let id = link.session, let session = model.session(id) { return session }
        let session = model.current ?? model.sessions.first
        link.session = session?.id
        return session
    }

    // MARK: Telling phones what changed

    /// Tabs opened, closed or renamed.
    func sessionsChanged() {
        for link in links.values where link.allowed { sendSessions(to: link) }
    }

    /// A terminal printed something; phones watching it get the changed rows, at most ~15 times a second.
    func screenChanged(_ id: Session.ID) {
        guard isOn, links.values.contains(where: { $0.allowed && ($0.session == id || $0.session == nil) }), flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(66))
            guard let self else { return }
            self.flush = nil
            for link in self.links.values where link.allowed { self.sendScreen(to: link, full: false) }
        }
    }

    private func sendSessions(to link: Link) {
        guard let model else { return }
        let current = target(of: link)
        let list: [[String: Any]] = model.sessions.map { session in
            ["id": session.id.uuidString, "title": session.title, "host": session.server.target,
             "place": session.server.place.rawValue, "live": session.isLive, "typing": canType(in: session),
             "held": session.held?.command ?? ""]
        }
        link.send(["t": "sessions", "list": list, "selected": current?.id.uuidString ?? ""], key: key)
    }

    private func sendScreen(to link: Link, full: Bool) {
        guard let session = target(of: link) else { return link.send(["t": "screen", "empty": true], key: key) }
        let snapshot = ScreenSnapshot.rows(of: session.terminal)
        var changed: [[Any]] = []
        for (index, row) in snapshot.rows.enumerated() where full || index >= link.seen.count || link.seen[index] != row {
            changed.append([index, row])
        }
        link.seen = snapshot.rows
        link.send(["t": "screen", "session": session.id.uuidString, "cols": snapshot.cols, "count": snapshot.rows.count,
                   "rows": changed, "cursor": snapshot.cursor, "full": full,
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
