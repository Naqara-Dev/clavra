import SwiftUI

/// Saved hosts, open tabs, and which one is in front. Nil selection is the "Where to?" page.
@MainActor @Observable
final class AppModel {
    let store = HostStore()
    private(set) var sessions: [Session] = []
    var selection: Session.ID?
    /// The host being edited in the sheet; a fresh one when adding.
    var editing: Server?
    /// Bumped to put the cursor in the "Where to?" field.
    var focusQuick = 0

    var current: Session? { sessions.first { $0.id == selection } }

    func open(_ server: Server) {
        let session = Session(server: server)
        sessions.append(session)
        selection = session.id
        store.touch(server.id)
        session.connect()
    }

    /// A saved host whose name or address matches, or a new one read from `user@host:port`.
    func quickConnect(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return }
        if let saved = store.hosts.first(where: { $0.title.lowercased() == q || $0.address.lowercased() == q }) {
            return open(saved)
        }
        guard let server = Server(quick: text) else { return }
        open(server)
    }

    func close(_ id: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].close()
        sessions.remove(at: index)
        if selection == id {
            selection = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }

    func goHome() {
        selection = nil
        focusQuick += 1
    }

    func newHost() {
        editing = Server(name: "", address: "", user: NSUserName())
    }

    func save(_ server: Server) {
        store.save(server)
        for session in sessions where session.server.id == server.id {
            if case .failed = session.state { session.retry(with: server) }
        }
    }

    func isSaved(_ server: Server) -> Bool { store.host(server.id) != nil }
}
