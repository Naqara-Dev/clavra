import Foundation
import Network

/// Whether each saved host answers on its SSH port, and how fast. A plain TCP connect that closes as
/// soon as it opens; nothing is sent, nothing logs in. Checked every few minutes, gently, so a
/// strict fail2ban never mistakes Clavra for a scanner.
@MainActor @Observable
final class HealthMonitor {
    enum Reach: Equatable {
        case up(milliseconds: Int)
        case down
    }

    private(set) var reach: [Server.ID: Reach] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hosts: () -> [Server] = { [] }

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
                await self?.checkAll()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func checkAll() async {
        // Hosts behind a jump host can't be reached from here; that's the point of the jump.
        let targets = hosts().filter { $0.jump == nil }
        await withTaskGroup(of: (Server.ID, Reach).self) { group in
            for host in targets {
                group.addTask { (host.id, await Self.probe(host.address, port: host.port)) }
            }
            for await (id, result) in group { reach[id] = result }
        }
    }

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
