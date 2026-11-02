import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// The tunnels open in one tab. Local ones (`ssh -L`) and the SOCKS proxy (`ssh -D`) listen on
/// 127.0.0.1 on the Mac and carry each connection to the server over a `direct-tcpip` channel.
/// Remote ones (`ssh -R`) ask the server to listen and bring its connections back to the Mac.
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
        /// The tunnel is open, but the server couldn't reach where the last connection was going.
        var note: String?
        var id: Server.Forward.ID { forward.id }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var listeners: [Server.Forward.ID: LocalListener] = [:]
    @ObservationIgnored private var remotes: [Server.Forward.ID: Task<Void, Never>] = [:]

    func isOpen(remotePort: Int) -> Bool {
        items.contains { $0.forward.kind == .local && $0.forward.port == remotePort && ($0.forward.host == "localhost" || $0.forward.host == "127.0.0.1") }
    }

    func open(_ forward: Server.Forward, through client: ClientBox) {
        close(forward.id)
        items.append(Item(forward: forward, status: .opening))
        if forward.kind == .remote { return openRemote(forward, through: client) }
        Task {
            do {
                // The listener binds with SO_REUSEADDR, which on macOS can sit quietly beside an app
                // already on *:port. Check first, so the user hears about it instead of a dead tunnel.
                if forward.localPort >= 1024, !LocalListener.isFree(forward.localPort) {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !LocalListener.isFree(forward.localPort) {
                        return set(forward.id, .failed("This Mac: port \(forward.localPort) is already used by another app. Pick another Mac port."))
                    }
                }
                let id = forward.id, target = "\(forward.host):\(forward.port)"
                let listener = try await LocalListener.start(port: forward.localPort, host: forward.host,
                                                             remotePort: forward.port, socks: forward.kind == .socks, client: client) { [weak self] in
                    Task { @MainActor in self?.note(id, "Server: couldn't reach \(target) from there. Is something listening on it?") }
                } reached: { [weak self] in
                    Task { @MainActor in self?.note(id, nil) }
                }
                guard items.contains(where: { $0.id == forward.id }) else { return listener.close() }
                listeners[forward.id] = listener
                set(forward.id, .open)
            } catch {
                set(forward.id, .failed(Self.describe(error, port: forward.localPort)))
            }
        }
    }

    /// The server listens on `port` (its loopback) for as long as the task runs; each connection is
    /// carried back and dialled from the Mac.
    private func openRemote(_ forward: Server.Forward, through client: ClientBox) {
        let id = forward.id
        remotes[id] = Task { [weak self] in
            do {
                try await Self.runRemote(forward, client: client) { [weak self] in await self?.set(id, .open) }
                self?.set(id, .failed("The server closed this tunnel."))
            } catch is CancellationError {
            } catch {
                let raw = String(describing: error)
                self?.set(id, .failed(raw.contains("globalRequest") || raw.contains("rejected") || raw.contains("Failure")
                    ? "Server: it said no. It may not allow forwarding (AllowTcpForwarding), or port \(forward.port) is taken there."
                    : "Server: couldn't open port \(forward.port) there."))
            }
        }
    }

    /// Citadel's own `runRemotePortForward` hands raw channel data to a ByteBuffer pipeline and traps
    /// on the first connection, so each forwarded channel is wired up here instead.
    private nonisolated static func runRemote(_ forward: Server.Forward, client: ClientBox,
                                              opened: @escaping @Sendable () async -> Void) async throws {
        let (macHost, macPort) = (forward.host, forward.localPort)
        try await client.client.withRemotePortForward(host: "localhost", port: forward.port, onOpen: { _ in await opened() }) { channel, _ in
            // The server sends nothing until this future succeeds, so the Mac side is dialled first.
            channel.pipeline.addHandler(ChannelDataCodec()).flatMap {
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .connect(host: macHost, port: macPort)
            }.flatMap { local in
                local.pipeline.addHandler(Relay(peer: channel)).flatMap {
                    channel.pipeline.addHandler(Relay(peer: local))
                }
            }
        }
    }

    func close(_ id: Server.Forward.ID) {
        listeners.removeValue(forKey: id)?.close()
        remotes.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }

    func closeAll() {
        for listener in listeners.values { listener.close() }
        for task in remotes.values { task.cancel() }
        listeners = [:]
        remotes = [:]
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

    private func note(_ id: Server.Forward.ID, _ text: String?) {
        if let index = items.firstIndex(where: { $0.id == id }), items[index].note != text { items[index].note = text }
    }

    private func set(_ id: Server.Forward.ID, _ status: Status) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = status }
    }

    private static func describe(_ error: Error, port: Int) -> String {
        let raw = String(describing: error)
        if raw.contains("Address already in use") || raw.contains("EADDRINUSE") { return "This Mac: port \(port) is already used by another app." }
        if raw.contains("Permission denied") || raw.contains("EACCES") { return "This Mac: ports below 1024 need admin rights." }
        return "This Mac: couldn't open port \(port)."
    }
}

/// A listening socket on the Mac's loopback. Everything it accepts goes through the SSH client.
final class LocalListener: Sendable {
    private let channel: Channel

    private init(channel: Channel) { self.channel = channel }

    /// `unreachable` is called when the server can't open the way to `host:remotePort` for a
    /// connection, `reached` when it can again.
    static func start(port: Int, host: String, remotePort: Int, socks: Bool = false, client: ClientBox,
                      unreachable: @escaping @Sendable () -> Void = {}, reached: @escaping @Sendable () -> Void = {}) async throws -> LocalListener {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Nothing is read until the tunnel's other end is ready, so no bytes fall on the floor.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { local in
                socks ? local.pipeline.addHandler(SOCKSOpener(client: client))
                      : local.pipeline.addHandler(Opener(client: client, host: host, port: remotePort, unreachable: unreachable, reached: reached))
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
    private let unreachable: @Sendable () -> Void
    private let reached: @Sendable () -> Void

    init(client: ClientBox, host: String, port: Int, unreachable: @escaping @Sendable () -> Void, reached: @escaping @Sendable () -> Void) {
        self.client = client
        self.host = host
        self.port = port
        self.unreachable = unreachable
        self.reached = reached
    }

    func channelActive(context: ChannelHandlerContext) {
        let local = context.channel
        let origin = local.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!
        let (client, host, port, unreachable, reached) = (client, host, port, unreachable, reached)
        Task {
            let remote: Channel
            do {
                remote = try await client.client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
                ) { remote in
                    remote.pipeline.addHandler(Relay(peer: local))
                }
                reached()
            } catch {
                unreachable()
                try? await local.close()
                return
            }
            do {
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

/// A small SOCKS5 server (RFC 1928, CONNECT only, no auth) in front of each accepted connection.
/// Once the client names where it wants to go, the rest is the same as a local tunnel.
private final class SOCKSOpener: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case greeting, request, connecting }

    private let client: ClientBox
    private var stage = Stage.greeting
    private var pending = ByteBuffer()

    init(client: ClientBox) { self.client = client }

    func channelActive(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        switch stage {
        case .greeting:
            // VER, NMETHODS, METHODS…
            guard pending.readableBytes >= 2, let bytes = pending.getBytes(at: pending.readerIndex, length: 2) else { return }
            guard bytes[0] == 5 else { return fail(context) }
            let length = 2 + Int(bytes[1])
            guard pending.readableBytes >= length else { return }
            pending.moveReaderIndex(forwardBy: length)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 0])), promise: nil)
            stage = .request
            process(context: context)
        case .request:
            // VER, CMD, RSV, ATYP, address, port
            guard pending.readableBytes >= 5, let head = pending.getBytes(at: pending.readerIndex, length: 5) else { return }
            guard head[0] == 5, head[1] == 1 else { return reply(context, code: 7) }
            let addressLength: Int
            switch head[3] {
            case 1: addressLength = 4
            case 3: addressLength = 1 + Int(head[4])
            case 4: addressLength = 16
            default: return reply(context, code: 8)
            }
            let total = 4 + addressLength + 2
            guard pending.readableBytes >= total, let request = pending.readBytes(length: total) else { return }
            let address = Array(request[4..<(4 + addressLength)])
            let port = Int(request[total - 2]) << 8 | Int(request[total - 1])
            let host: String
            switch head[3] {
            case 1: host = address.map(String.init).joined(separator: ".")
            case 3: host = String(decoding: address.dropFirst(), as: UTF8.self)
            default: host = stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(address[$0]) << 8 | Int(address[$0 + 1])) }.joined(separator: ":")
            }
            stage = .connecting
            connect(context: context, host: host, port: port)
        case .connecting:
            break
        }
    }

    private func connect(context: ChannelHandlerContext, host: String, port: Int) {
        let local = context.channel
        let origin = local.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!
        let client = client
        let loop = context.eventLoop
        let promise = loop.makePromise(of: Channel.self)
        promise.completeWithTask {
            try await client.client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
            ) { remote in
                remote.pipeline.addHandler(Relay(peer: local))
            }
        }
        promise.futureResult.whenComplete { result in
            switch result {
            case .success(let remote):
                // Hand the connection to the relay first, so nothing the client sends next is missed,
                // then pass on anything it already sent, then tell it the way is open.
                let leftover = self.pending
                self.pending = ByteBuffer()
                local.pipeline.addHandler(Relay(peer: remote))
                    .flatMap { local.pipeline.removeHandler(self) }
                    .whenComplete { _ in
                        if leftover.readableBytes > 0, let bytes = leftover.getBytes(at: leftover.readerIndex, length: leftover.readableBytes) {
                            remote.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
                        }
                        local.writeAndFlush(ByteBuffer(bytes: [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), promise: nil)
                    }
            case .failure:
                Self.reply(local, code: 5)
            }
        }
    }

    private func reply(_ context: ChannelHandlerContext, code: UInt8) {
        Self.reply(context.channel, code: code)
    }

    /// A SOCKS error reply, then hang up.
    private static func reply(_ channel: Channel, code: UInt8) {
        channel.writeAndFlush(ByteBuffer(bytes: [5, code, 0, 1, 0, 0, 0, 0, 0, 0])).whenComplete { _ in channel.close(promise: nil) }
    }

    private func fail(_ context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}

/// SSH channel data in, plain bytes out, and back. Stderr-type data never comes on a TCP channel.
private final class ChannelDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenComplete { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let incoming = unwrapInboundIn(data)
        guard case .channel = incoming.type, case .byteBuffer(let bytes) = incoming.data else { return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }
}

/// Copies what one side reads to the other side. When one side finishes sending, the other is told
/// the same (a half-close), and only after everything already read has been written; a side that
/// goes away takes the other with it, again after the last write. So replies that end with the
/// server closing (HTTP with `Connection: close`, `nc`, dumps) arrive whole.
private final class Relay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    /// Touched only on this side's event loop.
    private var lastWrite: EventLoopFuture<Void>?

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lastWrite = peer.writeAndFlush(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        let peer = peer
        afterWrites { peer.close(promise: nil) }
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            let peer = peer
            afterWrites { peer.close(mode: .output, promise: nil) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func afterWrites(_ then: @escaping @Sendable () -> Void) {
        if let lastWrite { lastWrite.whenComplete { _ in then() } } else { then() }
    }
}
