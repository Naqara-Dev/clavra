import Foundation

/// A way of signing in that many hosts share: a user, and a key or a password. "deploy with
/// ~/.ssh/work", "root with the team password". Its password or passphrase sits in the Keychain
/// under the identity's own id, so changing it once changes it for every host that uses it.
struct Identity: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var user: String
    var auth: Server.Auth = .key
    var keyPath: String?

    var title: String { name.isEmpty ? user : name }

    /// `deploy · ~/.ssh/work` or `root · password`.
    var summary: String {
        auth == .password ? "\(user) · password" : "\(user) · \(keyPath ?? "default key")"
    }
}

@MainActor @Observable
final class IdentityStore {
    private(set) var identities: [Identity] = []
    private var file: URL { Library.dataFolder.appending(path: "identities.json") }

    init() {
        reload()
    }

    func reload() {
        if let saved = Library.load([Identity].self, from: file), saved != identities { identities = saved }
    }

    func identity(_ id: Identity.ID?) -> Identity? {
        guard let id else { return nil }
        return identities.first { $0.id == id }
    }

    func save(_ identity: Identity) {
        if let index = identities.firstIndex(where: { $0.id == identity.id }) { identities[index] = identity } else { identities.append(identity) }
        Library.save(identities, to: file)
    }

    func delete(_ identity: Identity) {
        identities.removeAll { $0.id == identity.id }
        Keychain.forget(identity.id)
        Library.save(identities, to: file)
    }
}
