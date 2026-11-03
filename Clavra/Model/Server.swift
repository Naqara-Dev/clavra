import Foundation

/// A server you connect to. Passwords and key passphrases live in the Keychain, never in this struct.
struct Server: Identifiable, Codable, Hashable, Sendable {
    enum Auth: String, Codable, CaseIterable, Sendable {
        case key, password
    }

    /// Where a host sits: Personal, Staging, Production, or a label the user made. Production gets
    /// a coral mark and asks before risky commands. Stored as a plain string, so files from older
    /// versions read as before.
    struct Place: Hashable, Codable, Sendable, Identifiable {
        let rawValue: String
        var id: String { rawValue }

        init(rawValue: String) { self.rawValue = rawValue }

        static let personal = Place(rawValue: "personal")
        static let staging = Place(rawValue: "staging")
        static let production = Place(rawValue: "production")
        static let builtIn = [personal, staging, production]

        var isBuiltIn: Bool { Self.builtIn.contains(self) }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    var id = UUID()
    var name: String
    var address: String
    var port = 22
    var user: String
    var auth: Auth = .key
    /// Private key file, `~` allowed. Nil means automatic: the key ~/.ssh/config names for this
    /// host, then the usual ones in ~/.ssh.
    var keyPath: String?
    var place: Place = .personal
    var lastConnected: Date?
    /// A saved host to hop through first, like `ProxyJump`.
    var jump: Server.ID?
    /// Ports carried from this Mac to the server while a session is open.
    var forwards: [Forward] = []
    /// Ask before risky commands. Nil follows the place: on for production, off elsewhere.
    var guardOverride: Bool?
    /// Risky commands on this host run only once a phone (through Phone Access) approves them.
    var phoneApproval = false
    /// Each tab runs inside tmux on the server, so a dropped connection, sleep or quitting Clavra
    /// doesn't end what's running; reconnecting picks it up where it was.
    var keepsAlive = false
    /// A saved identity to sign in as; when set, it supplies the user, key and password.
    var identity: UUID?
    /// Words to find and group hosts by: "nginx", "client-a", "db".
    var tags: [String] = []
    /// Where this host's password or passphrase is kept: its identity's, or its own.
    var secretsID: UUID { identity ?? id }
    /// Typed into the shell once it's up, e.g. `cd /srv/app && tmux attach`.
    var startup = ""
    var notes = ""

    var guardsCommands: Bool { guardOverride ?? (place == .production) }

    var title: String { name.isEmpty ? address : name }

    /// A `Host` block that only tells git which key to use (github.com, a GitLab server): you push
    /// to it, you don't open a shell on it.
    var isGitRemote: Bool {
        let forges = ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com"]
        return user == "git" || forges.contains(address.lowercased())
    }

    var target: String {
        #if DEBUG
        if let shown = Self.demoTargets[id.uuidString] { return shown }
        #endif
        return port == 22 ? "\(user)@\(address)" : "\(user)@\(address):\(port)"
    }

    #if DEBUG
    /// `-ClavraDemoTargets '{ "<host id>" = "deploy@10.0.1.12"; }'` shows a made-up address for a
    /// saved host, so screenshots of a local test server don't show a real account.
    static let demoTargets = UserDefaults.standard.dictionary(forKey: "ClavraDemoTargets") as? [String: String] ?? [:]
    #endif

    /// Two letters for the host's tile: the first letters of the first two words ("api prod" is
    /// "ap"), or the first two letters of a single word.
    var monogram: String {
        let words = title.lowercased().split { !($0.isLetter || $0.isNumber) }
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]) }
        return String((words.first ?? "").prefix(2))
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
    /// A tunnel, as `ssh -L`, `-R` or `-D` would make it.
    struct Forward: Identifiable, Codable, Hashable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            /// A port on the Mac reaches `host:port` from the server.
            case local
            /// `port` on the server reaches `host:localPort` from the Mac.
            case remote
            /// A SOCKS5 proxy on the Mac; every connection leaves from the server.
            case socks
        }

        var id = UUID()
        var kind = Kind.local
        var localPort: Int
        var host = "localhost"
        var port: Int
        /// Opened as soon as the session connects.
        var automatic = true

        var label: String { host == "localhost" || host == "127.0.0.1" ? ":\(port)" : "\(host):\(port)" }

        /// `localhost:3000 → :3000`, `server:8080 → Mac :3000`, `SOCKS localhost:1080`.
        var summary: String {
            switch kind {
            case .local: "localhost:\(localPort) → \(label)"
            case .remote: "server:\(port) → Mac \(host == "localhost" ? "" : host):\(localPort)"
            case .socks: "SOCKS localhost:\(localPort)"
            }
        }

        init(kind: Kind = .local, localPort: Int, host: String = "localhost", port: Int, automatic: Bool = true) {
            self.kind = kind
            self.localPort = localPort
            self.host = host
            self.port = port
            self.automatic = automatic
        }

        /// A TCP port: a whole number from 1 to 65535.
        static func port(_ text: String) -> Int? {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.allSatisfy(\.isASCII), let port = Int(text), (1...65_535).contains(port) else { return nil }
            return port
        }

        /// `8080` (meaning localhost) or `db.internal:5432`.
        static func endpoint(_ text: String) -> (host: String, port: Int)? {
            let text = text.trimmingCharacters(in: .whitespaces)
            if let port = port(text) { return ("localhost", port) }
            guard let colon = text.lastIndex(of: ":"), let port = port(String(text[text.index(after: colon)...])) else { return nil }
            let host = String(text[..<colon])
            return host.isEmpty || host.contains(" ") ? nil : (host, port)
        }

        /// Reads the two fields of the "add a tunnel" form for `kind`. Anything that isn't a real
        /// port is turned down rather than guessed at.
        static func parse(kind: Kind, local: String, remote: String) -> Server.Forward? {
            let typedMac = local.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .local:
                guard let target = endpoint(remote) else { return nil }
                // An empty Mac port means "the same number as on the server".
                let mac = typedMac.isEmpty ? target.port : port(typedMac)
                guard let mac else { return nil }
                return Server.Forward(kind: .local, localPort: mac, host: target.host, port: target.port)
            case .remote:
                guard let serverPort = port(remote), let mac = endpoint(local) else { return nil }
                return Server.Forward(kind: .remote, localPort: mac.port, host: mac.host, port: serverPort)
            case .socks:
                guard let mac = port(typedMac) else { return nil }
                return Server.Forward(kind: .socks, localPort: mac, port: 0)
            }
        }

        /// What's wrong with the form, naming the side it's on; nil while it's fine or still empty.
        static func problem(kind: Kind, local: String, remote: String) -> String? {
            let mac = local.trimmingCharacters(in: .whitespaces), server = remote.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .local:
                if !server.isEmpty, endpoint(server) == nil { return "Server side: a port from 1 to 65535, or host:port like db.internal:5432." }
                if !mac.isEmpty, port(mac) == nil { return "Mac side: a port from 1 to 65535, or leave it empty to use the server's number." }
            case .remote:
                if !server.isEmpty, port(server) == nil { return "Server side: a port from 1 to 65535." }
                if !mac.isEmpty, endpoint(mac) == nil { return "Mac side: a port from 1 to 65535, or host:port like localhost:3000." }
            case .socks:
                if !mac.isEmpty, port(mac) == nil { return "Mac side: a port from 1 to 65535, like 1080." }
            }
            return nil
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .local
            localPort = try c.decode(Int.self, forKey: .localPort)
            host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
            automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        }
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
        case id, name, address, port, user, auth, keyPath, place, lastConnected, jump, forwards, guardOverride, startup, notes, identity, tags, phoneApproval, keepsAlive
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
        startup = try c.decodeIfPresent(String.self, forKey: .startup) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        identity = try c.decodeIfPresent(UUID.self, forKey: .identity)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        phoneApproval = try c.decodeIfPresent(Bool.self, forKey: .phoneApproval) ?? false
        keepsAlive = try c.decodeIfPresent(Bool.self, forKey: .keepsAlive) ?? false
    }

    /// A copy with a new identity, for "Duplicate".
    func duplicate() -> Server {
        var copy = self
        copy.id = UUID()
        copy.name = title + " copy"
        copy.lastConnected = nil
        copy.forwards = forwards.map { var f = $0; f.id = UUID(); return f }
        return copy
    }
}
