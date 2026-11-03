import Citadel
import Foundation
import NIOCore
import NIOSSH

/// "Test Connection" in the host editor: reaches the server, checks its key, signs in, runs one
/// harmless command, and hangs up. Never trusts a new key on its own; that stays the user's call.
enum ConnectionTest {
    enum Outcome: Equatable {
        case ok(String)
        /// The server answered, but Clavra hasn't been told to trust its key yet.
        case newKey(fingerprint: String, key: String, host: String, port: Int)
        case changedKey(String)
        case failed(String)
    }

    private final class Seen: @unchecked Sendable {
        var verdict: KnownHosts.Verdict = .trusted
        var fingerprint = ""
        var key = ""
        var host = ""
        var port = 22
    }

    static func run(_ server: Server, through jump: Server?, password: String? = nil, passphrase: String? = nil) async -> Outcome {
        let started = ContinuousClock.now
        let seen = Seen()
        do {
            let signIns = try Credentials.signIns(for: server, password: password, passphrase: passphrase)
            // Only a known key is accepted here; anything else stops the test and says why.
            func check(_ host: Server) -> HostKeyCheck {
                HostKeyCheck { key in
                    let verdict = KnownHosts.check(host: host.address, port: host.port, key: key)
                    if verdict != .trusted {
                        seen.verdict = verdict
                        seen.fingerprint = KnownHosts.fingerprint(key)
                        seen.key = key
                        seen.host = host.address
                        seen.port = host.port
                    }
                    return verdict == .trusted
                }
            }
            func settings(_ method: SSHAuthenticationMethod, for host: Server) -> SSHClientSettings {
                nonisolated(unsafe) let method = method
                var settings = SSHClientSettings(host: host.address, port: host.port,
                                                 authenticationMethod: { method }, hostKeyValidator: .custom(check(host)))
                settings.connectTimeout = .seconds(10)
                return settings
            }
            let client: SSHClient
            var hop: SSHClient?
            // With the key on Automatic, the one the server took is named in the result.
            let signedIn: Credentials.SignIn
            if let jump {
                let opened = try await Connector.connect(try Credentials.signIns(for: jump)) { try await SSHClient.connect(to: settings($0, for: jump)) }.client
                hop = opened
                (client, signedIn) = try await Connector.connect(signIns) { try await opened.jump(to: settings($0, for: server)) }
            } else {
                (client, signedIn) = try await Connector.connect(signIns) { try await SSHClient.connect(to: settings($0, for: server)) }
            }
            let output = try await client.executeCommand("uname -sr 2>/dev/null || ver; whoami", maxResponseSize: 1 << 16,
                                                         mergeStreams: true, inShell: false)
            try? await client.close()
            try? await hop?.close()
            let lines = String(buffer: output).split(separator: "\n").map(String.init)
            let elapsed = ContinuousClock.now - started
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let system = lines.first ?? "the server"
            let user = lines.count > 1 ? lines[1] : server.user
            let with = server.auth == .key && server.keyPath == nil ? " with \(signedIn.label)" : ""
            return .ok("Signed in as \(user)\(with) on \(system) in \(ms) ms.")
        } catch {
            switch seen.verdict {
            case .unknown: return .newKey(fingerprint: seen.fingerprint, key: seen.key, host: seen.host, port: seen.port)
            case .changed: return .changedKey(seen.fingerprint)
            case .revoked: return .failed(ClavraError.revokedHostKey.localizedDescription)
            case .trusted: return .failed(Session.describe(error))
            }
        }
    }
}
