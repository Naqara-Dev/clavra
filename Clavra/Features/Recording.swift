import Foundation

/// Terminal sessions written down as they happen, so "what did I run on prod last Tuesday" has an
/// answer you can watch. Files are asciinema's v2 format (`.cast`): Clavra plays them back, and so
/// does `asciinema play`. Each command run is a marker on the timeline.
///
/// Off unless turned on, kept on this Mac only (never in iCloud), readable only by you, and
/// removed after `keepDays`.
enum Recordings {
    enum Policy: String, CaseIterable {
        case off, production, all

        var label: String {
            switch self {
            case .off: "Off"
            case .production: "Hosts that ask before risky commands"
            case .all: "Every host"
            }
        }
    }

    static var policy: Policy {
        get { UserDefaults.standard.string(forKey: "RecordSessions").flatMap(Policy.init(rawValue:)) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "RecordSessions") }
    }

    static let keepDays = 30

    static var folder: URL { Library.folder.appending(path: "Recordings", directoryHint: .isDirectory) }

    static func records(_ server: Server) -> Bool {
        switch policy {
        case .off: false
        case .production: server.guardsCommands
        case .all: true
        }
    }

    /// Older than `keepDays`: gone. Run once at launch.
    static func prune() {
        let cutoff = Date.now.addingTimeInterval(-Double(keepDays) * 86_400)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "cast",
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Reading

    /// One recording, as the list shows it.
    struct Info: Identifiable, Hashable, Sendable {
        var url: URL
        var title: String
        var host: String
        var started: Date
        var duration: TimeInterval
        var size: Int
        /// Commands run, with when.
        var commands: [Marker]
        var id: URL { url }
    }

    struct Marker: Hashable, Sendable {
        var time: TimeInterval
        var text: String
    }

    /// Every recording, newest first. Reads each file once; cheap enough for a month of them.
    static func list() -> [Info] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var found: [Info] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "cast", let info = info(at: url) else { continue }
            found.append(info)
        }
        return found.sorted { $0.started > $1.started }
    }

    static func info(at url: URL) -> Info? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)[...]
        guard let first = lines.popFirst(),
              let header = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any] else { return nil }
        let started = Date(timeIntervalSince1970: header["timestamp"] as? Double ?? 0)
        var commands: [Marker] = []
        var last: TimeInterval = 0
        let marker = Array(#","m","#.utf8)
        for line in lines {
            // Only marker lines are decoded; output lines just give the time.
            if line.firstRange(of: marker) != nil,
               let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [Any],
               let time = event.first as? Double, let text = event.last as? String {
                commands.append(Marker(time: time, text: text))
            }
            if let comma = line.firstIndex(of: UInt8(ascii: ",")),
               let time = Double(String(decoding: line[line.index(after: line.startIndex)..<comma], as: UTF8.self)) {
                last = time
            }
        }
        let clavra = header["clavra"] as? [String: Any]
        return Info(url: url, title: header["title"] as? String ?? url.deletingPathExtension().lastPathComponent,
                    host: clavra?["host"] as? String ?? "", started: started, duration: last, size: data.count, commands: commands)
    }

    /// The whole recording, for playing.
    struct Tape: Sendable {
        enum Event: Sendable {
            case output(String)
            case resize(cols: Int, rows: Int)
        }
        var cols: Int
        var rows: Int
        var events: [(time: TimeInterval, event: Event)]
        var duration: TimeInterval { events.last?.time ?? 0 }
    }

    static func tape(at url: URL) -> Tape? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)[...]
        guard let first = lines.popFirst(),
              let header = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any] else { return nil }
        var tape = Tape(cols: header["width"] as? Int ?? 80, rows: header["height"] as? Int ?? 24, events: [])
        tape.events.reserveCapacity(lines.count)
        for line in lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [Any], event.count == 3,
                  let time = event[0] as? Double, let type = event[1] as? String, let text = event[2] as? String else { continue }
            switch type {
            case "o":
                tape.events.append((time, .output(text)))
            case "r":
                let parts = text.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { tape.events.append((time, .resize(cols: parts[0], rows: parts[1]))) }
            default:
                break
            }
        }
        return tape
    }
}

/// Writes one session's recording. Calls come from the main actor; the file is written on a queue
/// of its own.
final class SessionRecorder: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.naqara.clavra.recorder")
    private let started = Date.now
    /// The end of a UTF-8 character cut off by the last chunk, kept for the next.
    private var carry: [UInt8] = []
    private var written = 0
    private var full = false
    /// A recording stops growing here; the session goes on.
    static let limit = 64 << 20

    init?(server: Server, cols: Int, rows: Int) {
        let folder = Recordings.folder.appending(path: server.id.uuidString, directoryHint: .isDirectory)
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        // Two tabs on one host can connect in the same second (restoring tabs): each gets its own file.
        url = folder.appending(path: "\(stamp)-\(UUID().uuidString.prefix(6).lowercased()).cast")
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        let header: [String: Any] = [
            "version": 2, "width": max(cols, 1), "height": max(rows, 1), "timestamp": Int(started.timeIntervalSince1970),
            "title": "\(server.title) · \(server.target)", "env": ["TERM": "xterm-256color"],
            "clavra": ["host": server.title, "hostID": server.id.uuidString, "target": server.target],
        ]
        write(header)
    }

    func output(_ bytes: [UInt8]) {
        let time = elapsed
        queue.async { [self] in
            var chunk = carry + bytes
            let cut = Self.completeLength(chunk)
            carry = Array(chunk[cut...])
            chunk.removeSubrange(cut...)
            guard !chunk.isEmpty else { return }
            event(time, "o", String(decoding: chunk, as: UTF8.self))
        }
    }

    /// A command was run: a marker on the timeline.
    func marker(_ command: String) {
        let time = elapsed
        queue.async { [self] in event(time, "m", command) }
    }

    func resize(cols: Int, rows: Int) {
        let time = elapsed
        queue.async { [self] in event(time, "r", "\(cols)x\(rows)") }
    }

    func close() {
        queue.async { [self] in try? handle.close() }
    }

    private var elapsed: Double { (Date.now.timeIntervalSince(started) * 1000).rounded() / 1000 }

    /// `[1.234, "o", "text"]`, with the time to the millisecond rather than as a long float.
    private func event(_ time: Double, _ type: String, _ text: String) {
        guard !full, let quoted = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]) else { return }
        var line = Data("[\(String(format: "%.3f", time)),\"\(type)\",".utf8)
        line.append(quoted.dropFirst().dropLast())
        line.append(contentsOf: Array("]\n".utf8))
        append(line)
    }

    private func write(_ object: Any) {
        guard !full, var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(UInt8(ascii: "\n"))
        append(data)
    }

    private func append(_ line: Data) {
        guard !full else { return }
        var data = line
        written += data.count
        if written > Self.limit {
            full = true
            data = Data((try? JSONSerialization.data(withJSONObject: [elapsed, "o", "\r\n[Clavra: the recording stopped here; it reached 64 MB]\r\n"])) ?? Data())
            data.append(UInt8(ascii: "\n"))
        }
        try? handle.write(contentsOf: data)
    }

    /// How much of `bytes` ends on a whole UTF-8 character.
    static func completeLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        var back = 0
        while index >= 0, back < 4 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 { index -= 1; back += 1; continue }
            let needs = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return bytes.count - index < needs ? index : bytes.count
        }
        return bytes.count
    }
}
