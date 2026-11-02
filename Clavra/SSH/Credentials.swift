import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

enum ClavraError: LocalizedError {
    case noKey
    case unreadableKey(String)
    case unsupportedKey(String)
    case needsPassphrase
    case noPassword
    case hostKeyRejected
    case notConnected
    case encryptedECDSA
    case wrongPassphrase
    case revokedHostKey

    var errorDescription: String? {
        switch self {
        case .noKey: "No private key found in ~/.ssh. Choose one in the host's settings."
        case .unreadableKey(let path): "Couldn't read the key at \(path)."
        case .unsupportedKey(let type): "\(type) keys aren't supported yet. Use an ed25519 or RSA key."
        case .needsPassphrase: "This key is protected by a passphrase. Add it in the host's settings."
        case .noPassword: "No password saved for this host. Add it in the host's settings."
        case .hostKeyRejected: "You didn't trust the server's key, so Clavra didn't connect."
        case .revokedHostKey: "This server showed a key that's marked @revoked in known_hosts, so Clavra refused it. Ask whoever runs the server what changed."
        case .notConnected: "This tab isn't connected right now."
        case .wrongPassphrase: "The saved passphrase doesn't open this key. Check it in the host's settings."
        case .encryptedECDSA: "Clavra can't open passphrase-protected ECDSA keys yet. Use an ed25519 key, or one without a passphrase."
        }
    }
}

/// Turns a host's saved settings into what Citadel needs to log in.
enum Credentials {
    static let defaultKeys = ["~/.ssh/id_ed25519", "~/.ssh/id_ecdsa", "~/.ssh/id_rsa"]
    /// Servers stop listening after a handful of wrong keys (OpenSSH's MaxAuthTries is 6).
    static let automaticLimit = 5

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// Private keys in ~/.ssh, by the header in their first line.
    static func keysInSSHFolder() -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard !name.hasSuffix(".pub"), !name.hasPrefix("known_hosts"), name != "config",
                  let handle = FileHandle(forReadingAtPath: folder.appending(path: name).path) else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 40), as: UTF8.self)
            return head.hasPrefix("-----BEGIN") && head.contains("PRIVATE KEY") ? "~/.ssh/\(name)" : nil
        }
    }

    /// What ~/.ssh/config says about keys for this host.
    static func configuredKeys(for server: Server) -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        guard let text = try? String(contentsOf: folder.appending(path: "config"), encoding: .utf8) else { return [] }
        return HostStore.identityFiles(for: server, in: HostStore.expandedConfig(text, base: folder))
            .filter { FileManager.default.fileExists(atPath: expand($0)) }
    }

    /// The keys "Automatic" tries, in order: the ones ~/.ssh/config names for this host, the usual
    /// names, then any other private key in ~/.ssh, the way ssh would offer them.
    static func automaticKeys(for server: Server) -> [String] {
        var list: [String] = []
        func add(_ path: String) {
            if !list.contains(where: { expand($0) == expand(path) }) { list.append(path) }
        }
        configuredKeys(for: server).forEach(add)
        defaultKeys.filter { FileManager.default.fileExists(atPath: expand($0)) }.forEach(add)
        keysInSSHFolder().forEach(add)
        return Array(list.prefix(automaticLimit))
    }

    /// `password` and `passphrase`, when given, stand in for what's saved (Test Connection uses
    /// what's typed in the editor before it's saved).
    static func method(for server: Server, password typedPassword: String? = nil, passphrase typedPassphrase: String? = nil) throws -> SSHAuthenticationMethod {
        switch server.auth {
        case .password:
            guard let password = typedPassword.flatMap({ $0.isEmpty ? nil : $0 }) ?? Keychain.password(for: server.secretsID) else { throw ClavraError.noPassword }
            return .passwordBased(username: server.user, password: password)
        case .key:
            let passphrase = (typedPassphrase.flatMap { $0.isEmpty ? nil : $0 } ?? Keychain.passphrase(for: server.secretsID)).map { Data($0.utf8) }
            if let path = server.keyPath { return try load(path, user: server.user, passphrase: passphrase) }
            return try automatic(for: server, passphrase: passphrase).method
        }
    }

    /// Every key "Automatic" can open, offered one after another; `tried` says which went last,
    /// which is the one that worked once signed in.
    static func automatic(for server: Server, passphrase: Data?) throws -> (method: SSHAuthenticationMethod, tried: KeyAttempts) {
        var loaded: [(String, SSHAuthenticationMethod)] = []
        var firstError: Error?
        for path in automaticKeys(for: server) {
            do {
                loaded.append((path, try load(path, user: server.user, passphrase: passphrase)))
            } catch {
                // A key behind a passphrase this host doesn't have is skipped, as ssh skips it.
                if firstError == nil { firstError = error }
            }
        }
        guard !loaded.isEmpty else { throw firstError ?? ClavraError.noKey }
        let attempts = KeyAttempts(loaded)
        return (.custom(attempts), attempts)
    }

    private static func load(_ path: String, user: String, passphrase: Data?) throws -> SSHAuthenticationMethod {
        guard let text = try? String(contentsOfFile: expand(path), encoding: .utf8) else { throw ClavraError.unreadableKey(path) }
        do {
            let type = try SSHKeyDetection.detectPrivateKeyType(from: text)
            switch type {
            case .ed25519:
                return .ed25519(username: user, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphrase))
            case .rsa:
                return .rsa(username: user, privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: passphrase))
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                return try ECDSAKey.method(user: user, text: text)
            default:
                throw ClavraError.unsupportedKey(type.description)
            }
        } catch let error as ClavraError {
            throw error
        } catch where text.contains("BEGIN EC PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY") {
            // Older PEM files: CryptoKit reads these directly.
            return try ECDSAKey.method(user: user, text: text)
        } catch {
            // The cipher name is base64 inside an OpenSSH file, so ask the parser what went wrong.
            let raw = String(describing: error)
            if raw.contains("missingDecryptionKey") || (passphrase == nil && text.contains("ENCRYPTED")) {
                throw ClavraError.needsPassphrase
            }
            if passphrase != nil, raw.contains("invalidCheck") || raw.contains("decrypt") || raw.contains("invalidPadding") {
                throw ClavraError.wrongPassphrase
            }
            throw error
        }
    }
}

/// Offers several keys in turn, like ssh does: when the server turns one down, NIO asks again and
/// the next one goes.
final class KeyAttempts: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private var queue: [(path: String, method: SSHAuthenticationMethod)]
    private let lock = NSLock()
    private var last: String?

    init(_ keys: [(String, SSHAuthenticationMethod)]) {
        queue = keys.map { (path: $0.0, method: $0.1) }
    }

    /// The key offered most recently.
    var lastTried: String? { lock.withLock { last } }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let next: (path: String, method: SSHAuthenticationMethod)? = lock.withLock {
            guard !queue.isEmpty else { return nil }
            let item = queue.removeFirst()
            last = item.path
            return item
        }
        guard let next else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        next.method.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: nextChallengePromise)
    }
}

/// ECDSA keys, which Citadel can sign with but doesn't read from a file. Unencrypted OpenSSH files
/// and PEM files are read here; an encrypted ECDSA key needs its passphrase removed or an
/// ed25519 key instead.
enum ECDSAKey {
    static func method(user: String, text: String) throws -> SSHAuthenticationMethod {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") { return try openSSH(user: user, text: text) }
        if text.contains("ENCRYPTED") { throw ClavraError.encryptedECDSA }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return .p256(username: user, privateKey: key) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return .p384(username: user, privateKey: key) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return .p521(username: user, privateKey: key) }
        // CryptoKit turns down some SEC1 files that OpenSSH writes; the scalar is easy to find by hand.
        let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        if let der = Data(base64Encoded: base64), let scalar = sec1Scalar(in: [UInt8](der)) {
            switch scalar.count {
            case 32: return .p256(username: user, privateKey: try P256.Signing.PrivateKey(rawRepresentation: scalar))
            case 48: return .p384(username: user, privateKey: try P384.Signing.PrivateKey(rawRepresentation: scalar))
            case 65, 66: return .p521(username: user, privateKey: try P521.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 66 - scalar.count) + scalar))
            default: break
            }
        }
        throw ClavraError.unsupportedKey("This ECDSA")
    }

    /// SEC1's ECPrivateKey starts `INTEGER 1, OCTET STRING scalar`; PKCS#8 wraps the same thing.
    private static func sec1Scalar(in der: [UInt8]) -> Data? {
        guard der.count > 8 else { return nil }
        for i in 0..<(der.count - 5) where der[i] == 0x02 && der[i + 1] == 0x01 && der[i + 2] == 0x01 && der[i + 3] == 0x04 {
            let length = Int(der[i + 4])
            let start = i + 5
            if [32, 48, 65, 66].contains(length), start + length <= der.count {
                return Data(der[start..<start + length])
            }
        }
        return nil
    }

    /// openssh-key-v1: magic, cipher, kdf, kdf options, key count, public key, then the private
    /// section: two check numbers, type, curve, public point, private scalar, comment.
    private static func openSSH(user: String, text: String) throws -> SSHAuthenticationMethod {
        let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: base64) else { throw ClavraError.unsupportedKey("This ECDSA") }
        var buffer = ByteBuffer(bytes: data)
        let magic = Array("openssh-key-v1\0".utf8)
        guard buffer.readBytes(length: magic.count) == magic,
              let cipher = buffer.readSSHText(), buffer.readSSHText() != nil, buffer.readSSHBytes() != nil,
              buffer.readInteger(as: UInt32.self) == 1, buffer.readSSHBytes() != nil,
              let privateBytes = buffer.readSSHBytes() else { throw ClavraError.unsupportedKey("This ECDSA") }
        guard cipher == "none" else { throw ClavraError.encryptedECDSA }
        var section = ByteBuffer(bytes: privateBytes)
        guard let check1 = section.readInteger(as: UInt32.self), section.readInteger(as: UInt32.self) == check1,
              section.readSSHText() != nil, let curve = section.readSSHText(), section.readSSHBytes() != nil,
              var scalar = section.readSSHBytes() else { throw ClavraError.unsupportedKey("This ECDSA") }
        // An mpint: drop the sign byte, pad to the curve's size.
        while scalar.first == 0 { scalar.removeFirst() }
        func padded(_ length: Int) -> Data { Data(repeating: 0, count: max(0, length - scalar.count)) + Data(scalar) }
        switch curve {
        case "nistp256": return .p256(username: user, privateKey: try P256.Signing.PrivateKey(rawRepresentation: padded(32)))
        case "nistp384": return .p384(username: user, privateKey: try P384.Signing.PrivateKey(rawRepresentation: padded(48)))
        case "nistp521": return .p521(username: user, privateKey: try P521.Signing.PrivateKey(rawRepresentation: padded(66)))
        default: throw ClavraError.unsupportedKey("ECDSA \(curve)")
        }
    }
}

private extension ByteBuffer {
    mutating func readSSHBytes() -> [UInt8]? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self), readableBytes >= 4 + Int(length) else { return nil }
        moveReaderIndex(forwardBy: 4)
        return readBytes(length: Int(length))
    }

    mutating func readSSHText() -> String? {
        readSSHBytes().map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Asks the session whether to trust the server's key. NIO calls in on its event loop; the answer
/// can take as long as the user needs.
/// The key reaches the session as OpenSSH text (`ssh-ed25519 AAAA…`), which crosses actors safely.
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let decide: @Sendable (String) async -> Bool

    init(_ decide: @escaping @Sendable (String) async -> Bool) {
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        // A revoked key is refused before anyone is asked; there's nothing to decide.
        if KnownHosts.isRevoked(key) {
            validationCompletePromise.fail(ClavraError.revokedHostKey)
            return
        }
        let decide = decide
        Task {
            if await decide(key) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(ClavraError.hostKeyRejected)
            }
        }
    }
}
