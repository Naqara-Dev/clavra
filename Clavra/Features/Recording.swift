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

    /// Posted on the main thread when a recording starts or is finished, so the list can refresh.
    static let didChange = Notification.Name("ClavraRecordingsChanged")
    static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

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
        Recordings.changed()
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

    /// A command was run: a marker on the timeline, with any secret in it hidden.
    func marker(_ command: String) {
        let time = elapsed
        let shown = Redaction.isOn ? Redaction.redact(command) : command
        queue.async { [self] in event(time, "m", shown) }
    }

    func resize(cols: Int, rows: Int) {
        let time = elapsed
        queue.async { [self] in event(time, "r", "\(cols)x\(rows)") }
    }

    /// Closes the file, then hides the secrets in it.
    func close() {
        let url = url
        let redact = Redaction.isOn
        queue.async { [self] in
            try? handle.close()
            if redact { Redaction.apply(to: url) }
            Recordings.changed()
        }
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

/// Secrets kept out of recordings: tokens, passwords in `KEY=…` and `--password …`, credentials in
/// URLs and headers, private keys, and words of your own. Each hidden character becomes `•`, so
/// the screen keeps its shape when played back. Words on the allow list are left as they are.
enum Redaction {
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "RedactRecordings") == nil || UserDefaults.standard.bool(forKey: "RedactRecordings") }
        set { UserDefaults.standard.set(newValue, forKey: "RedactRecordings") }
    }

    /// Hidden wherever they appear, one per line in Recordings.
    static var extraWords: [String] {
        get { UserDefaults.standard.stringArray(forKey: "RedactWords") ?? [] }
        set { UserDefaults.standard.set(newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: "RedactWords") }
    }

    /// Never hidden, even when they look like a secret.
    static var allowed: [String] {
        get { UserDefaults.standard.stringArray(forKey: "RedactAllow") ?? [] }
        set { UserDefaults.standard.set(newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: "RedactAllow") }
    }

    /// Each pattern, and which capture group is the secret (0: all of it).
    private static let patterns: [(NSRegularExpression, Int)] = [
        (#"(?i)\b(?:pass(?:word|wd|phrase)?|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|credentials?|private[_-]?key)\w*\s*[=:]\s*["']?([^\s"'`;&|]+)"#, 1),
        (#"(?i)--(?:password|passwd|token|secret|api-key|access-key)(?:=|\s+)["']?([^\s"']+)"#, 1),
        (#"\bmysql(?:dump)?\b[^\n]*?\s-p([^\s]+)"#, 1),
        (#"://[^/\s:@]+:([^/\s@]+)@"#, 1),
        (#"(?i)\bauthorization:\s*(?:bearer\s+|basic\s+|token\s+)?([^\s"']+)"#, 1),
        (#"\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}|xox[bpas]-[\w-]{10,}|sk-[A-Za-z0-9_-]{20,}|sk_live_\w{10,}|glpat-[\w-]{20,})"#, 0),
        (#"\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}"#, 0),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, 0),
    ].compactMap { pattern, group in (try? NSRegularExpression(pattern: pattern)).map { ($0, group) } }

    /// Where the secrets are in `text`, as UTF-16 ranges.
    static func ranges(in text: String, words: [String] = extraWords, allow: [String] = allowed) -> [NSRange] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [NSRange] = []
        for (regex, group) in patterns {
            for match in regex.matches(in: text, range: all) {
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let value = ns.substring(with: range)
                if allow.contains(where: { !$0.isEmpty && value.contains($0) }) { continue }
                found.append(range)
            }
        }
        for word in words where !word.isEmpty && !allow.contains(word) {
            var search = all
            while true {
                let range = ns.range(of: word, options: [], range: search)
                guard range.location != NSNotFound else { break }
                found.append(range)
                search = NSRange(location: range.upperBound, length: all.upperBound - range.upperBound)
            }
        }
        return found
    }

    /// `text` with every secret character turned to `•` (spaces and line breaks kept).
    static func redact(_ text: String, words: [String] = extraWords, allow: [String] = allowed) -> String {
        let found = ranges(in: text, words: words, allow: allow)
        guard !found.isEmpty else { return text }
        var units = Array(text.utf16)
        let dot = "•".utf16.first!
        for range in found {
            for i in range.location..<min(range.upperBound, units.count) where !isBlank(units[i]) { units[i] = dot }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09 }

    /// Hides the secrets in a finished recording, across the chunks output arrived in (a token
    /// typed a key at a time is still one token). Marks the file done so it isn't read twice.
    static func apply(to url: URL, words: [String] = extraWords, allow: [String] = allowed) {
        guard let data = try? Data(contentsOf: url) else { return }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        guard let first = lines.first, var header = try? JSONSerialization.jsonObject(with: first) as? [String: Any] else { return }
        var clavra = header["clavra"] as? [String: Any] ?? [:]
        if clavra["redacted"] as? Bool == true { return }

        // Output events, joined, with where each one starts.
        var events: [(line: Int, time: Double, type: String, text: String)] = []
        for (index, line) in lines.enumerated().dropFirst() {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [Any], event.count == 3,
                  let time = event[0] as? Double, let type = event[1] as? String, let text = event[2] as? String else { continue }
            events.append((index, time, type, text))
        }
        let outputs = events.filter { $0.type == "o" }
        let joined = outputs.map(\.text).joined()
        var units = Array(joined.utf16)
        let dot = "•".utf16.first!
        for range in ranges(in: joined, words: words, allow: allow) {
            for i in range.location..<min(range.upperBound, units.count) where !isBlank(units[i]) { units[i] = dot }
        }
        var offset = 0
        for event in events {
            let text: String
            if event.type == "o" {
                let count = event.text.utf16.count
                text = String(decoding: units[offset..<offset + count], as: UTF16.self)
                offset += count
            } else if event.type == "m" {
                text = redact(event.text, words: words, allow: allow)
            } else {
                continue
            }
            if let encoded = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]) {
                var line = Data("[\(String(format: "%.3f", event.time)),\"\(event.type)\",".utf8)
                line.append(encoded.dropFirst().dropLast())
                line.append(UInt8(ascii: "]"))
                lines[event.line] = line
            }
        }
        clavra["redacted"] = true
        header["clavra"] = clavra
        guard let newHeader = try? JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes]) else { return }
        lines[0] = newHeader
        var out = Data()
        for line in lines { out.append(line); out.append(UInt8(ascii: "\n")) }
        try? out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Recordings a crash or a forced quit left unfinished: hidden now.
    static func catchUp() {
        guard isOn else { return }
        let files = FileManager.default.enumerator(at: Recordings.folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "cast" { apply(to: url) }
        }
    }
}
