import Foundation

/// A host's runbook: how to deploy, restart, or get it out of trouble, written in Markdown and kept
/// beside its terminal. Code blocks run with a click (through the same guard as typing), and
/// `- [ ]` steps tick off as you go.
@MainActor @Observable
final class RunbookStore {
    private(set) var texts: [String: String] = [:]
    private var file: URL { Library.dataFolder.appending(path: "runbooks.json") }

    init() { reload() }

    func reload() {
        if let saved = Library.load([String: String].self, from: file), saved != texts { texts = saved }
    }

    func text(for host: Server.ID) -> String { texts[host.uuidString] ?? "" }

    func save(_ text: String, for host: Server.ID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        texts[host.uuidString] = trimmed.isEmpty ? nil : text
        Library.save(texts, to: file)
    }

    /// Ticks or unticks the step on `line` of the host's runbook.
    func toggle(line: Int, for host: Server.ID) {
        var lines = text(for: host).components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        let current = lines[line]
        if let range = current.range(of: "- [ ]") {
            lines[line] = current.replacingCharacters(in: range, with: "- [x]")
        } else if let range = current.range(of: "- [x]") ?? current.range(of: "- [X]") {
            lines[line] = current.replacingCharacters(in: range, with: "- [ ]")
        }
        save(lines.joined(separator: "\n"), for: host)
    }

    /// Every step unticked, for the next run through.
    func resetSteps(for host: Server.ID) {
        let text = text(for: host).replacingOccurrences(of: "- [x]", with: "- [ ]").replacingOccurrences(of: "- [X]", with: "- [ ]")
        save(text, for: host)
    }

    static let starter = """
    # Deploy

    - [ ] Tell the team it's going out
    - [ ] Check nothing is mid-migration

    ```
    cd /srv/app && git pull --ff-only
    ```

    ```
    sudo systemctl restart app
    ```

    - [ ] Watch the error log for a minute

    # When it's down

    Who's eating the disk:

    ```
    du -xh / 2>/dev/null | sort -h | tail -n 15
    ```
    """
}

/// A runbook, read into what the panel draws.
enum RunbookBlock: Equatable, Identifiable {
    case heading(String, level: Int, line: Int)
    case step(String, done: Bool, line: Int)
    case code(String, line: Int)
    case text(String, line: Int)

    var id: Int {
        switch self {
        case .heading(_, _, let line), .step(_, _, let line), .code(_, let line), .text(_, let line): line
        }
    }

    static func parse(_ markdown: String) -> [RunbookBlock] {
        var blocks: [RunbookBlock] = []
        var code: [String]?
        var codeStart = 0
        var paragraph: [String] = []
        var paragraphStart = 0
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: " "), line: paragraphStart)) }
            paragraph = []
        }
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n"), line: codeStart))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                    codeStart = index
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flushParagraph(); continue }
            if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), level: level, line: index))
            } else if line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
                flushParagraph()
                blocks.append(.step(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces), done: !line.hasPrefix("- [ ]"), line: index))
            } else if line.hasPrefix("$ ") {
                flushParagraph()
                blocks.append(.code(String(line.dropFirst(2)), line: index))
            } else {
                if paragraph.isEmpty { paragraphStart = index }
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"), line: codeStart)) }
        flushParagraph()
        return blocks
    }
}
