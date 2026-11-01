import AppKit
import Citadel
import NIOCore
import NIOSSH
import SwiftTerm

/// One open connection: an SSH client, a shell in a pseudo-terminal, and the terminal view that shows it.
@MainActor @Observable
final class Session: Identifiable {
    enum State: Equatable {
        case connecting
        /// The connection dropped; trying again on its own.
        case reconnecting(attempt: Int)
        case askingHostKey(HostKeyQuestion)
        case connected
        case failed(String)
        case closed
    }

    struct HostKeyQuestion: Equatable {
        /// The host asking: the server itself, or the jump host on the way.
        var host: String
        var isJump: Bool
        var type: String
        var fingerprint: String
        /// The server shows a different key from the one trusted before.
        var changed: Bool
    }

    /// What goes to the server, in order.
    private enum Outgoing: Sendable {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    /// A risky command held back until the user says to run it.
    struct HeldCommand: Equatable {
        var command: String
        var reason: String
        fileprivate var bytes: [UInt8]
    }

    let id = UUID()
    private(set) var server: Server
    /// The saved host to hop through, looked up when the tab opened.
    private(set) var jumpServer: Server?
    private(set) var state: State = .connecting
    private(set) var title: String
    private(set) var held: HeldCommand? {
        didSet { onScreen?() }
    }
    /// The bell rang while this tab wasn't in front.
    var wantsAttention = false
    /// Typed bytes, handed on so they can go to other tabs too (broadcast).
    @ObservationIgnored var mirror: ((ArraySlice<UInt8>) -> Void)?
    /// The screen changed; remote access passes it on to phones.
    @ObservationIgnored var onScreen: (() -> Void)?
    /// Load, memory and disk, read every so often while connected. Nil until the first reading.
    private(set) var stats: ServerStats?
    let forwards = ForwardList()
    @ObservationIgnored let terminal: TerminalView

    @ObservationIgnored private var client: ClientBox?
    @ObservationIgnored private var jumpClient: ClientBox?
    @ObservationIgnored private var sftpClient: SFTPClient?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var typed = TypedLine()
    @ObservationIgnored private var browser: FileBrowser?
    @ObservationIgnored private var ghost: GhostText?
    @ObservationIgnored private var suggestion: String?
    /// Saved hosts keep their history under their id; set by the app when the tab opens.
    @ObservationIgnored var isSavedHost = false
    private var history: CommandHistory { CommandHistory.of(server, saved: isSavedHost) }
    /// Automatic attempts since the connection last dropped.
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var userClosed = false
    /// Bumped by every connect and close. A connection attempt that finishes after its generation
    /// has passed closes what it opened instead of taking over the tab: Citadel's connect doesn't
    /// stop when its task is cancelled.
    @ObservationIgnored private var generation = 0
    /// Tunnels that were open when the connection dropped, opened again once it's back.
    @ObservationIgnored private var carried: [Server.Forward] = []

    /// The tab's file browser, made on first use so it remembers its folder between visits.
    var files: FileBrowser {
        if let browser { return browser }
        let made = FileBrowser(session: self)
        browser = made
        return made
    }
    @ObservationIgnored private var outgoing: AsyncStream<Outgoing>.Continuation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let relay = TerminalRelay()

    init(server: Server, jump: Server? = nil) {
        self.server = server
        jumpServer = jump
        title = server.title
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalStyle.apply(to: terminal)
        relay.session = self
        terminal.terminalDelegate = relay
        ghost = GhostText(in: terminal)
    }

    var isLive: Bool { state == .connected }

    /// Connecting, asking or failed: the terminal steps back behind the card.
    var dimsTerminal: Bool {
        switch state {
        case .connected, .closed, .reconnecting: false
        default: true
        }
    }

    func connect() {
        task?.cancel()
        answer?.resume(returning: false)
        answer = nil
        generation += 1
        teardown(keepFiles: false)
        attempts = 0
        carried = []
        userClosed = false
        state = .connecting
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        let current = generation
        task = Task { await run(current) }
    }

    /// Picks up edits made to the host while this tab was failing, then tries again.
    func retry(with server: Server, jump: Server? = nil) {
        self.server = server
        jumpServer = jump
        title = server.title
        connect()
    }

    func close() {
        userClosed = true
        generation += 1
        answer?.resume(returning: false)
        answer = nil
        task?.cancel()
        teardown(keepFiles: false)
        if state != .closed, !isFailed { state = .closed }
    }

    /// Everything that hangs off the connection goes with it. Files being edited survive a reconnect;
    /// their saves go up once the connection is back.
    private func teardown(keepFiles: Bool) {
        outgoing?.finish()
        outgoing = nil
        statsTask?.cancel()
        statsTask = nil
        forwards.closeAll()
        if let sftp = sftpClient { Task { try? await sftp.close() } }
        sftpClient = nil
        if !keepFiles {
            browser?.stopEditing()
            browser = nil
        }
        hideSuggestion()
        client?.close()
        client = nil
        jumpClient?.close()
        jumpClient = nil
        held = nil
        typed.reset()
    }

    func answerHostKey(_ trust: Bool) {
        answer?.resume(returning: trust)
        answer = nil
        if trust { state = .connecting }
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    // MARK: Connection

    private func run(_ current: Int) async {
        func stale() -> Bool { current != generation || userClosed }
        do {
            nonisolated(unsafe) let method = try Credentials.method(for: server)
            let target = server
            let check = HostKeyCheck { [weak self] key in await self?.decide(key, for: target, isJump: false) ?? false }
            var settings = SSHClientSettings(host: server.address, port: server.port,
                                             authenticationMethod: { method }, hostKeyValidator: .custom(check))
            settings.connectTimeout = .seconds(12)
            let client: ClientBox
            if let jump = jumpServer {
                nonisolated(unsafe) let jumpMethod = try Credentials.method(for: jump)
                let jumpCheck = HostKeyCheck { [weak self] key in await self?.decide(key, for: jump, isJump: true) ?? false }
                var hop = SSHClientSettings(host: jump.address, port: jump.port,
                                            authenticationMethod: { jumpMethod }, hostKeyValidator: .custom(jumpCheck))
                hop.connectTimeout = .seconds(12)
                let jumpClient = ClientBox(try await SSHClient.connect(to: hop))
                if stale() { return jumpClient.close() }
                self.jumpClient = jumpClient
                client = try await Self.hop(through: jumpClient, settings)
            } else {
                client = ClientBox(try await SSHClient.connect(to: settings))
            }
            if stale() {
                client.close()
                if current != generation { return }
                jumpClient?.close()
                return
            }
            self.client = client

            let (input, sink) = AsyncStream.makeStream(of: Outgoing.self)
            outgoing = sink
            let size = terminal.getTerminal()
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "xterm-256color",
                terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
            state = .connected
            let wasReconnect = attempts > 0
            attempts = 0
            if wasReconnect { terminal.feed(text: "\r\n\u{1b}[2m[Clavra: connected again]\u{1b}[0m\r\n") }
            startWatching()
            seedHistory()
            if !server.startup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let startup = server.startup
                Task { try? await Task.sleep(for: .milliseconds(700)); self.type(startup, run: true) }
            }
            let reopen = server.forwards.filter(\.automatic) + carried.filter { c in !server.forwards.contains { $0.id == c.id && $0.automatic } }
            carried = []
            for forward in reopen { forwards.open(forward, through: client) }
            #if DEBUG
            // `-ClavraType 'ls\r|ec'` types into the shell once it's up, a key at a time, pausing at
            // each `|`, to check input end to end.
            if let typed = UserDefaults.standard.string(forKey: "ClavraType") {
                Task {
                    for step in typed.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}").split(separator: "|") {
                        try? await Task.sleep(for: .seconds(1.5))
                        // An escape sequence goes as one key; everything else a byte at a time.
                        var keys: [[UInt8]] = []
                        for byte in step.utf8 {
                            if let last = keys.last, last.first == 0x1B, last.count < 3 { keys[keys.count - 1].append(byte) } else { keys.append([byte]) }
                        }
                        for key in keys { self.typedByUser(key[...]); try? await Task.sleep(for: .milliseconds(30)) }
                    }
                }
            }
            #endif

            try await Self.pump(client, request: request, input: input) { [weak self] bytes in
                await self?.show(bytes)
            }
            guard current == generation else { return }
            end(.closed)
        } catch is CancellationError {
        } catch {
            guard current == generation else { return }
            let wasConnected = state == .connected || { if case .reconnecting = state { true } else { false } }()
            if state == .connected { carried = forwards.items.map(\.forward) }
            teardown(keepFiles: wasConnected && !userClosed)
            // A live session that drops (Wi-Fi change, sleep, a blip) tries again a few times on its
            // own. Failing to connect in the first place doesn't; that's for the user to look at.
            if wasConnected, !userClosed, attempts < 4 {
                attempts += 1
                state = .reconnecting(attempt: attempts)
                terminal.feed(text: "\r\n\u{1b}[2m[Clavra: connection lost, trying again]\u{1b}[0m\r\n")
                let wait = [2, 5, 10, 20][attempts - 1]
                task = Task {
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, !self.userClosed, current == self.generation else { return }
                    await self.run(current)
                }
                return
            }
            end(.failed(Self.describe(error)))
        }
    }

    private func end(_ final: State) {
        teardown(keepFiles: false)
        if case .failed = final { state = final } else if state != .closed { state = final }
    }

    private nonisolated static func hop(through box: ClientBox, _ settings: SSHClientSettings) async throws -> ClientBox {
        ClientBox(try await box.client.jump(to: settings))
    }

    /// Runs the shell: what the terminal types goes out in order, what the server prints comes back.
    /// Off the main actor, since Citadel's PTY types aren't Sendable.
    private nonisolated static func pump(_ box: ClientBox, request: SSHChannelRequestEvent.PseudoTerminalRequest,
                                         input: AsyncStream<Outgoing>,
                                         output: @escaping @Sendable ([UInt8]) async -> Void) async throws {
        try await box.client.withPTY(request) { inbound, outbound in
            nonisolated(unsafe) let outbound = outbound
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await item in input {
                        switch item {
                        case .bytes(let bytes): try await outbound.write(ByteBuffer(bytes: bytes))
                        case .resize(let cols, let rows): try await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                }
                // The shell ending (exit, or the server closing) ends the session.
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer): await output(Array(buffer.readableBytesView))
                    }
                }
                group.cancelAll()
            }
        }
    }

    private func show(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes[...])
        refreshSuggestion()
        onScreen?()
    }

    private func decide(_ text: String, for host: Server, isJump: Bool) async -> Bool {
        let verdict = KnownHosts.check(host: host.address, port: host.port, key: text)
        if verdict == .trusted { return true }
        let type = text.split(separator: " ").first.map(String.init) ?? "key"
        state = .askingHostKey(HostKeyQuestion(host: host.title, isJump: isJump, type: type,
                                               fingerprint: KnownHosts.fingerprint(text), changed: verdict == .changed))
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ClavraAutoTrust") {
            Task { try? await Task.sleep(for: .seconds(2.5)); self.answerHostKey(true) }
        }
        #endif
        // A question still open from an earlier attempt is answered no, never left hanging.
        answer?.resume(returning: false)
        let trust = await withCheckedContinuation { answer = $0 }
        if trust { KnownHosts.trust(host: host.address, port: host.port, key: text) }
        return trust
    }

    // MARK: Terminal

    fileprivate func send(_ data: ArraySlice<UInt8>) {
        guard held == nil else { return }
        let pressesReturn = data.contains(0x0D) || data.contains(0x0A)
        if server.guardsCommands, pressesReturn, let held = riskyCommand(in: data) {
            self.held = held
            return
        }
        if data.count == 1, data.first == 0x0D { remember(PromptLine.command(in: screenLine(), strict: true)) }
        typed.feed(data)
        outgoing?.yield(.bytes(Array(data)))
    }

    // MARK: Suggestions

    /// Production hosts don't add to the history kept on disk; their server-side history still
    /// feeds suggestions for the session.
    private func remember(_ command: String?) {
        guard let command, CommandHistory.isEnabled, server.place != .production else { return }
        history.record(command)
    }

    /// → (or ⌃F) at the end of the line takes the suggestion, the way fish and zsh-autosuggestions do.
    private func acceptsSuggestion(_ data: ArraySlice<UInt8>) -> Bool {
        guard let suggestion, !suggestion.isEmpty else { return false }
        let right: [[UInt8]] = [[0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43], [0x06]]
        guard right.contains(Array(data)) else { return false }
        let bytes = ArraySlice(Array(suggestion.utf8))
        send(bytes)
        // Other panes typing along get the same text, not an arrow key they'd read differently.
        mirror?(bytes)
        hideSuggestion()
        return true
    }

    /// Looks at the line under the cursor once the screen has settled.
    private func refreshSuggestion() {
        guard CommandHistory.isEnabled, isLive, held == nil else { return hideSuggestion() }
        let term = terminal.getTerminal()
        guard !term.isCurrentBufferAlternate else { return hideSuggestion() }
        let cursor = term.getCursorLocation()
        let line = term.getLine(row: cursor.y)?.translateToString(trimRight: true) ?? ""
        guard cursor.x == line.count, let typed = PromptLine.command(in: line, strict: true), !typed.isEmpty,
              let rest = history.suggestion(for: typed) else { return hideSuggestion() }
        suggestion = rest
        ghost?.show(rest, column: cursor.x, row: cursor.y, in: terminal)
    }

    private func hideSuggestion() {
        suggestion = nil
        ghost?.hide()
    }

    /// The server's own shell history makes suggestions useful from the first command.
    private func seedHistory() {
        guard CommandHistory.isEnabled, let client else { return }
        let history = history
        Task {
            let text = try? await Self.exec("tail -n 3000 ~/.zsh_history ~/.bash_history 2>/dev/null | grep -v '^==>' ; true", on: client)
            if let text { history.seed(text) }
        }
    }

    /// Keys from a phone. The same guard applies; a held command waits for a yes on the Mac.
    func receiveRemote(_ text: String) {
        guard isLive else { return }
        hideSuggestion()
        send(ArraySlice(Array(text.utf8)))
    }

    /// Bytes from another tab while broadcasting. They go through this tab's own guard.
    func receiveBroadcast(_ data: ArraySlice<UInt8>) {
        guard isLive else { return }
        send(data)
    }

    fileprivate func typedByUser(_ data: ArraySlice<UInt8>) {
        if acceptsSuggestion(data) { return }
        hideSuggestion()
        send(data)
        mirror?(data)
    }

    fileprivate func rang() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        wantsAttention = true
    }

    // MARK: Terminal tools

    func find(_ text: String, backwards: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        return backwards ? terminal.findPrevious(text) : terminal.findNext(text)
    }

    func clearScrollback() {
        // Clear screen and scrollback, then ask the shell to draw its prompt again.
        terminal.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
        if isLive { send([0x0C][...]) }
    }

    /// Everything in the scrollback as plain text.
    var transcript: String {
        String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// Types text into the shell as if from the keyboard, Return included when `run` is set. Goes
    /// through the same guard as typing.
    func type(_ text: String, run: Bool) {
        var bytes = Array(text.utf8)
        if run { bytes.append(0x0D) }
        send(bytes[...])
        refocus()
    }

    /// The user's answer to a held command.
    func release(run: Bool) {
        guard let held else { return }
        self.held = nil
        if run {
            if held.bytes == [0x0D] { remember(held.command) }
            typed.feed(held.bytes[...])
            outgoing?.yield(.bytes(held.bytes))
        }
        refocus()
    }

    func refocus() {
        DispatchQueue.main.async { [terminal] in terminal.window?.makeFirstResponder(terminal) }
    }

    /// Each line this input would run: the line on screen (it has whatever the shell recalled or
    /// completed), what was typed since the last Return, and any lines in a paste.
    private func riskyCommand(in data: ArraySlice<UInt8>) -> HeldCommand? {
        var pending = typed
        let text = String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
        for (index, part) in parts.dropLast().enumerated() {
            if index == 0 {
                pending.feed(ArraySlice(Array(part.utf8)))
                lines.append(pending.text)
                lines.append(PromptLine.command(in: screenLine()) + part)
            } else {
                lines.append(String(part))
            }
        }
        for line in lines {
            if let risk = CommandGuard.check(line) {
                return HeldCommand(command: line.trimmingCharacters(in: .whitespaces), reason: risk.reason, bytes: Array(data))
            }
        }
        return nil
    }

    private func screenLine() -> String {
        let terminal = terminal.getTerminal()
        let row = terminal.getCursorLocation().y
        return terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
    }


    fileprivate func resized(cols: Int, rows: Int) {
        outgoing?.yield(.resize(cols: cols, rows: rows))
    }

    fileprivate func retitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        title = trimmed.isEmpty ? server.title : trimmed
    }

    // MARK: Side channels

    /// Runs a command next to the shell and returns what it printed. A non-zero exit is an error.
    func exec(_ command: String) async throws -> String {
        guard let client else { throw ClavraError.notConnected }
        return try await Self.exec(command, on: client)
    }

    private nonisolated static func exec(_ command: String, on box: ClientBox) async throws -> String {
        let buffer = try await box.client.executeCommand(command, maxResponseSize: 4 << 20, mergeStreams: false, inShell: false)
        return String(buffer: buffer)
    }

    /// One SFTP channel per tab, opened the first time the file browser asks.
    func sftp() async throws -> SFTPClient {
        if let sftpClient, sftpClient.isActive { return sftpClient }
        guard let client else { throw ClavraError.notConnected }
        let sftp = try await Self.openSFTP(on: client)
        sftpClient = sftp
        return sftp
    }

    private nonisolated static func openSFTP(on box: ClientBox) async throws -> SFTPClient {
        try await box.client.openSFTP()
    }

    func openForward(_ forward: Server.Forward) {
        guard let client else { return }
        forwards.open(forward, through: client)
    }

    /// Reads the server's vitals now and then, plus which ports it listens on (for forwarding).
    private func startWatching() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                if let text = try? await Self.exec(ServerStats.script, on: client) {
                    self.stats = ServerStats(text, sshPort: self.server.port)
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Plain words for the errors people actually hit.
    static func describe(_ error: Error) -> String {
        if let error = error as? ClavraError, let text = error.errorDescription { return text }
        let raw = String(describing: error)
        if raw.contains("allAuthenticationOptionsFailed") || raw.contains("authentication") {
            return "The server didn't accept this key or password."
        }
        if raw.contains("connectTimeout") || raw.contains("timeout") { return "The server didn't answer. Check the address and your network." }
        if raw.contains("connectionRefused") || raw.contains("Connection refused") { return "The server refused the connection. Is SSH running on that port?" }
        if raw.contains("hostKeyRejected") { return ClavraError.hostKeyRejected.errorDescription! }
        if raw.contains("NXDOMAIN") || raw.contains("unknownHost") || raw.contains("resolve") { return "Couldn't find that address." }
        return error.localizedDescription
    }
}

/// The SSH client, handed across actors. Citadel's client is thread-safe (it lives on its NIO event
/// loop) but isn't marked Sendable.
final class ClientBox: @unchecked Sendable {
    let client: SSHClient
    init(_ client: SSHClient) { self.client = client }

    func close() {
        let client = client
        Task { try? await client.close() }
    }
}

/// SwiftTerm calls its delegate on the main thread; this forwards to the session.
@MainActor
private final class TerminalRelay: NSObject, @preconcurrency TerminalViewDelegate {
    weak var session: Session?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.typedByUser(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resized(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session?.retitle(title)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { session?.rang() }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
