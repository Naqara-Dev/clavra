import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Runs one command on a saved host over a connection of its own, then hangs up. Only a host key
/// Clavra already trusts is accepted; a new one is for a tab to ask about.
enum RemoteRun {
    static func run(_ command: String, on server: Server, through jump: Server?) async throws -> String {
        nonisolated(unsafe) let method = try Credentials.method(for: server)
        func check(_ host: Server) -> HostKeyCheck {
            HostKeyCheck { key in KnownHosts.check(host: host.address, port: host.port, key: key) == .trusted }
        }
        var settings = SSHClientSettings(host: server.address, port: server.port,
                                         authenticationMethod: { method }, hostKeyValidator: .custom(check(server)))
        settings.connectTimeout = .seconds(12)
        var hop: SSHClient?
        let client: SSHClient
        do {
            if let jump {
                nonisolated(unsafe) let jumpMethod = try Credentials.method(for: jump)
                var first = SSHClientSettings(host: jump.address, port: jump.port,
                                              authenticationMethod: { jumpMethod }, hostKeyValidator: .custom(check(jump)))
                first.connectTimeout = .seconds(12)
                let opened = try await SSHClient.connect(to: first)
                hop = opened
                client = try await opened.jump(to: settings)
            } else {
                client = try await SSHClient.connect(to: settings)
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
