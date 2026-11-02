import CryptoKit
import Foundation

/// A private key in ~/.ssh, read just far enough to judge it. The secret part is never decoded.
struct SSHKeyInfo: Identifiable, Hashable, Sendable {
    enum Issue: Hashable, Sendable {
        case noPassphrase
        case openPermissions(String)
        case weak(String)
        case old(years: Int)

        var text: String {
            switch self {
            case .noPassphrase: "No passphrase: anyone who copies the file can use it."
            case .openPermissions(let mode): "Other users on this Mac can read it (\(mode)). It should be 600."
            case .weak(let why): why
            case .old(let years): "Made \(years) years ago. Consider a fresh one."
            }
        }

        /// Serious enough to colour coral.
        var isSerious: Bool {
            switch self {
            case .openPermissions, .weak: true
            default: false
            }
        }
    }

    var id: String { path }
    /// `~/.ssh/id_ed25519`
    var path: String
    var type: String
    var bits: Int?
    var encrypted: Bool
    var fingerprint: String?
    var publicKey: String?
    var comment: String?
    var mode: Int
    var created: Date?

    var kind: String {
        switch type {
        case "ssh-ed25519": "Ed25519"
        case "ssh-rsa": bits.map { "RSA \($0)" } ?? "RSA"
        case let t where t.hasPrefix("ecdsa"): "ECDSA"
        case "ssh-dss": "DSA"
        default: type
        }
    }

    var issues: [Issue] {
        var list: [Issue] = []
        if mode & 0o077 != 0 { list.append(.openPermissions(String(mode & 0o777, radix: 8))) }
        if type == "ssh-dss" { list.append(.weak("DSA keys are turned off in OpenSSH 7 and later.")) }
        if type == "ssh-rsa", let bits, bits < 3072 {
            list.append(.weak("RSA \(bits) is below today's 3072-bit floor. Ed25519 is shorter and stronger."))
        }
        if !encrypted { list.append(.noPassphrase) }
        if let created, let years = Calendar.current.dateComponents([.year], from: created, to: .now).year, years >= 3 {
            list.append(.old(years: years))
        }
        return list
    }
}

enum SSHKeys {
    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory) }

    static func scan() -> [SSHKeyInfo] {
        Credentials.keysInSSHFolder().compactMap(read)
    }

    static func read(_ path: String) -> SSHKeyInfo? {
        let full = Credentials.expand(path)
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: full)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let created = attributes?[.creationDate] as? Date
        let publicText = (try? String(contentsOfFile: full + ".pub", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var info = SSHKeyInfo(path: path, type: "unknown", encrypted: false, mode: mode, created: created)
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            guard let blob = body(of: text) else { return nil }
            var reader = Reader(blob)
            guard reader.skip(Array("openssh-key-v1\0".utf8)),
                  let cipher = reader.string(), reader.string() != nil, reader.bytes() != nil,
                  reader.uint32() != nil, let publicBlob = reader.bytes() else { return nil }
            info.encrypted = cipher != "none"
            describe(publicBlob, into: &info)
        } else {
            // Old PEM files: the header says what's inside and whether it's encrypted.
            info.encrypted = text.contains("ENCRYPTED")
            info.type = text.contains("BEGIN RSA") ? "ssh-rsa" : text.contains("BEGIN DSA") ? "ssh-dss"
                : text.contains("BEGIN EC") ? "ecdsa" : "unknown"
        }
        if let publicText {
            let parts = publicText.split(separator: " ", maxSplits: 2)
            if parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) {
                describe([UInt8](blob), into: &info)
                info.publicKey = publicText
                if parts.count == 3 { info.comment = String(parts[2]) }
            }
        }
        return info
    }

    /// Type, size and fingerprint from the public half.
    private static func describe(_ blob: [UInt8], into info: inout SSHKeyInfo) {
        var reader = Reader(blob)
        guard let type = reader.string() else { return }
        info.type = type
        let digest = Data(SHA256.hash(data: Data(blob))).base64EncodedString().replacingOccurrences(of: "=", with: "")
        info.fingerprint = "SHA256:\(digest)"
        if info.publicKey == nil { info.publicKey = "\(type) \(Data(blob).base64EncodedString())" }
        if type == "ssh-rsa", reader.bytes() != nil, let modulus = reader.bytes() {
            let significant = modulus.drop(while: { $0 == 0 })
            info.bits = significant.count * 8 - (significant.first.map { $0.leadingZeroBitCount } ?? 0)
        }
    }

    private static func body(of pem: String) -> [UInt8]? {
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64).map { [UInt8]($0) }
    }

    /// Sets the key to 600, as ssh insists.
    static func fixPermissions(_ key: SSHKeyInfo) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Credentials.expand(key.path))
    }

    /// A new Ed25519 key made by the Mac's own `ssh-keygen`, so the file is exactly what OpenSSH
    /// writes. The passphrase goes in on standard input, never on the command line.
    static func generate(name: String, comment: String, passphrase: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { throw KeyError.badName }
        let target = folder.appending(path: clean)
        guard !FileManager.default.fileExists(atPath: target.path),
              !FileManager.default.fileExists(atPath: target.path + ".pub") else { throw KeyError.exists(clean) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // The key is made without a passphrase, then re-encrypted with `-p`, which asks for the new
        // one through an askpass helper instead of an argument other processes could see. Both steps
        // happen in a private scratch folder; only a finished key is moved into ~/.ssh, so a failed
        // second step never leaves an unprotected key behind.
        let scratch = folder.appending(path: ".clavra-new-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let draft = scratch.appending(path: clean)
        try await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-a", "100", "-N", "", "-C", comment, "-f", draft.path])
        if !passphrase.isEmpty {
            try await withAskpass(passphrase) { env in
                try await run("/usr/bin/ssh-keygen", ["-q", "-p", "-a", "100", "-P", "", "-f", draft.path], environment: env)
            }
        }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw KeyError.exists(clean) }
        try FileManager.default.moveItem(at: draft, to: target)
        try FileManager.default.moveItem(at: scratch.appending(path: clean + ".pub"), to: folder.appending(path: clean + ".pub"))
        return "~/.ssh/\(clean)"
    }

    enum KeyError: LocalizedError {
        case badName, exists(String), failed(String)

        var errorDescription: String? {
            switch self {
            case .badName: "Give the key a file name."
            case .exists(let name): "~/.ssh/\(name) already exists."
            case .failed(let text): text.isEmpty ? "ssh-keygen didn't finish." : text
            }
        }
    }

    /// ssh-keygen -p asks for the new passphrase twice on its terminal; with no terminal it falls back
    /// to SSH_ASKPASS. The helper prints an environment variable, so the secret never lands on disk.
    private static func withAskpass<T>(_ secret: String, _ body: ([String: String]) async throws -> T) async throws -> T {
        let helper = FileManager.default.temporaryDirectory.appending(path: "clavra-askpass-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' \"$CLAVRA_SECRET\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: helper) }
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["CLAVRA_SECRET"] = secret
        return try await body(env)
    }

    private static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { process in
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 { continuation.resume() } else { continuation.resume(throwing: KeyError.failed(text)) }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Adds the public key to `~/.ssh/authorized_keys` on a connected server, once.
    static func install(_ publicKey: String, on session: Session) async throws {
        let line = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("'"), !line.contains("\n") else { throw KeyError.failed("That public key has characters a shell can't take safely.") }
        let script = """
        umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && \
        { [ ! -s ~/.ssh/authorized_keys ] || [ -z "$(tail -c1 ~/.ssh/authorized_keys)" ] || echo >> ~/.ssh/authorized_keys; } && \
        (grep -qxF '\(line)' ~/.ssh/authorized_keys || printf '%s\\n' '\(line)' >> ~/.ssh/authorized_keys) && \
        chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
        """
        _ = try await session.exec(script)
    }
}

/// Reads the length-prefixed fields of the SSH wire format.
private struct Reader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) { self.data = data }

    mutating func skip(_ prefix: [UInt8]) -> Bool {
        guard data.count >= offset + prefix.count, Array(data[offset..<offset + prefix.count]) == prefix else { return false }
        offset += prefix.count
        return true
    }

    mutating func uint32() -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func bytes() -> [UInt8]? {
        guard let length = uint32().map(Int.init), data.count >= offset + length else { return nil }
        defer { offset += length }
        return Array(data[offset..<offset + length])
    }

    mutating func string() -> String? {
        bytes().map { String(decoding: $0, as: UTF8.self) }
    }
}
