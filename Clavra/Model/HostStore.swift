import Foundation
import SwiftUI

/// The saved hosts, kept as JSON in Application Support. Secrets are in the Keychain.
@MainActor @Observable
final class HostStore {
    private(set) var hosts: [Server] = []
    private var file: URL { Library.dataFolder.appending(path: "hosts.json") }
    /// Deleted here since launch, so a save that folds in the file's hosts doesn't bring them back.
    @ObservationIgnored private var removed: Set<Server.ID> = []

    init() {
        reload()
    }

    /// Reads the file again; it may have changed on another Mac through iCloud Drive.
    func reload() {
        if let saved = Library.load([Server].self, from: file), saved != hosts { hosts = saved }
    }

    /// Hosts in the folder Clavra is moving to win; ones only this Mac had are added to them.
    func merge(_ others: [Server]) {
        let new = others.filter { other in !hosts.contains { $0.id == other.id } }
        hosts += new
        persist()
    }

    func host(_ id: Server.ID) -> Server? { hosts.first { $0.id == id } }

    func save(_ host: Server) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        persist()
    }

    func delete(_ host: Server) {
        hosts.removeAll { $0.id == host.id }
        removed.insert(host.id)
        for index in hosts.indices where hosts[index].jump == host.id { hosts[index].jump = nil }
        Keychain.forget(host.id)
        persist()
    }

    func touch(_ id: Server.ID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnected = .now
        persist()
    }

    /// Hosts by place, production first, each sorted by name.
    func grouped(matching query: String) -> [(Server.Place, [Server])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = q.isEmpty ? hosts : hosts.filter {
            $0.title.lowercased().contains(q) || $0.address.lowercased().contains(q) || $0.user.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
        return [Server.Place.production, .staging, .personal].compactMap { place in
            let list = found.filter { $0.place == place }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return list.isEmpty ? nil : (place, list)
        }
    }

    var recent: [Server] {
        hosts.filter { $0.lastConnected != nil }.sorted { $0.lastConnected! > $1.lastConnected! }
    }

    /// Adds the `Host` blocks of ~/.ssh/config that aren't saved yet. Returns how many were added.
    @discardableResult
    func importSSHConfig() -> Int {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let new = Self.parseSSHConfig(text).filter { found in
            !hosts.contains { $0.address == found.address && $0.user == found.user && $0.port == found.port }
        }
        hosts += new
        persist()
        return new.count
    }

    nonisolated static func parseSSHConfig(_ text: String) -> [Server] {
        var result: [Server] = []
        var current: Server?
        func flush() {
            if let current { result.append(current) }
            current = nil
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                flush()
                // Wildcard blocks hold defaults, not a server you can open.
                if let alias = value.split(separator: " ").first, !alias.contains("*"), !alias.contains("?") {
                    current = Server(name: String(alias), address: String(alias), user: NSUserName())
                }
            case "match":
                flush()
            case "hostname": current?.address = value
            case "user": current?.user = value
            case "port": if let port = Int(value) { current?.port = port }
            case "identityfile":
                current?.keyPath = value
                current?.auth = .key
            default: break
            }
        }
        flush()
        return result
    }

    /// With iCloud Drive, another Mac may have written since we last read: hosts only the file has
    /// are kept, not overwritten.
    private func persist() {
        if Library.syncsWithICloud, let onDisk = Library.load([Server].self, from: file) {
            let theirs = onDisk.filter { other in !removed.contains(other.id) && !hosts.contains { $0.id == other.id } }
            hosts += theirs
        }
        Library.save(hosts, to: file)
    }
}
