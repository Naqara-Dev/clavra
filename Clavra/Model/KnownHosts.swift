import CryptoKit
import Foundation

/// Server keys Clavra has been told to trust, one OpenSSH-style line each: `[host]:port type base64`.
/// Plain entries in ~/.ssh/known_hosts count as trusted too, so hosts you already use don't ask again.
enum KnownHosts {
    enum Verdict: Equatable {
        case trusted
        case unknown
        /// Clavra trusted a different key for this host before.
        case changed
        /// Marked `@revoked` in a known_hosts file: never trusted, and never offered to trust.
        case revoked
    }

    static let file = Library.folder.appending(path: "known_hosts")

    static func check(host: String, port: Int, key: String) -> Verdict {
        check(host: host, port: port, key: key, ours: file,
              system: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/known_hosts"))
    }

    /// The same, against any two files; the tests use their own.
    static func check(host: String, port: Int, key: String, ours oursFile: URL, system systemFile: URL) -> Verdict {
        if isRevoked(key, files: [oursFile, systemFile]) { return .revoked }
        let name = entryName(host, port)
        let ours = entries(in: oursFile).filter { $0.names.contains(name) }
        if ours.contains(where: { $0.key == key }) { return .trusted }
        if !ours.isEmpty { return .changed }
        let system = entries(in: systemFile).filter { $0.names.contains(name) }
        if system.contains(where: { $0.key == key }) { return .trusted }
        // ~/.ssh/known_hosts knows this host by a key of the same type and this isn't it: as alarming
        // as a change Clavra saw itself. (A host listed only with a different type of key is new.)
        let type = key.split(separator: " ").first.map(String.init)
        if system.contains(where: { $0.key.split(separator: " ").first.map(String.init) == type }) { return .changed }
        return .unknown
    }

    /// Remembers `key` for the host, replacing any key it had.
    static func trust(host: String, port: Int, key: String) {
        let name = entryName(host, port)
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { !($0.split(separator: " ").first.map { $0.split(separator: ",").contains(Substring(name)) } ?? false) }
        lines.append("\(name) \(key)")
        try? FileManager.default.createDirectory(at: Library.folder, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// What Clavra trusts, for Settings: host, key type and fingerprint.
    struct Trusted: Identifiable, Hashable {
        var name: String
        var type: String
        var fingerprint: String
        var id: String { name + " " + fingerprint }
    }

    static func trusted() -> [Trusted] {
        entries(in: file).map { entry in
            Trusted(name: entry.names.joined(separator: ", "), type: String(entry.key.split(separator: " ").first ?? ""),
                    fingerprint: fingerprint(entry.key))
        }
    }

    /// Forgets a host's key; the next connection asks again.
    static func forget(_ trusted: Trusted) {
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { line in
                let parts = line.split(separator: " ")
                guard parts.count >= 3 else { return true }
                return !(String(parts[0]) == trusted.name.replacingOccurrences(of: ", ", with: ",")
                         && fingerprint("\(parts[1]) \(parts[2])") == trusted.fingerprint)
            }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
    }

    /// `SHA256:…`, the same fingerprint `ssh` prints.
    static func fingerprint(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return key }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }

    private static func entryName(_ host: String, _ port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    private struct Entry {
        let names: [String]
        let key: String
    }

    /// Whether a known_hosts file marks `key` `@revoked`. Checked for every host, whatever host
    /// pattern the line names: a key someone revoked shouldn't be trusted anywhere.
    static func isRevoked(_ key: String) -> Bool {
        isRevoked(key, files: [file, FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/known_hosts")])
    }

    static func isRevoked(_ key: String, files: [URL]) -> Bool {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let blob = parts[1]
        return files.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { line in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return fields.count >= 4 && fields[0].lowercased() == "@revoked" && fields[3] == blob
            }
        }
    }

    /// Skips hashed (`|1|…`) and marker (`@revoked`, `@cert-authority`) lines; revoked keys are
    /// read by `isRevoked`.
    private static func entries(in url: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 3, !line.hasPrefix("#"), !line.hasPrefix("|"), !line.hasPrefix("@") else { return nil }
            return Entry(names: parts[0].split(separator: ",").map(String.init), key: "\(parts[1]) \(parts[2])")
        }
    }
}

/// Where Clavra keeps its own files.
enum Library {
    /// Known hosts and anything tied to this Mac.
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Clavra", directoryHint: .isDirectory)

    /// iCloud Drive, as Finder shows it. Present when the user has iCloud Drive turned on.
    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)

    static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }

    static var syncsWithICloud: Bool {
        get { UserDefaults.standard.bool(forKey: "SyncWithICloud") && iCloudAvailable }
        set { UserDefaults.standard.set(newValue, forKey: "SyncWithICloud") }
    }

    /// Hosts and snippets: in a Clavra folder on iCloud Drive when syncing, otherwise next to the rest.
    /// Passwords stay in this Mac's Keychain either way.
    static var dataFolder: URL {
        syncsWithICloud ? iCloudDrive.appending(path: "Clavra", directoryHint: .isDirectory) : folder
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
