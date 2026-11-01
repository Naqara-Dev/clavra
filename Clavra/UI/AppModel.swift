import AppKit
import SwiftUI

/// Saved hosts, open tabs, and which one is in front. Nil selection shows `page`.
@MainActor @Observable
final class AppModel {
    enum Page: Hashable {
        case home, keys, snippets
    }

    let store = HostStore()
    let snippets = SnippetStore()
    let health = HealthMonitor()
    private(set) var sessions: [Session] = []
    var selection: Session.ID?
    var page: Page = .home
    /// The host being edited in the sheet; a fresh one when adding.
    var editing: Server?
    /// Bumped to put the cursor in the "Where to?" field.
    var focusQuick = 0
    /// The snippet palette over the front terminal.
    var showingSnippets = false
    /// What sits beside the front terminal.
    var sidePanel: SidePanel?

    enum SidePanel: Hashable {
        case files, ports
    }

    init() {
        health.watch { [weak self] in self?.store.hosts ?? [] }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var current: Session? { sessions.first { $0.id == selection } }

    func open(_ server: Server, through jump: Server? = nil) {
        let session = Session(server: server, jump: jump ?? jumpHost(for: server))
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

    /// ⇧⌘] and ⇧⌘[ through the open tabs.
    func cycle(_ step: Int) {
        guard !sessions.isEmpty else { return }
        let index = sessions.firstIndex { $0.id == selection } ?? -1
        selection = sessions[(index + step + sessions.count) % sessions.count].id
    }

    func goHome() {
        selection = nil
        page = .home
        focusQuick += 1
    }

    func show(_ page: Page) {
        selection = nil
        self.page = page
    }

    func newHost() {
        editing = Server(name: "", address: "", user: NSUserName())
    }

    func save(_ server: Server) {
        store.save(server)
        for session in sessions where session.server.id == server.id {
            if case .failed = session.state { session.retry(with: server, jump: jumpHost(for: server)) }
        }
    }

    func isSaved(_ server: Server) -> Bool { store.host(server.id) != nil }

    /// The saved host to go through. A host can't jump through itself.
    func jumpHost(for server: Server) -> Server? {
        guard let id = server.jump, id != server.id else { return nil }
        return store.host(id)
    }

    /// Hosts and snippets move between this Mac and iCloud Drive. Whatever is already in the new
    /// place stays; anything only the old place had is added.
    func setICloudSync(_ on: Bool) {
        guard on != Library.syncsWithICloud else { return }
        let hosts = store.hosts
        let saved = snippets.snippets
        Library.syncsWithICloud = on
        store.reload()
        store.merge(hosts)
        snippets.reload()
        snippets.merge(saved)
    }

    /// Back in front: pick up hosts another Mac may have changed, and check who's up.
    func refresh() {
        guard Library.syncsWithICloud else { return }
        store.reload()
        snippets.reload()
    }
}
