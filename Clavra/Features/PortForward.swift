import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// The tunnels open in one tab. Each listens on 127.0.0.1 on the Mac and carries every connection to
/// the server over a `direct-tcpip` channel, the same thing `ssh -L` does.
@MainActor @Observable
final class ForwardList {
    enum Status: Equatable {
        case opening
        case open
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        var forward: Server.Forward
        var status: Status
        var id: Server.Forward.ID { forward.id }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var listeners: [Server.Forward.ID: LocalListener] = [:]

    func isOpen(remotePort: Int) -> Bool {
        items.contains { $0.forward.port == remotePort && ($0.forward.host == "localhost" || $0.forward.host == "127.0.0.1") }
    }

    func open(_ forward: Server.Forward, through client: ClientBox) {
        close(forward.id)
        items.append(Item(forward: forward, status: .opening))
        Task {
            do {
                let listener = try await LocalListener.start(port: forward.localPort, host: forward.host,
                                                             remotePort: forward.port, client: client)
                guard items.contains(where: { $0.id == forward.id }) else { return listener.close() }
                listeners[forward.id] = listener
                set(forward.id, .open)
            } catch {
                set(forward.id, .failed(Self.describe(error, port: forward.localPort)))
            }
        }
    }

    func close(_ id: Server.Forward.ID) {
        listeners.removeValue(forKey: id)?.close()
        items.removeAll { $0.id == id }
    }

    func closeAll() {
        for listener in listeners.values { listener.close() }
        listeners = [:]
        items = []
    }

    /// The first port from `wanted` up that nothing on this Mac is using.
    static func freePort(from wanted: Int) -> Int {
        var port = wanted
        while port < 65_535 {
            if LocalListener.isFree(port) { return port }
            port += 1
        }
        return wanted
    }

    private func set(_ id: Server.Forward.ID, _ status: Status) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = status }
    }

    private static func describe(_ error: Error, port: Int) -> String {
        let raw = String(describing: error)
        if raw.contains("Address already in use") || raw.contains("EADDRINUSE") { return "Port \(port) is taken on this Mac." }
        if raw.contains("Permission denied") || raw.contains("EACCES") { return "Ports below 1024 need admin rights." }
        return "Couldn't open port \(port)."
    }
}

/// A listening socket on the Mac's loopback. Everything it accepts goes through the SSH client.
final class LocalListener: Sendable {
    private let channel: Channel

    private init(channel: Channel) { self.channel = channel }

    static func start(port: Int, host: String, remotePort: Int, client: ClientBox) async throws -> LocalListener {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Nothing is read until the tunnel's other end is ready, so no bytes fall on the floor.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { local in
                local.pipeline.addHandler(Opener(client: client, host: host, port: remotePort))
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        return LocalListener(channel: channel)
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Tries to bind the port for a moment.
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// Waits for an accepted connection to be live, opens its channel through SSH, then lets bytes flow.
/// Nothing is read before that, so nothing falls on the floor.
private final class Opener: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let client: ClientBox
    private let host: String
    private let port: Int

    init(client: ClientBox, host: String, port: Int) {
        self.client = client
        self.host = host
        self.port = port
    }

    func channelActive(context: ChannelHandlerContext) {
        let local = context.channel
        let origin = local.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!
        let (client, host, port) = (client, host, port)
        Task {
            do {
                let remote = try await client.client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
                ) { remote in
                    remote.pipeline.addHandler(Relay(peer: local))
                }
                try await local.pipeline.addHandler(Relay(peer: remote)).get()
                try await local.pipeline.removeHandler(self).get()
                try await local.setOption(ChannelOptions.autoRead, value: true).get()
            } catch {
                try? await local.close()
            }
        }
        context.fireChannelActive()
    }
}

/// Copies what one side reads to the other side, and closes the pair together.
private final class Relay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The SSH side reports the far end finishing as a half-close.
        if let event = event as? ChannelEvent, event == .inputClosed {
            peer.close(promise: nil)
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
