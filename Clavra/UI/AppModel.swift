import AppKit
import SwiftUI

/// Saved hosts, open tabs and their panes, and which one is in front. Nil selection shows `page`.
@MainActor @Observable
final class AppModel {
    enum Page: Hashable {
        case home, keys, snippets
    }

    let store = HostStore()
    let snippets = SnippetStore()
    let health = HealthMonitor()
    /// Every open terminal, in every tab and pane.
    private(set) var sessions: [Session] = []
    private(set) var tabs: [TabGroup] = [] {
        didSet { rememberTabs() }
    }
    var selection: TabGroup.ID? {
        didSet { current?.wantsAttention = false }
    }
    /// Whatever is typed in the front tab goes to every connected tab.
    var broadcasting = false
    var showingFind = false
    /// What the find bar last looked for, for ⌘G.
    var lastFind = ""
    var fontSize = TerminalStyle.fontSize
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
        // A click in a pane gives it the keyboard; the terminal view takes the click itself, so it's
        // noticed on the way in.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.paneClicked(event) }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var currentTab: TabGroup? { tabs.first { $0.id == selection } }

    /// The pane with the keyboard in the front tab.
    var current: Session? { currentTab.flatMap { tab in session(tab.focused) } }

    func session(_ id: Session.ID) -> Session? { sessions.first { $0.id == id } }

    func tab(containing id: Session.ID) -> TabGroup? { tabs.first { $0.paneIDs.contains(id) } }

    /// A new tab with one terminal.
    func open(_ server: Server, through jump: Server? = nil) {
        let session = start(server, through: jump ?? jumpHost(for: server))
        let tab = TabGroup(session.id)
        tabs.append(tab)
        selection = tab.id
    }

    /// ⌘D beside, ⇧⌘D below: another terminal on the same host, in the same tab.
    func split(_ axis: PaneNode.Axis) {
        guard let tab = currentTab, let from = current else { return }
        let session = start(from.server, through: from.jumpServer)
        tab.root = tab.root.splitting(from.id, with: session.id, along: axis)
        tab.focused = session.id
        rememberTabs()
    }

    /// ⌥⌘ arrows: the next or previous pane.
    func focusPane(_ step: Int) {
        guard let tab = currentTab, let next = tab.neighbor(step), let session = session(next) else { return }
        tab.focused = next
        session.refocus()
    }

    private func paneClicked(_ event: NSEvent) {
        guard let tab = currentTab, tab.isSplit else { return }
        for id in tab.paneIDs {
            guard let session = session(id), session.terminal.window === event.window else { continue }
            let point = session.terminal.convert(event.locationInWindow, from: nil)
            if session.terminal.bounds.contains(point) {
                if tab.focused != id { tab.focused = id }
                return
            }
        }
    }

    func focus(_ session: Session) {
        guard let tab = tab(containing: session.id) else { return }
        tab.focused = session.id
        session.wantsAttention = false
        if selection != tab.id { selection = tab.id }
    }

    private func start(_ server: Server, through jump: Server?) -> Session {
        let session = Session(server: server, jump: jump)
        session.isSavedHost = isSaved(server)
        session.mirror = { [weak self, weak session] bytes in
            guard let self, self.broadcasting, let session, session.id == self.current?.id else { return }
            for other in self.sessions where other.id != session.id { other.receiveBroadcast(bytes) }
        }
        sessions.append(session)
        if isSaved(server) { store.touch(server.id) }
        session.connect()
        return session
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

    /// Closes one pane. The last pane of a tab takes the tab with it.
    func close(_ id: Session.ID) {
        guard let tab = tab(containing: id) else { return }
        session(id)?.close()
        sessions.removeAll { $0.id == id }
        if let rest = tab.root.removing(id) {
            let order = tab.paneIDs
            tab.root = rest
            if tab.focused == id {
                let index = order.firstIndex(of: id) ?? 0
                let left = rest.ids
                tab.focused = left[min(max(index - 1, 0), left.count - 1)]
                session(tab.focused)?.refocus()
            }
            rememberTabs()
        } else {
            removeTab(tab)
        }
    }

    func closeTab(_ id: TabGroup.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        for pane in tab.paneIDs {
            session(pane)?.close()
            sessions.removeAll { $0.id == pane }
        }
        removeTab(tab)
    }

    /// ⌘W: the focused pane, or the window when there are no tabs.
    func closeFront() {
        if let current { close(current.id) } else { NSApp.keyWindow?.performClose(nil) }
    }

    private func removeTab(_ tab: TabGroup) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selection == tab.id {
            selection = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// `ssh://user@host:port` from a link or another app. A saved host with that address is used.
    func openURL(_ url: URL) {
        guard url.scheme == "ssh", let host = url.host() else { return }
        let port = url.port ?? 22
        let user = url.user() ?? NSUserName()
        if let saved = store.hosts.first(where: { $0.address == host && $0.port == port && $0.user == user }) {
            return open(saved)
        }
        open(Server(name: host, address: host, port: port, user: user))
    }

    /// The front tab's scrollback, as a text file.
    func saveOutput() {
        guard let session = current else { return }
        let panel = NSSavePanel()
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "\(session.server.title) \(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.transcript.write(to: url, atomically: true, encoding: .utf8)
    }

    func closeOthers(than id: TabGroup.ID) {
        for tab in tabs where tab.id != id { closeTab(tab.id) }
    }

    /// ⌘+ and ⌘-, for every tab at once.
    func setFontSize(_ size: CGFloat) {
        TerminalStyle.fontSize = size
        fontSize = TerminalStyle.fontSize
        for session in sessions { TerminalStyle.setFont(on: session.terminal) }
    }

    // MARK: Tabs across launches

    static var restoresTabs: Bool {
        get { UserDefaults.standard.object(forKey: "RestoreTabs") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "RestoreTabs") }
    }

    /// Saved hosts that have a tab, so the next launch can open them again.
    private func rememberTabs() {
        let ids = tabs.compactMap { session($0.focused)?.server.id }.filter { store.host($0) != nil }.map(\.uuidString)
        UserDefaults.standard.set(ids, forKey: "OpenTabs")
    }

    func restoreTabs() {
        guard Self.restoresTabs, tabs.isEmpty else { return }
        let ids = (UserDefaults.standard.stringArray(forKey: "OpenTabs") ?? []).compactMap(UUID.init(uuidString:))
        for id in ids { if let server = store.host(id) { open(server) } }
    }

    // MARK: Backup

    struct Backup: Codable {
        var hosts: [Server]
        var snippets: [Snippet]
    }

    /// Hosts and snippets as one JSON file. No passwords, passphrases or keys go in it.
    func exportBackup(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Backup(hosts: store.hosts, snippets: snippets.snippets)).write(to: url, options: .atomic)
    }

    /// Adds what the file has that isn't here yet. Returns how many hosts and snippets were new.
    func importBackup(from url: URL) throws -> (hosts: Int, snippets: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: Data(contentsOf: url))
        let hosts = backup.hosts.filter { h in store.host(h.id) == nil }.count
        let snips = backup.snippets.filter { s in !snippets.snippets.contains { $0.id == s.id } }.count
        store.merge(backup.hosts)
        snippets.merge(backup.snippets)
        return (hosts, snips)
    }

    /// ⇧⌘] and ⇧⌘[ through the open tabs.
    func cycle(_ step: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selection } ?? -1
        selection = tabs[(index + step + tabs.count) % tabs.count].id
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

    /// The same connection as a plain `ssh` line, for a terminal elsewhere.
    func sshCommand(for server: Server) -> String {
        var parts = ["ssh"]
        if server.port != 22 { parts += ["-p", String(server.port)] }
        if server.auth == .key, let key = server.keyPath { parts += ["-i", key] }
        if let jump = jumpHost(for: server) { parts += ["-J", jump.port == 22 ? "\(jump.user)@\(jump.address)" : "\(jump.user)@\(jump.address):\(jump.port)"] }
        for forward in server.forwards {
            switch forward.kind {
            case .local: parts += ["-L", "\(forward.localPort):\(forward.host):\(forward.port)"]
            case .remote: parts += ["-R", "\(forward.port):\(forward.host):\(forward.localPort)"]
            case .socks: parts += ["-D", String(forward.localPort)]
            }
        }
        parts.append("\(server.user)@\(server.address)")
        return parts.joined(separator: " ")
    }

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
