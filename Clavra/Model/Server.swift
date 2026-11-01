import Foundation

/// A server you connect to. Passwords and key passphrases live in the Keychain, never in this struct.
struct Server: Identifiable, Codable, Hashable, Sendable {
    enum Auth: String, Codable, CaseIterable, Sendable {
        case key, password
    }

    /// Where a host sits. Production gets a red mark and asks before risky commands.
    enum Place: String, Codable, CaseIterable, Sendable {
        case personal, staging, production

        var label: String {
            switch self {
            case .personal: "Personal"
            case .staging: "Staging"
            case .production: "Production"
            }
        }
    }

    var id = UUID()
    var name: String
    var address: String
    var port = 22
    var user: String
    var auth: Auth = .key
    /// Private key file, `~` allowed. Nil means the first default key found in ~/.ssh.
    var keyPath: String?
    var place: Place = .personal
    var lastConnected: Date?
    /// A saved host to hop through first, like `ProxyJump`.
    var jump: Server.ID?
    /// Ports carried from this Mac to the server while a session is open.
    var forwards: [Forward] = []
    /// Ask before risky commands. Nil follows the place: on for production, off elsewhere.
    var guardOverride: Bool?

    var guardsCommands: Bool { guardOverride ?? (place == .production) }

    var title: String { name.isEmpty ? address : name }

    var target: String {
        port == 22 ? "\(user)@\(address)" : "\(user)@\(address):\(port)"
    }

    /// Two letters for the host's tile.
    var monogram: String {
        let letters = title.lowercased().filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2))
    }

    /// Reads `user@host:port`, `host:port` or `host`. The user defaults to the Mac's.
    init?(quick text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("ssh ") { rest.removeFirst(4) }
        guard !rest.isEmpty, !rest.contains(" ") else { return nil }
        var user = NSUserName()
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port = 22
        if let colon = rest.lastIndex(of: ":"), !rest.contains("]"), let number = Int(rest[rest.index(after: colon)...]) {
            port = number
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty, !user.isEmpty else { return nil }
        self.init(name: rest, address: rest, port: port, user: user)
    }

    /// `localhost:3000` on the Mac reaches `host:port` as seen from the server.
    struct Forward: Identifiable, Codable, Hashable, Sendable {
        var id = UUID()
        var localPort: Int
        var host = "localhost"
        var port: Int
        /// Opened as soon as the session connects.
        var automatic = true

        var label: String { host == "localhost" || host == "127.0.0.1" ? ":\(port)" : "\(host):\(port)" }
    }

    init(name: String, address: String, port: Int = 22, user: String) {
        self.name = name
        self.address = address
        self.port = port
        self.user = user
    }
}

extension Server {
    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, user, auth, keyPath, place, lastConnected, jump, forwards, guardOverride
    }

    /// Every field but the address is optional on disk, so files from older versions (or written by
    /// hand) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        address = try c.decode(String.self, forKey: .address)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? NSUserName()
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .key
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath)
        place = try c.decodeIfPresent(Place.self, forKey: .place) ?? .personal
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        jump = try c.decodeIfPresent(UUID.self, forKey: .jump)
        forwards = try c.decodeIfPresent([Forward].self, forKey: .forwards) ?? []
        guardOverride = try c.decodeIfPresent(Bool.self, forKey: .guardOverride)
    }
}
