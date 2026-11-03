import Foundation

/// A log followed live beside the terminal: a file (`tail -F`), the systemd journal, or a Docker
/// container. Lines are coloured by level, can be filtered as they arrive, and pause without
/// losing anything. Runs over a side channel, so the shell stays free.
@MainActor @Observable
final class LogLens {
    enum Source: Equatable, Hashable {
        case file(String)
        case journal(unit: String)
        case docker(String)

        var label: String {
            switch self {
            case .file(let path): (path as NSString).lastPathComponent
            case .journal(let unit): unit.isEmpty ? "journal" : unit
            case .docker(let name): name
            }
        }

        /// What follows it on the server, in `sh`.
        var command: String {
            let script: String
            switch self {
            case .file(let path):
                script = "exec tail -n 300 -F -- \(BlastRadius.quote(path)) 2>&1"
            case .journal(let unit):
                script = "exec journalctl -f -n 300 --no-pager -o short-iso" + (unit.isEmpty ? "" : " -u \(BlastRadius.quote(unit))") + " 2>&1"
            case .docker(let name):
                script = "exec docker logs -f --tail 300 \(BlastRadius.quote(name)) 2>&1"
            }
            return "sh -c " + BlastRadius.quote(script)
        }
    }

    typealias Level = LogLevel

    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
        let level: Level
    }

    private(set) var source: Source?
    private(set) var lines: [Line] = []
    private(set) var running = false
    private(set) var problem: String?
    /// Arrived while paused; shown when it's resumed.
    private(set) var waiting = 0
    private(set) var errors = 0
    private(set) var warnings = 0
    var paused = false {
        didSet { if !paused { flushHeld() } }
    }
    var filter = ""
    var minimum = Level.debug

    static let limit = 5000
    @ObservationIgnored private weak var session: Session?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var carry: [UInt8] = []
    @ObservationIgnored private var held: [Line] = []
    @ObservationIgnored private var counter = 0

    init(session: Session) {
        self.session = session
    }

    var visible: [Line] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return lines.filter { $0.level >= minimum && (q.isEmpty || $0.text.localizedCaseInsensitiveContains(q)) }
    }

    func follow(_ source: Source) {
        stop()
        self.source = source
        lines = []
        held = []
        waiting = 0
        errors = 0
        warnings = 0
        problem = nil
        carry = []
        guard let session else { return }
        running = true
        let command = source.command
        task = Task { [weak self] in
            do {
                try await session.follow(command) { bytes in self?.receive(bytes) }
                guard let self, !Task.isCancelled else { return }
                self.running = false
                if self.lines.isEmpty { self.problem = "It ended without printing anything. Check the name, and whether you can read it without sudo." }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.running = false
                self.problem = Session.describe(error)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    func clear() {
        lines = []
        held = []
        waiting = 0
        errors = 0
        warnings = 0
    }

    private func receive(_ bytes: [UInt8]) {
        var data = carry + bytes
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else {
            carry = data.count > 16_384 ? [] : data
            return
        }
        carry = Array(data[(lastBreak + 1)...])
        data.removeSubrange((lastBreak + 1)...)
        var fresh: [Line] = []
        for raw in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast() {
            let text = LogLevel.clean(String(decoding: raw, as: UTF8.self))
            counter += 1
            let level = LogLevel.of(text)
            if level == .error { errors += 1 } else if level == .warning { warnings += 1 }
            fresh.append(Line(id: counter, text: text, level: level))
        }
        if paused {
            held += fresh
            if held.count > Self.limit { held.removeFirst(held.count - Self.limit) }
            waiting = held.count
        } else {
            append(fresh)
        }
    }

    private func flushHeld() {
        append(held)
        held = []
        waiting = 0
    }

    private func append(_ fresh: [Line]) {
        guard !fresh.isEmpty else { return }
        lines += fresh
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }
}
