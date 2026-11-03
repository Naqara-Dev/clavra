import Foundation
import Network

/// Whether each saved host answers on its SSH port, and how fast. A plain TCP connect that closes as
/// soon as it opens; nothing is sent, nothing logs in. Checked every five minutes, gently, so a
/// strict fail2ban never mistakes Clavra for a scanner; hosts that ask before risky commands every
/// minute, so you hear when one goes down.
@MainActor @Observable
final class HealthMonitor {
    enum Reach: Equatable {
        case up(milliseconds: Int)
        case down
    }

    private(set) var reach: [Server.ID: Reach] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hosts: () -> [Server] = { [] }
    /// A watched host stopped answering, or answered again. Told once each way.
    enum Change { case down(Server), back(Server, after: TimeInterval) }
    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private var round = 0
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private let online = Flag(true)

    /// Hear about hosts that ask before risky commands going down and coming back.
    static var alertsWhenDown: Bool {
        get { UserDefaults.standard.object(forKey: "AlertDown") == nil || UserDefaults.standard.bool(forKey: "AlertDown") }
        set { UserDefaults.standard.set(newValue, forKey: "AlertDown") }
    }

    init() {
        let online = online
        path.pathUpdateHandler = { update in online.set(update.status == .satisfied) }
        path.start(queue: .global(qos: .utility))
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "CheckHosts") == nil || UserDefaults.standard.bool(forKey: "CheckHosts") }
        set { UserDefaults.standard.set(newValue, forKey: "CheckHosts") }
    }

    func watch(_ hosts: @escaping () -> [Server]) {
        self.hosts = hosts
        restart()
    }

    func restart() {
        task?.cancel()
        guard Self.isEnabled else {
            reach = [:]
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self?.checkRound()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Every minute: watched hosts; every fifth: all of them.
    private func checkRound() async {
        let everyone = round % 5 == 0
        round += 1
        await check(hosts().filter { everyone || $0.guardsCommands })
    }

    func checkAll() async {
        await check(hosts())
    }

    private func check(_ list: [Server]) async {
        // Hosts behind a jump host can't be reached from here; that's the point of the jump.
        let targets = list.filter { $0.jump == nil }
        guard !targets.isEmpty else { return }
        var results: [(Server, Reach)] = []
        await withTaskGroup(of: (Server, Reach).self) { group in
            for host in targets {
                group.addTask { (host, await Self.probe(host.address, port: host.port)) }
            }
            for await result in group { results.append(result) }
        }
        // Offline, or (when every host checked failed) other hosts that were up don't answer
        // either: that's this Mac or its network (just woken, Wi-Fi changing), not the servers.
        var isUs = !online.get()
        if !isUs, results.allSatisfy({ $0.1 == .down }) {
            let checked = Set(results.map { $0.0.id })
            let others = hosts().filter { $0.jump == nil && !checked.contains($0.id) && { if case .up = reach[$0.id] { true } else { false } }($0) }
            if !others.isEmpty {
                var anyUp = false
                for other in others.prefix(3) {
                    if case .up = await Self.probe(other.address, port: other.port) { anyUp = true; break }
                }
                isUs = !anyUp
            }
        }
        for (host, result) in results {
            reach[host.id] = result
            guard !isUs else { continue }
            note(host, result)
        }
    }

    private func note(_ host: Server, _ result: Reach) {
        guard host.guardsCommands, Self.alertsWhenDown else { return }
        let up = if case .up = result { true } else { false }
        switch tracker.record(host.id, up: up) {
        case .wentDown: onChange?(.down(host))
        case .cameBack(let after): onChange?(.back(host, after: after))
        case nil: break
        }
    }

    @ObservationIgnored private var tracker = DownTracker<Server.ID>()

    nonisolated static func probe(_ address: String, port: Int) async -> Reach {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .down }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 6
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: parameters)
        let start = ContinuousClock.now
        let once = Once()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = ContinuousClock.now - start
                    let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                    if once.claim() { continuation.resume(returning: .up(milliseconds: max(ms, 1))) }
                    connection.cancel()
                case .failed, .waiting:
                    if once.claim() { continuation.resume(returning: .down) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 7) {
                if once.claim() { continuation.resume(returning: .down) }
                connection.cancel()
            }
        }
    }
}

/// Turns check results into "went down" and "came back", once each. One miss is a blip, two in a
/// row is down; a host never seen up since launch is never said to be down.
struct DownTracker<ID: Hashable> {
    enum Event: Equatable {
        case wentDown
        case cameBack(after: TimeInterval)
    }

    private var misses: [ID: Int] = [:]
    private var downSince: [ID: Date] = [:]
    private var seenUp: Set<ID> = []

    mutating func record(_ id: ID, up: Bool, at now: Date = .now) -> Event? {
        if up {
            misses[id] = 0
            seenUp.insert(id)
            return downSince.removeValue(forKey: id).map { .cameBack(after: now.timeIntervalSince($0)) }
        }
        let count = (misses[id] ?? 0) + 1
        misses[id] = count
        guard count == 2, downSince[id] == nil, seenUp.contains(id) else { return nil }
        downSince[id] = now
        return .wentDown
    }
}

/// A Bool set on one queue and read on another.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func get() -> Bool { lock.withLock { value } }
    func set(_ new: Bool) { lock.withLock { value = new } }
}

/// Lets exactly one of several callbacks finish a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
