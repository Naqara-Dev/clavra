import CCryptoBoringSSL
import Citadel
import Crypto
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// RSA keys signing with SHA-512 (`rsa-sha2-512`, RFC 8332). Citadel only signs RSA with SHA-1
/// (`ssh-rsa`), which OpenSSH 8.8 and later turn down by default, so an RSA key that works with
/// `ssh` was refused in Clavra. The key is still read (and decrypted) by Citadel; only the signing
/// is done here.
enum RSASHA2 {
    /// Ways in for an RSA key: SHA-512 first, then the old SHA-1 for servers too old to know SHA-2.
    static func signIns(label: String, user: String, key: Insecure.RSA.PrivateKey) -> [Credentials.SignIn] {
        var found: [Credentials.SignIn] = []
        if let sha512 = SHA512Key(key) {
            found.append(Credentials.SignIn(label: label) { .custom(SingleOffer(user: user, key: NIOSSHPrivateKey(custom: sha512))) })
        }
        found.append(Credentials.SignIn(label: label) { .rsa(username: user, privateKey: key) })
        return found
    }

    /// Offers one key once.
    final class SingleOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
        private let user: String
        private let key: NIOSSHPrivateKey
        private let lock = NSLock()
        private var offered = false

        init(user: String, key: NIOSSHPrivateKey) {
            self.user = user
            self.key = key
        }

        func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
            let first = lock.withLock { () -> Bool in
                defer { offered = true }
                return !offered
            }
            guard first, availableMethods.contains(.publicKey) else {
                nextChallengePromise.succeed(nil)
                return
            }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
        }
    }

    /// The private half: n, e and d as BoringSSL numbers, owned here.
    final class SHA512Key: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
        static let keyPrefix = "rsa-sha2-512"
        let publicKey: NIOSSHPublicKeyProtocol
        private let n: UnsafeMutablePointer<BIGNUM>
        private let e: UnsafeMutablePointer<BIGNUM>
        private let d: UnsafeMutablePointer<BIGNUM>

        /// Nil when the key's private exponent can't be read, and the old SHA-1 offer is all there is.
        init?(_ key: Insecure.RSA.PrivateKey) {
            // e and n, as the key writes them for SSH: two mpints.
            var buffer = ByteBufferAllocator().buffer(capacity: 1024)
            _ = key.publicKey.write(to: &buffer)
            guard let eBytes = Self.readMPInt(&buffer), let nBytes = Self.readMPInt(&buffer),
                  let exponent = Mirror(reflecting: key).children.first(where: { $0.label == "privateExponent" })?.value
                    as? UnsafeMutablePointer<BIGNUM>,
                  let d = CCryptoBoringSSL_BN_dup(exponent) else { return nil }
            guard let n = CCryptoBoringSSL_BN_bin2bn(nBytes, nBytes.count, nil),
                  let e = CCryptoBoringSSL_BN_bin2bn(eBytes, eBytes.count, nil) else {
                CCryptoBoringSSL_BN_free(d)
                return nil
            }
            self.n = n
            self.e = e
            self.d = d
            publicKey = SHA512PublicKey(e: eBytes, n: nBytes)
        }

        deinit {
            CCryptoBoringSSL_BN_free(n)
            CCryptoBoringSSL_BN_free(e)
            CCryptoBoringSSL_BN_clear_free(d)
        }

        func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            guard let rsa = CCryptoBoringSSL_RSA_new() else { throw ClavraError.message("Couldn't sign with the RSA key.") }
            defer { CCryptoBoringSSL_RSA_free(rsa) }
            // RSA_set0_key takes ownership, so it gets copies.
            guard let n = CCryptoBoringSSL_BN_dup(n), let e = CCryptoBoringSSL_BN_dup(e), let d = CCryptoBoringSSL_BN_dup(d),
                  CCryptoBoringSSL_RSA_set0_key(rsa, n, e, d) == 1 else {
                throw ClavraError.message("Couldn't sign with the RSA key.")
            }
            let digest = Array(SHA512.hash(data: Array(data)))
            var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_RSA_size(rsa)))
            var length: UInt32 = 0
            guard CCryptoBoringSSL_RSA_sign(NID_sha512, digest, digest.count, &out, &length, rsa) == 1 else {
                throw ClavraError.message("Couldn't sign with the RSA key.")
            }
            return SHA512Signature(rawRepresentation: Data(out.prefix(Int(length))))
        }

        private static func readMPInt(_ buffer: inout ByteBuffer) -> [UInt8]? {
            guard let length = buffer.readInteger(as: UInt32.self), let bytes = buffer.readBytes(length: Int(length)) else { return nil }
            return Array(bytes.drop { $0 == 0 })
        }
    }

    /// The public half. Its algorithm is `rsa-sha2-512`, but RFC 8332 keeps the key's own type in
    /// its blob as `ssh-rsa`; NIOSSH writes the algorithm name there, so it's put right here.
    struct SHA512PublicKey: NIOSSHPublicKeyProtocol {
        static let publicKeyPrefix = "rsa-sha2-512"
        let e: [UInt8]
        let n: [UInt8]

        var rawRepresentation: Data {
            var buffer = ByteBufferAllocator().buffer(capacity: 1024)
            _ = Self.writeBody(e: e, n: n, to: &buffer)
            return Data(buffer.readableBytesView)
        }

        func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            // Only ever used to sign in; the server checks the signature, not this side.
            false
        }

        func write(to buffer: inout ByteBuffer) -> Int {
            let name = Array(Self.publicKeyPrefix.utf8)
            let header = 4 + name.count
            let start = buffer.writerIndex - header
            // Only when what's just before is exactly the algorithm name NIOSSH wrote as the type.
            if start >= buffer.readerIndex, buffer.getInteger(at: start, as: UInt32.self) == UInt32(name.count),
               buffer.getBytes(at: start + 4, length: name.count) == name {
                buffer.moveWriterIndex(to: start)
                var written = Self.writeString(Array("ssh-rsa".utf8), to: &buffer)
                written += Self.writeBody(e: e, n: n, to: &buffer)
                return written - header
            }
            return Self.writeBody(e: e, n: n, to: &buffer)
        }

        static func read(from buffer: inout ByteBuffer) throws -> SHA512PublicKey {
            throw ClavraError.message("rsa-sha2-512 keys are only written, never read.")
        }

        private static func writeBody(e: [UInt8], n: [UInt8], to buffer: inout ByteBuffer) -> Int {
            writeMPInt(e, to: &buffer) + writeMPInt(n, to: &buffer)
        }

        /// A positive mpint: big-endian, with a leading zero when the top bit is set.
        private static func writeMPInt(_ bytes: [UInt8], to buffer: inout ByteBuffer) -> Int {
            let body = (bytes.first ?? 0) & 0x80 != 0 ? [0] + bytes : bytes
            return writeString(body, to: &buffer)
        }

        private static func writeString(_ bytes: [UInt8], to buffer: inout ByteBuffer) -> Int {
            buffer.writeInteger(UInt32(bytes.count)) + buffer.writeBytes(bytes)
        }
    }

    struct SHA512Signature: NIOSSHSignatureProtocol {
        static let signaturePrefix = "rsa-sha2-512"
        let rawRepresentation: Data

        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
        }

        static func read(from buffer: inout ByteBuffer) throws -> SHA512Signature {
            guard let length = buffer.readInteger(as: UInt32.self), let bytes = buffer.readBytes(length: Int(length)) else {
                throw ClavraError.message("A malformed rsa-sha2-512 signature.")
            }
            return SHA512Signature(rawRepresentation: Data(bytes))
        }
    }
}
