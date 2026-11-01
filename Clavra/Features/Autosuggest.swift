import AppKit
import CryptoKit
import SwiftTerm

/// Commands run on one host, newest last, for suggestions as you type (like zsh-autosuggestions).
/// What you run through Clavra is kept on this Mac; the server's own shell history is read when a
/// session starts and held in memory only.
@MainActor
final class CommandHistory {
    private static var cache: [String: CommandHistory] = [:]

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "Autosuggest") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "Autosuggest") }
    }

    /// One history per saved host, or per `user@address:port` for quick connections.
    static func of(_ server: Server, saved: Bool) -> CommandHistory {
        let key = saved ? server.id.uuidString
            : SHA256.hash(data: Data("\(server.user)@\(server.address):\(server.port)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let history = cache[key] { return history }
        let history = CommandHistory(key: key)
        cache[key] = history
        return history
    }

    private let file: URL
    private(set) var ran: [String] = []
    private var fromServer: [String] = []

    private init(key: String) {
        file = Library.folder.appending(path: "History/\(key).json")
        ran = Library.load([String].self, from: file) ?? []
    }

    func record(_ command: String) {
        let line = command.trimmingCharacters(in: .whitespaces)
        guard line.count > 1, !command.hasPrefix(" "), !Self.looksSecret(line) else { return }
        ran.removeAll { $0 == line }
        ran.append(line)
        if ran.count > 1000 { ran.removeFirst(ran.count - 1000) }
        Library.save(ran, to: file)
    }

    /// Lines from the server's ~/.zsh_history and ~/.bash_history.
    func seed(_ text: String) {
        fromServer = text.split(separator: "\n").compactMap { raw in
            var line = String(raw)
            // zsh's extended format: ": 1700000000:0;command"
            if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") { line = String(line[line.index(after: semicolon)...]) }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.count > 1 && !Self.looksSecret(line) ? line : nil
        }
    }

    /// The rest of the newest command that starts with what's typed.
    func suggestion(for typed: String) -> String? {
        guard !typed.isEmpty, typed.trimmingCharacters(in: .whitespaces).count >= 1 else { return nil }
        for list in [ran, fromServer] {
            if let match = list.last(where: { $0.hasPrefix(typed) && $0.count > typed.count }) {
                return String(match.dropFirst(typed.count))
            }
        }
        return nil
    }

    func forgetAll() {
        ran = []
        try? FileManager.default.removeItem(at: file)
    }

    static func forgetEverything() {
        for history in cache.values { history.ran = [] }
        try? FileManager.default.removeItem(at: Library.folder.appending(path: "History"))
    }

    /// Passwords and tokens typed on a command line aren't worth remembering.
    private static let secret = try! NSRegularExpression(
        pattern: #"(pass(word|wd)?|secret|token|api[_-]?key|auth)\s*[=:]|--password\b|\bmysql\b.*\s-p\S|\bsshpass\b|\bAuthorization:"#,
        options: [.caseInsensitive])

    static func looksSecret(_ line: String) -> Bool {
        secret.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}

/// Grey text after the cursor showing the rest of a suggestion. It lives inside the terminal view,
/// in the terminal's own font, so it sits exactly where the characters would.
@MainActor
final class GhostText {
    private let label: NSTextField

    init(in terminal: TerminalView) {
        label = NSTextField(labelWithString: "")
        label.textColor = NSColor(hex: 0x6F6B66)
        label.isHidden = true
        label.lineBreakMode = .byClipping
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        terminal.addSubview(label)
    }

    func show(_ text: String, column: Int, row: Int, in terminal: TerminalView) {
        let font = terminal.font
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        label.font = font
        label.stringValue = text
        let x = CGFloat(column) * width
        let y = terminal.frame.height - CGFloat(row + 1) * height
        let available = max(terminal.frame.width - x - 16, 0)
        // NSTextField adds a couple of points of inset; nudge it back onto the grid.
        label.frame = NSRect(x: x - 2, y: y, width: available, height: height)
        label.isHidden = text.isEmpty || available < width
    }

    func hide() {
        label.isHidden = true
        label.stringValue = ""
    }
}
