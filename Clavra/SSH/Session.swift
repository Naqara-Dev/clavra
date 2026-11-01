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
        case askingHostKey(HostKeyQuestion)
        case connected
        case failed(String)
        case closed
    }

    struct HostKeyQuestion: Equatable {
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

    let id = UUID()
    private(set) var server: Server
    private(set) var state: State = .connecting
    private(set) var title: String
    @ObservationIgnored let terminal: TerminalView

    @ObservationIgnored private var client: ClientBox?
    @ObservationIgnored private var outgoing: AsyncStream<Outgoing>.Continuation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let relay = TerminalRelay()

    init(server: Server) {
        self.server = server
        title = server.title
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalStyle.apply(to: terminal)
        relay.session = self
        terminal.terminalDelegate = relay
    }

    var isLive: Bool { state == .connected }

    func connect() {
        task?.cancel()
        state = .connecting
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        task = Task { await run() }
    }

    /// Picks up edits made to the host while this tab was failing, then tries again.
    func retry(with server: Server) {
        self.server = server
        title = server.title
        connect()
    }

    func close() {
        answer?.resume(returning: false)
        answer = nil
        outgoing?.finish()
        task?.cancel()
        client?.close()
        client = nil
        if state != .closed, !isFailed { state = .closed }
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

    private func run() async {
        do {
            nonisolated(unsafe) let method = try Credentials.method(for: server)
            let check = HostKeyCheck { [weak self] key in await self?.decide(key) ?? false }
            var settings = SSHClientSettings(host: server.address, port: server.port,
                                             authenticationMethod: { method }, hostKeyValidator: .custom(check))
            settings.connectTimeout = .seconds(12)
            let client = ClientBox(try await SSHClient.connect(to: settings))
            self.client = client

            let (input, sink) = AsyncStream.makeStream(of: Outgoing.self)
            outgoing = sink
            let size = terminal.getTerminal()
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "xterm-256color",
                terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
            state = .connected
            #if DEBUG
            // `-ClavraType 'ls\r'` types into the shell once it's up, to check input end to end.
            if let typed = UserDefaults.standard.string(forKey: "ClavraType") {
                let bytes = Array(typed.replacingOccurrences(of: "\\r", with: "\r").utf8)
                Task { try? await Task.sleep(for: .seconds(1.5)); self.outgoing?.yield(.bytes(bytes)) }
            }
            #endif

            try await Self.pump(client, request: request, input: input) { [weak self] bytes in
                await self?.show(bytes)
            }
            end(.closed)
        } catch is CancellationError {
        } catch {
            end(.failed(Self.describe(error)))
        }
    }

    private func end(_ final: State) {
        outgoing?.finish()
        outgoing = nil
        client?.close()
        client = nil
        if case .failed = final { state = final } else if state != .closed { state = final }
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
    }

    private func decide(_ text: String) async -> Bool {
        let verdict = KnownHosts.check(host: server.address, port: server.port, key: text)
        if verdict == .trusted { return true }
        let type = text.split(separator: " ").first.map(String.init) ?? "key"
        state = .askingHostKey(HostKeyQuestion(type: type, fingerprint: KnownHosts.fingerprint(text), changed: verdict == .changed))
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ClavraAutoTrust") {
            Task { try? await Task.sleep(for: .seconds(2.5)); self.answerHostKey(true) }
        }
        #endif
        let trust = await withCheckedContinuation { answer = $0 }
        if trust { KnownHosts.trust(host: server.address, port: server.port, key: text) }
        return trust
    }

    // MARK: Terminal

    fileprivate func send(_ data: ArraySlice<UInt8>) {
        outgoing?.yield(.bytes(Array(data)))
    }

    fileprivate func resized(cols: Int, rows: Int) {
        outgoing?.yield(.resize(cols: cols, rows: rows))
    }

    fileprivate func retitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        title = trimmed.isEmpty ? server.title : trimmed
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
private final class ClientBox: @unchecked Sendable {
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
        session?.send(data)
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
    func bell(source: TerminalView) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
