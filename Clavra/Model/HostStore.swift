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

    /// Hosts by place: production, staging, the user's own labels, then personal. Each sorted by name.
    func grouped(matching query: String) -> [(Server.Place, [Server])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = q.isEmpty ? hosts : hosts.filter {
            $0.title.lowercased().contains(q) || $0.address.lowercased().contains(q) || $0.user.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
        let labels = LabelStore.shared
        return labels.order.compactMap { place in
            let list = found.filter { labels.resolve($0.place) == place }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return list.isEmpty ? nil : (place, list)
        }
    }

    var recent: [Server] {
        hosts.filter { $0.lastConnected != nil }.sorted { $0.lastConnected! > $1.lastConnected! }
    }

    /// A label is gone: its hosts go back to Personal.
    func moveHosts(from place: Server.Place) {
        guard hosts.contains(where: { $0.place == place }) else { return }
        for index in hosts.indices where hosts[index].place == place { hosts[index].place = .personal }
        persist()
    }

    /// A host ~/.ssh/config describes, as the import preview shows it.
    struct ImportCandidate: Identifiable, Sendable {
        var server: Server
        /// `ProxyJump`'s first hop, as written: an alias, or `user@host:port`.
        var jump: String?
        /// Every `IdentityFile` that applies, in order; the first becomes the host's key.
        var keys: [String]
        /// Saved already, with the same address, user and port.
        var isSaved = false
        var id: UUID { server.id }
    }

    /// What importing ~/.ssh/config would add, with `Include`s followed and `Host *` defaults applied.
    func importCandidates() -> [ImportCandidate] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        guard let text = try? String(contentsOf: folder.appending(path: "config"), encoding: .utf8) else { return [] }
        return Self.sshConfigHosts(text, base: folder).map { candidate in
            var candidate = candidate
            let found = candidate.server
            candidate.isSaved = hosts.contains { $0.address == found.address && $0.user == found.user && $0.port == found.port }
            return candidate
        }
    }

    /// Saves the chosen hosts. A `ProxyJump` naming another imported or saved host becomes its jump host.
    func add(_ chosen: [ImportCandidate]) {
        var added = chosen.map(\.server)
        for index in added.indices {
            guard let hop = chosen[index].jump?.lowercased() else { continue }
            let me = added[index].id
            let match = added.first { $0.name.lowercased() == hop && $0.id != me }
                ?? hosts.first { $0.name.lowercased() == hop || $0.address.lowercased() == hop }
            added[index].jump = match?.id
        }
        hosts += added
        persist()
    }

    nonisolated static func parseSSHConfig(_ text: String) -> [Server] { sshConfigHosts(text).map(\.server) }

    /// Every concrete alias in ~/.ssh/config, resolved the way ssh does: the first value found for
    /// each option wins, across every block that matches (so `Host *` fills in what's missing), and
    /// every `IdentityFile` counts. `Include` is followed from `base` (~/.ssh), a few levels deep.
    nonisolated static func sshConfigHosts(_ text: String, base: URL? = nil) -> [ImportCandidate] {
        struct Block {
            var patterns: [String]
            var options: [(key: String, value: String)] = []
        }
        // Lines before the first Host apply to every host.
        var blocks = [Block(patterns: ["*"])]
        var aliases: [String] = []
        for (key, value) in configLines(text, base: base, depth: 0) {
            switch key {
            case "host":
                let patterns = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                blocks.append(Block(patterns: patterns))
                for alias in patterns where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!")
                    && !aliases.contains(alias) { aliases.append(alias) }
            case "match":
                // Match blocks depend on more than the name; they're left out.
                blocks.append(Block(patterns: []))
            default:
                blocks[blocks.count - 1].options.append((key, value))
            }
        }
        return aliases.map { alias in
            let lower = alias.lowercased()
            var values: [String: String] = [:]
            var keys: [String] = []
            for block in blocks {
                let positive = block.patterns.filter { !$0.hasPrefix("!") }.map { $0.lowercased() }
                let negative = block.patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()).lowercased() }
                guard positive.contains(where: { glob($0, lower) }), !negative.contains(where: { glob($0, lower) }) else { continue }
                for (key, value) in block.options {
                    if key == "identityfile" {
                        if !keys.contains(value) { keys.append(value) }
                    } else if values[key] == nil {
                        values[key] = value
                    }
                }
            }
            let address = (values["hostname"] ?? alias).replacingOccurrences(of: "%h", with: alias)
            var server = Server(name: alias, address: address, user: values["user"] ?? NSUserName())
            if let port = values["port"].flatMap({ Int($0) }), (1...65_535).contains(port) { server.port = port }
            server.keyPath = keys.first
            server.auth = .key
            let jump = values["proxyjump"].flatMap { $0.split(separator: ",").first.map(String.init) }
                .flatMap { $0.lowercased() == "none" ? nil : $0 }
            return ImportCandidate(server: server, jump: jump, keys: keys)
        }
    }

    /// The config with its `Include`s spliced in, one `key value` per line.
    nonisolated static func expandedConfig(_ text: String, base: URL) -> String {
        configLines(text, base: base, depth: 0).map { "\($0.0) \($0.1)" }.joined(separator: "\n")
    }

    /// `key value` pairs with lowercased keys, `Include` files spliced in where they appear.
    nonisolated private static func configLines(_ text: String, base: URL?, depth: Int) -> [(String, String)] {
        var result: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            guard key == "include" else {
                result.append((key, value))
                continue
            }
            guard let base, depth < 4 else { continue }
            for pattern in value.split(separator: " ") {
                for file in includedFiles(String(pattern), base: base) {
                    if let included = try? String(contentsOf: file, encoding: .utf8) {
                        result += configLines(included, base: base, depth: depth + 1)
                    }
                }
            }
        }
        return result
    }

    /// An `Include` argument: `~` for home, relative to ~/.ssh otherwise, `*` and `?` in the file name.
    nonisolated private static func includedFiles(_ pattern: String, base: URL) -> [URL] {
        let expanded = (pattern as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appending(path: expanded)
        let name = url.lastPathComponent
        guard name.contains("*") || name.contains("?") else { return [url] }
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { glob(name, $0) }.sorted().map { folder.appending(path: $0) }
    }

    /// The `IdentityFile`s ~/.ssh/config gives a host: from blocks whose pattern matches its name or
    /// address, or whose `HostName` is its address (so `github.com` finds the key of a
    /// `Host github-work` block that points there). The closest match comes first: a block named
    /// exactly like the saved name, then like the address, then a wildcard, then a `HostName`.
    nonisolated static func identityFiles(for server: Server, in text: String) -> [String] {
        let name = server.name.lowercased(), address = server.address.lowercased()
        let names = Set([address, name].filter { !$0.isEmpty })
        var found: [(rank: Int, order: Int, files: [String])] = []
        var patterns: [String] = []
        var hostName: String?
        var files: [String] = []
        func flush() {
            defer { patterns = []; hostName = nil; files = [] }
            guard !files.isEmpty else { return }
            func hit(_ pattern: String) -> Bool { names.contains { glob(pattern, $0) } }
            let positive = patterns.filter { !$0.hasPrefix("!") }
            let negative = patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
            guard !negative.contains(where: hit) else { return }
            let rank: Int
            if !name.isEmpty, positive.contains(name) { rank = 0 }
            else if positive.contains(address) { rank = 1 }
            else if positive.contains(where: hit) { rank = 2 }
            else if let hostName, names.contains(hostName.lowercased()) { rank = 3 }
            else { return }
            found.append((rank, found.count, files))
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch parts[0].lowercased() {
            case "host":
                flush()
                patterns = value.split(separator: " ").map { $0.lowercased() }
            case "match": flush()
            case "hostname": hostName = value
            case "identityfile": files.append(value)
            default: break
            }
        }
        flush()
        var result: [String] = []
        for block in found.sorted(by: { ($0.rank, $0.order) < ($1.rank, $1.order) }) {
            for file in block.files where !result.contains(file) { result.append(file) }
        }
        return result
    }

    /// ssh_config patterns: `*` for any run of characters, `?` for one.
    nonisolated static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
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
