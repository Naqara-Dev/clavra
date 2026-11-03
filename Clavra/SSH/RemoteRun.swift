import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Runs one command on a saved host over a connection of its own, then hangs up. Only a host key
/// Clavra already trusts is accepted; a new one is for a tab to ask about.
enum RemoteRun {
    static func run(_ command: String, on server: Server, through jump: Server?) async throws -> String {
        let signIns = try Credentials.signIns(for: server)
        func check(_ host: Server) -> HostKeyCheck {
            HostKeyCheck { key in KnownHosts.check(host: host.address, port: host.port, key: key) == .trusted }
        }
        func settings(_ method: SSHAuthenticationMethod, for host: Server) -> SSHClientSettings {
            nonisolated(unsafe) let method = method
            var settings = SSHClientSettings(host: host.address, port: host.port,
                                             authenticationMethod: { method }, hostKeyValidator: .custom(check(host)))
            settings.connectTimeout = .seconds(12)
            return settings
        }
        var hop: SSHClient?
        let client: SSHClient
        do {
            if let jump {
                let opened = try await Connector.connect(try Credentials.signIns(for: jump)) { try await SSHClient.connect(to: settings($0, for: jump)) }.client
                hop = opened
                client = try await Connector.connect(signIns) { try await opened.jump(to: settings($0, for: server)) }.client
            } else {
                client = try await Connector.connect(signIns) { try await SSHClient.connect(to: settings($0, for: server)) }.client
            }
        } catch {
            try? await hop?.close()
            if String(describing: error).contains("hostKey") || String(describing: error).contains("HostKey") {
                throw ClavraError.message("Clavra hasn't trusted \(server.title)'s key yet. Connect to it once in a tab first.")
            }
            throw error
        }
        let box = ClientBox(client), hopBox = hop.map(ClientBox.init)
        defer { box.close(); hopBox?.close() }
        let output = try await client.executeCommand(command, maxResponseSize: 16 << 20, mergeStreams: false, inShell: false)
        return String(buffer: output)
    }
}
