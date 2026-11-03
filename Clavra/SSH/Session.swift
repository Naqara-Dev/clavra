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

    /// An archive made on the server before a command ran, to put things back.
    struct Backup: Identifiable, Equatable {
        let id = UUID()
        var file: String
        var bytes: Int
        var command: String
        var made: Date
    }

    /// What a held command would touch on the server, looked at before anyone says yes.
    enum Impact: Equatable {
        case checking
        case found([String])
        case unknown(String)

        var lines: [String] {
            switch self {
            case .checking: ["Looking at what it would touch…"]
            case .found(let lines): lines
            case .unknown(let text): [text]
            }
        }
    }

    /// A risky command held back until the user says to run it.
    struct HeldCommand: Equatable {
        var command: String
        var reason: String
        fileprivate var bytes: [UInt8]
        /// Read off a prompt line that's exactly what will run, so a look-alike can be trusted.
        fileprivate var previewable = true
    }

    let id = UUID()
    private(set) var server: Server
    /// The saved host to hop through, looked up when the tab opened.
    private(set) var jumpServer: Server?
    private(set) var state: State = .connecting
    private(set) var title: String
    private(set) var held: HeldCommand? {
        didSet {
            if held == nil {
                impactTask?.cancel()
                impact = nil
                backupPlan = nil
            }
            onScreen?()
        }
    }
    /// What the held command would touch, once looked at.
    private(set) var impact: Impact? {
        didSet { onScreen?() }
    }
    /// How to back up what the held command touches, when that's possible and worth it.
    private(set) var backupPlan: String?
    /// The held command a backup is being made for right now.
    private(set) var backingUpFor: String?
    /// Archives made in this tab, newest first. The files stay on the server in ~/.clavra-backups.
    private(set) var backups: [Backup] = []
    /// A line that says what just happened (a backup, a restore), shown for a few seconds.
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// sudo is asking for a password on the line under the cursor. `retry`: the one Clavra just
    /// filled in was turned down.
    struct SudoPrompt: Equatable {
        var retry: Bool
        var hasSaved: Bool
        var hasSignIn: Bool
    }
    private(set) var sudoPrompt: SudoPrompt?
    /// The command line Return last sent, to tell sudo's `Password:` from anyone else's.
    @ObservationIgnored private var lastCommand: String?
    /// Typing at the prompt means the user is answering it themselves; leave it until Return.
    @ObservationIgnored private var sudoDismissed = false
    @ObservationIgnored private var filledSudo = false
    /// A password typed into Clavra's field to keep: saved only once sudo has taken it.
    @ObservationIgnored private var pendingSudo: (password: String, at: Date)?
    /// Which of this host's tabs this is (1, 2, …), so a kept-alive tab finds its tmux session again,
    /// even after Clavra was quit. Set by the app when the tab opens.
    @ObservationIgnored var slot = 1
    /// Kept alive in tmux on the server: nil until known, then whether it worked.
    private(set) var keptAlive: Bool?
    @ObservationIgnored private var ranStartup = false
    /// A command that's been running since Return, for "it's done" when the prompt comes back.
    @ObservationIgnored private var running: (command: String, since: Date)?
    /// Called when a command that took a while finishes; the app decides whether to tell anyone.
    @ObservationIgnored var onFinished: ((String, TimeInterval) -> Void)?
    /// The folder the shell last said it's in (OSC 7), for previews of relative paths.
    @ObservationIgnored var reportedFolder: String?
    /// Who Clavra signed in as and on which machine (`id -un`, `hostname`), to tell whether the
    /// shell in the tab is still that one or has gone on (`ssh db2`, `sudo -i`, `docker exec`).
    @ObservationIgnored private var signedInAs: (user: String, host: String)?
    @ObservationIgnored private var impactTask: Task<Void, Never>?
    /// Writes this tab down when recording is on for its host. One file per connect.
    @ObservationIgnored private var recorder: SessionRecorder? {
        didSet { isRecording = recorder != nil }
    }
    /// This tab is being written down.
    private(set) var isRecording = false
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
    #if DEBUG
    /// Sessions in the order they were made, for `-ClavraTypes`.
    private static var debugSessions = 0
    @ObservationIgnored private let debugIndex: Int = {
        Session.debugSessions += 1
        return Session.debugSessions
    }()
    #endif
    /// Tunnels that were open when the connection dropped, opened again once it's back.
    @ObservationIgnored private var carried: [Server.Forward] = []

    /// The log followed beside this tab, made on first use.
    @ObservationIgnored private var lens: LogLens?
    var logs: LogLens {
        if let lens { return lens }
        let made = LogLens(session: self)
        lens = made
        return made
    }

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
        stopRecording()
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
        stopRecording()
        endTmux()
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
        lens?.stop()
        reportedFolder = nil
        sudoPrompt = nil
        sudoDismissed = false
        pendingSudo = nil
        lastCommand = nil
        running = nil
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
                terminalCharacterWidth: max(size.cols, 1), terminalRowHeight: max(size.rows, 1),
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
            state = .connected
            if recorder == nil, Recordings.records(server) {
                recorder = SessionRecorder(server: server, cols: size.cols, rows: size.rows)
            }
            let wasReconnect = attempts > 0
            attempts = 0
            if wasReconnect { terminal.feed(text: "\r\n\u{1b}[2m[Clavra: connected again]\u{1b}[0m\r\n") }
            startWatching()
            seedHistory()
            let startup = server.startup.trimmingCharacters(in: .whitespacesAndNewlines)
            if server.keepsAlive {
                // Into tmux first; the startup command runs once, in a session that's new.
                Task { await self.enterTmux(then: startup) }
            } else if !startup.isEmpty {
                Task { try? await Task.sleep(for: .milliseconds(700)); self.type(startup, run: true) }
            }
            let reopen = server.forwards.filter(\.automatic) + carried.filter { c in !server.forwards.contains { $0.id == c.id && $0.automatic } }
            carried = []
            for forward in reopen { forwards.open(forward, through: client) }
            #if DEBUG
            // `-ClavraType 'ls\r|ec'` types into the shell once it's up, a key at a time, pausing at
            // each `|`, to check input end to end.
            // `-ClavraTypeNext` types something else in every session after the first (split panes).
            // `-ClavraTypes '("", "ls\\r")'` gives each session its own, in the order they connect.
            let typing: String?
            if let list = UserDefaults.standard.stringArray(forKey: "ClavraTypes") {
                typing = debugIndex <= list.count ? list[debugIndex - 1] : nil
            } else {
                typing = debugIndex > 1 ? UserDefaults.standard.string(forKey: "ClavraTypeNext") ?? UserDefaults.standard.string(forKey: "ClavraType")
                    : UserDefaults.standard.string(forKey: "ClavraType")
            }
            if let typed = typing {
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
        stopRecording()
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
        recorder?.output(bytes)
        refreshSuggestion()
        checkSudo()
        checkFinished()
        onScreen?()
    }

    private func stopRecording() {
        recorder?.close()
        recorder = nil
    }


    // MARK: Backups

    /// Archives what the held command touches, then runs it. If the backup can't be made, nothing
    /// runs and the prompt says why.
    func backUpThenRun() async {
        guard let held, let plan = backupPlan, let client, backingUpFor == nil, !needsPhoneApproval else { return }
        backingUpFor = held.command
        let output = try? await Self.exec(plan, on: client)
        backingUpFor = nil
        let result = BlastRadius.readBackup(output ?? "")
        guard self.held == held else {
            // Answered "Don't Run" meanwhile: the archive isn't needed.
            if case .made(let file, _) = result { Task { _ = try? await Self.exec(BlastRadius.forget(file), on: client) } }
            return
        }
        switch result {
        case .made(let file, let bytes):
            backups.insert(Backup(file: file, bytes: bytes, command: held.command, made: .now), at: 0)
            say("Backed up first (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))). Restore it from Backups below.")
            release(run: true)
        case .skipped(let why):
            backupPlan = nil
            impact = .unknown(why + " Nothing has run.")
        }
    }

    /// Puts the backup's files back where they were, over whatever is there now.
    func restore(_ backup: Backup) async {
        guard let client else { return say("Connect first to restore.") }
        say("Restoring…", for: 60)
        let output = (try? await Self.exec(BlastRadius.restore(backup.file), on: client)) ?? ""
        if output.contains("missing=1") {
            backups.removeAll { $0.id == backup.id }
            say("That backup is gone from the server.")
        } else if output.contains("restored=0") {
            say("Restored what ‘\(backup.command)’ touched.")
        } else {
            let detail = output.split(separator: "\n").first { $0.hasPrefix("error=") }.map { String($0.dropFirst(6)) } ?? "tar didn't finish"
            say("Couldn't restore everything: \(detail)")
        }
    }

    func forget(_ backup: Backup) {
        backups.removeAll { $0.id == backup.id }
        guard let client else { return }
        let command = BlastRadius.forget(backup.file)
        Task { _ = try? await Self.exec(command, on: client) }
    }

    private func say(_ text: String, for seconds: Double = 6) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Kept alive

    /// The tmux session this tab lives in: one per host and tab slot.
    var tmuxName: String { "clavra-\(server.id.uuidString.prefix(8).lowercased())-\(Self.macID)-\(slot)" }

    /// This Mac, in tmux names: two Macs sharing hosts through iCloud never close each other's sessions.
    static let macID: String = {
        if let id = UserDefaults.standard.string(forKey: "ClavraMacID") { return id }
        let id = String(UUID().uuidString.prefix(4).lowercased())
        UserDefaults.standard.set(id, forKey: "ClavraMacID")
        return id
    }()

    /// Replaces the login shell with tmux, joining this tab's session if it's still there. Without
    /// tmux on the server the tab carries on as a plain shell, and says so.
    private func enterTmux(then startup: String) async {
        guard let client else { return }
        let name = tmuxName
        let check = "command -v tmux >/dev/null 2>&1 && { tmux has-session -t '=\(name)' 2>/dev/null && echo existing || echo new; } || echo missing"
        let answer = (try? await Self.exec("sh -c " + BlastRadius.quote(check), on: client))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLive else { return }
        guard answer == "existing" || answer == "new" else {
            keptAlive = false
            if !ranStartup, !startup.isEmpty { ranStartup = true; type(startup, run: true) }
            return
        }
        keptAlive = true
        // A leading space keeps it out of the shell's history; the status bar would only repeat
        // what Clavra's tab already shows.
        let line = " exec tmux new-session -A -s \(name) \\; set-option status off\r"
        outgoing?.yield(.bytes(Array(line.utf8)))
        if answer == "new", !ranStartup, !startup.isEmpty {
            ranStartup = true
            try? await Task.sleep(for: .milliseconds(900))
            type(startup, run: true)
        } else {
            ranStartup = true
        }
    }

    /// Closing the tab means it's done: its tmux session goes too. (Quitting Clavra leaves it.)
    private func endTmux() {
        guard keptAlive == true, let client else { return }
        let name = tmuxName
        // Taken from the session so the teardown that follows doesn't hang up first.
        self.client = nil
        let hop = jumpClient
        jumpClient = nil
        Task {
            _ = try? await Self.exec("tmux kill-session -t '=\(name)' 2>/dev/null; true", on: client)
            client.close()
            hop?.close()
        }
        // A dead link never answers; hang up anyway.
        Task {
            try? await Task.sleep(for: .seconds(8))
            client.close()
            hop?.close()
        }
    }

    // MARK: Finished commands

    /// Full-screen programs aren't "a command finishing" when they're quit.
    private static let interactive: Set<String> = ["vim", "vi", "nvim", "nano", "less", "more", "man", "top", "htop", "btop",
                                                   "ssh", "tmux", "screen", "mysql", "psql", "redis-cli", "python", "python3",
                                                   "node", "irb", "watch", "tail", "journalctl", "mc", "emacs", "su", "bash", "zsh", "sh"]

    /// The prompt is back after a command: if it ran long, say so.
    private func checkFinished() {
        guard let (command, since) = running else { return }
        let term = terminal.getTerminal()
        // tmux draws on the alternate screen; there, the prompt line is what counts.
        guard keptAlive == true || !term.isCurrentBufferAlternate, term.getCursorLocation().x > 0,
              PromptLine.command(in: logicalLine(), strict: true)?.trimmingCharacters(in: .whitespaces) == "" else { return }
        running = nil
        let took = Date.now.timeIntervalSince(since)
        let program = (command.split(separator: " ").first { $0 != "sudo" } ?? "").split(separator: "/").last.map(String.init) ?? ""
        guard took >= 20, !Self.interactive.contains(program) else { return }
        onFinished?(command, took)
    }

    // MARK: sudo

    private func checkSudo() {
        if let pending = pendingSudo {
            // Turned down: sudo says so, or asks again, or gives up. Taken: the shell's prompt comes
            // back with none of that, or 10 seconds pass with the command running.
            let term = terminal.getTerminal()
            let row = term.getCursorLocation().y
            let recent = (max(row - 3, 0)...row).map { term.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }.joined(separator: "\n")
            if SudoFill.isPrompt(screenLine(), after: "sudo") || recent.contains("try again") || recent.contains("incorrect password")
                || recent.contains("Authentication failure") {
                pendingSudo = nil
            } else if PromptLine.command(in: logicalLine(), strict: true) != nil || Date.now.timeIntervalSince(pending.at) > 10 {
                Keychain.setSudoPassword(pending.password, for: server.id)
                pendingSudo = nil
            }
        }
        let asking = isSavedHost && !sudoDismissed && held == nil && SudoFill.isPrompt(screenLine(), after: lastCommand)
        if asking, sudoPrompt == nil {
            let term = terminal.getTerminal()
            let row = term.getCursorLocation().y
            let above = row > 0 ? term.getLine(row: row - 1)?.translateToString(trimRight: true) ?? "" : ""
            sudoPrompt = SudoPrompt(retry: filledSudo && above.contains("try again"),
                                    hasSaved: Keychain.hasSudoPassword(for: server.id),
                                    hasSignIn: server.auth == .password && Keychain.password(for: server.secretsID) != nil)
            filledSudo = false
        } else if !asking, sudoPrompt != nil {
            sudoPrompt = nil
        }
    }

    /// Answers sudo's prompt. Saved passwords need Touch ID first; one typed into Clavra's field
    /// just now doesn't.
    func fillSudo(from source: SudoFill.Source) async {
        guard sudoPrompt != nil else { return }
        let secret: String?
        switch source {
        case .typed(let password, let remember):
            if remember { pendingSudo = (password, .now) }
            secret = password
        case .saved, .signIn:
            guard await SudoFill.unlock(reason: "fill in the sudo password on \(server.title)") else { return }
            secret = source == .saved ? Keychain.sudoPassword(for: server.id) : Keychain.password(for: server.secretsID)
        }
        guard let secret, !secret.isEmpty, sudoPrompt != nil, isLive else { return }
        sudoPrompt = nil
        filledSudo = true
        lastCommand = nil
        outgoing?.yield(.bytes(Array((secret + "\r").utf8)))
        refocus()
    }

    /// "Type It Myself": the card goes until the next Return.
    func dismissSudo() {
        sudoDismissed = true
        sudoPrompt = nil
        refocus()
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
            if held.previewable { lookAtImpact(of: held.command) }
            return
        }
        if data.count == 1, data.first == 0x0D { remember(PromptLine.command(in: logicalLine(), strict: true)) }
        if pressesReturn {
            // A password typed at sudo's own prompt is never kept as the "last command".
            let line = logicalLine()
            if sudoPrompt == nil, let command = PromptLine.command(in: line, strict: true)?.trimmingCharacters(in: .whitespaces),
               !command.isEmpty {
                if !CommandHistory.looksSecret(command) { recorder?.marker(command) }
                running = (command, .now)
            }
            lastCommand = sudoPrompt != nil || SudoFill.isPrompt(line, after: lastCommand) ? nil : (PromptLine.command(in: line, strict: true) ?? typed.text)
            sudoDismissed = false
            filledSudo = false
        }
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
        guard keptAlive == true || !term.isCurrentBufferAlternate else { return hideSuggestion() }
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
        if sudoPrompt != nil, !(data.count == 1 && data.first == 0x0D) {
            sudoDismissed = true
            sudoPrompt = nil
        }
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

    /// A held command needs a phone's yes on this host; the Mac alone can only say no.
    var needsPhoneApproval: Bool { server.guardsCommands && server.phoneApproval }

    /// The user's answer to a held command. On a host that needs a phone's approval, only a
    /// phone can say run.
    func release(run: Bool, fromPhone: Bool = false) {
        guard let held else { return }
        if run, needsPhoneApproval, !fromPhone { return }
        self.held = nil
        if run {
            if !CommandHistory.looksSecret(held.command) { recorder?.marker(held.command) }
            running = (held.command, .now)
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
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" }).dropLast()
        guard let first = parts.first else { return nil }
        pending.feed(ArraySlice(Array(first.utf8)))
        // What the shell will run is on screen: Tab completion and history recall land there, and
        // the typed copy misses them. The typed copy is for a long line that scrolled away.
        let screenLine = logicalLine()
        let whole = PromptLine.command(in: screenLine) + first
        let toCursor = PromptLine.command(in: logicalLine(cutAtCursor: true)) + first
        let hasPrompt = PromptLine.command(in: screenLine, strict: true) != nil
        let rest = parts.dropFirst().map(String.init)
        let candidates = [whole, toCursor, pending.text] + rest
        guard let risk = candidates.lazy.compactMap(CommandGuard.check).first else { return nil }
        // Text right of the cursor is part of the command only if nothing says otherwise: when
        // it's there and the typed copy agrees with the text up to the cursor, it was a suggestion.
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespaces) }
        let suggestionShown = trim(whole) != trim(toCursor)
        let onScreen = suggestionShown && trim(toCursor) == trim(pending.text) ? toCursor : whole
        let certain = !suggestionShown || trim(toCursor) == trim(pending.text)
        let shown = CommandGuard.check(onScreen) != nil || CommandGuard.check(pending.text) == nil ? onScreen : pending.text
        if !rest.isEmpty {
            // A paste of several lines runs every one of them: all of it is shown, and none is previewed.
            let all = ([shown] + rest).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return HeldCommand(command: all.joined(separator: "\n"), reason: risk.reason, bytes: Array(data), previewable: false)
        }
        return HeldCommand(command: shown.trimmingCharacters(in: .whitespaces), reason: risk.reason, bytes: Array(data),
                           previewable: hasPrompt && certain && shown == onScreen)
    }


    // MARK: Blast radius

    /// Reads what the held command would touch, with a look-alike that only reads, over a side
    /// channel. The prompt shows it as soon as it's back.
    private func lookAtImpact(of command: String) {
        impactTask?.cancel()
        let line = logicalLine()
        // A backup is made over a channel of its own, as the login: only when the prompt shows the
        // shell is still that user on that machine. A prompt that shows another one gets no
        // preview either, since it would describe the wrong machine.
        var sameShell = false
        if let shell = BlastRadius.identity(fromPrompt: line), let me = signedInAs {
            let sameHost = shell.host.split(separator: ".").first == me.host.split(separator: ".").first
            guard shell.user == me.user, sameHost, !shell.root || me.user == "root" else {
                impact = .unknown("This shell is \(shell.user)@\(shell.host)\(shell.root ? " as root" : ""), not the login Clavra looks through, so there's no preview.")
                return
            }
            sameShell = true
        }
        let folder = BlastRadius.folder(fromPrompt: line) ?? (BlastRadius.identity(fromPrompt: line) == nil ? reportedFolder : nil)
        switch BlastRadius.plan(for: command, folder: folder) {
        case nil:
            impact = nil
        case .needsFolder:
            impact = .unknown("Couldn't tell which folder the shell is in, so there's no preview.")
        case .probe(let probe):
            guard let client else { impact = nil; return }
            impact = .checking
            impactTask = Task { [weak self] in
                let output = try? await Self.exec(probe.command, on: client)
                guard !Task.isCancelled, let self, self.held?.command == command else { return }
                var lines = output.flatMap { BlastRadius.describe($0, kind: probe.kind, withoutSudo: probe.withoutSudo) }
                if probe.more { lines?.append("Only this first risky part is shown; the line does more after it.") }
                self.impact = lines.map { .found($0) } ?? .unknown("Couldn't read what it would touch.")
                // Worth offering only when something is there and it's small enough to archive quickly.
                if sameShell, let output, let kb = BlastRadius.kilobytes(in: output), kb > 0, kb <= BlastRadius.backupLimitKB {
                    self.backupPlan = probe.backup
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(9))
                guard let self, self.held?.command == command, self.impact == .checking else { return }
                self.impact = .unknown("The server took too long to say what it would touch.")
            }
        }
    }

    /// The line under the cursor with the rows it wrapped from: a long command fills several rows
    /// on screen, and only the first has the prompt. A row above that is full to the last column
    /// is taken to carry on into the next.
    private func logicalLine(cutAtCursor: Bool = false) -> String {
        let term = terminal.getTerminal()
        let cursor = term.getCursorLocation()
        var row = cursor.y
        var text = term.getLine(row: row)?.translateToString(trimRight: true) ?? ""
        // What's right of the cursor may be a shell's suggestion (zsh-autosuggestions, fish), not
        // part of the command.
        if cutAtCursor { text = String(text.prefix(cursor.x)) }
        var steps = 0
        // Blank cells at the end of a row aren't spaces, so a row is only "full" if what's written in
        // it, trailing blanks dropped, reaches the last column.
        while row > 0, steps < 30, let above = term.getLine(row: row - 1)?.translateToString(trimRight: true),
              above.count >= term.cols {
            text = above + text
            row -= 1
            steps += 1
        }
        return text
    }

    private func screenLine() -> String {
        let terminal = terminal.getTerminal()
        let row = terminal.getCursorLocation().y
        return terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
    }


    /// While a pane is being laid out again (a split, coming back from Home) the terminal can be
    /// squeezed to nothing for a moment and report zero or negative columns. SSH sizes are
    /// unsigned, so those would crash; that passing size is skipped and the real one follows.
    fileprivate func resized(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        recorder?.resize(cols: cols, rows: rows)
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

    /// Runs a command that keeps printing (`tail -F`), handing each chunk over as it comes. The
    /// channel closes when the calling task is cancelled.
    func follow(_ command: String, output: @escaping @MainActor ([UInt8]) -> Void) async throws {
        guard let client else { throw ClavraError.notConnected }
        try await Self.follow(command, on: client, output: output)
    }

    private nonisolated static func follow(_ command: String, on box: ClientBox,
                                           output: @escaping @MainActor ([UInt8]) -> Void) async throws {
        try await box.client.withExec(command) { inbound, _ in
            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    let bytes = Array(buffer.readableBytesView)
                    await output(bytes)
                }
            }
        }
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
        if signedInAs == nil, let client {
            Task { [weak self] in
                let lines = (try? await Self.exec("id -un; hostname", on: client))?.split(separator: "\n").map(String.init) ?? []
                if lines.count >= 2 { self?.signedInAs = (lines[0], lines[1]) }
            }
        }
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
    nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? ClavraError, let text = error.errorDescription { return text }
        let raw = String(describing: error)
        if raw.contains("allAuthenticationOptionsFailed") || raw.contains("authentication") {
            return "The server didn't accept this key or password."
        }
        if raw.contains("connectTimeout") || raw.contains("timeout") { return "The server didn't answer. Check the address and your network." }
        if raw.contains("connectionRefused") || raw.contains("Connection refused") { return "The server refused the connection. Is SSH running on that port?" }
        if raw.contains("revokedHostKey") { return ClavraError.revokedHostKey.errorDescription! }
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

    /// OSC 7 from the shell: `file://host/path`, or a bare path.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        if directory.hasPrefix("file://") {
            session?.reportedFolder = URL(string: directory)?.path(percentEncoded: false)
        } else if directory.hasPrefix("/") {
            session?.reportedFolder = directory
        }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { session?.rang() }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
