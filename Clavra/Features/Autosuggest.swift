import CryptoKit
import Foundation

/// Commands run on one host, newest last, for suggestions as you type (like zsh-autosuggestions).
/// What you run through Clavra is kept on this Mac; the server's own shell history is read when a
/// session starts and held in memory only.
@MainActor
final class CommandHistory {
    private static var cache: [String: CommandHistory] = [:]

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "Autosuggest") == nil || UserDefaults.standard.bool(forKey: "Autosuggest") }
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
        pattern: #"\w*(pass(word|wd|phrase)?|secret|token|api[_-]?key|auth|credential|private[_-]?key)\w*\s*[=:]|--(password|token|secret)\b|\bmysql\b.*\s-p\S|\bsshpass\b|\bAuthorization:|\s-u\s+\S+:\S|://[^/\s:@]+:[^/\s@]+@|\b(AKIA|ghp_|gho_|github_pat_|xox[bpas]-|sk-|sk_live_)\w+"#,
        options: [.caseInsensitive])

    static func looksSecret(_ line: String) -> Bool {
        secret.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
