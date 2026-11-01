import Foundation

/// Spots commands that are hard to take back. Production hosts (or any host with the guard on) ask
/// before Return sends one of these.
enum CommandGuard {
    struct Risk: Equatable {
        /// What we'd say about it, e.g. "Deletes files for good".
        var reason: String
    }

    private static let rules: [(pattern: String, reason: String)] = [
        (#"\brm\s+(-\w+\s+)*-\w*[rRf]"#, "Deletes files without asking"),
        (#"\b(drop)\s+(database|schema|table)\b"#, "Drops data from the database"),
        (#"\btruncate\s+(table\s+)?[\w\.\"`]+"#, "Empties a table or file"),
        (#"\bdelete\s+from\s+[\w\.\"`]+\s*;?\s*$"#, "Deletes every row: there's no WHERE"),
        (#"\bupdate\s+[\w\.\"`]+\s+set\s+((?!\bwhere\b).)*$"#, "Changes every row: there's no WHERE"),
        // Only as a command, so `grep reboot-required` or `less /var/log/shutdown.log` pass.
        (#"(^|[;&|(]|\bsudo|\bthen|\bdo|\bexec)\s*(shutdown|reboot|poweroff|halt)(?![-.\w/])"#, "Turns the server off or restarts it"),
        (#"\binit\s+[06]\b"#, "Turns the server off or restarts it"),
        (#"\bmkfs(\.\w+)?\b"#, "Formats a disk"),
        (#"\bdd\s+.*\bof=/dev/"#, "Writes straight onto a disk"),
        (#">\s*/dev/(sd|nvme|vd|xvd)"#, "Writes straight onto a disk"),
        (#"\bsystemctl\s+(stop|restart|disable|mask|kill)\b"#, "Stops or restarts a service"),
        (#"\bservice\s+\S+\s+(stop|restart)\b"#, "Stops or restarts a service"),
        (#"\bkill(all)?\s+(-9|-KILL|-SIGKILL)\b"#, "Kills processes without letting them clean up"),
        (#"\bpkill\b"#, "Kills processes by name"),
        (#"\bdocker\s+(rm|rmi|kill|stop)\b"#, "Removes or stops containers"),
        (#"\bdocker\s+(system|container|volume|image|network)\s+(prune|rm)\b"#, "Removes Docker data"),
        (#"\bdocker[\s-]compose\s+(down|rm|kill|stop)\b"#, "Takes containers down"),
        (#"\bkubectl\s+(delete|drain|scale)\b"#, "Changes what's running in the cluster"),
        (#"\bterraform\s+(destroy|apply)\b"#, "Changes real infrastructure"),
        (#"\bgit\s+push\b.*(\s--force\b|\s-f\b|\s--force-with-lease\b)"#, "Rewrites history on the remote"),
        (#"\bgit\s+(reset\s+--hard|clean\s+-\w*f)"#, "Throws away uncommitted work"),
        (#"\bch(mod|own)\s+(-\w*R\w*)\b"#, "Changes permissions on a whole tree"),
        (#"\b(iptables|ip6tables)\s+(-F|--flush)\b"#, "Clears the firewall"),
        (#"\bufw\s+(disable|reset)\b"#, "Turns the firewall off"),
        (#"\b(apt|apt-get|yum|dnf)\s+(remove|purge|autoremove)\b"#, "Uninstalls packages"),
        (#"\bcrontab\s+-r\b"#, "Removes every cron job"),
        (#":\(\)\s*\{\s*:\|:&\s*\};:"#, "Fork bomb"),
        (#"\bredis-cli\b.*\bflush(all|db)\b"#, "Empties Redis"),
        (#"\b(dropdb|mysqladmin\s+drop)\b"#, "Drops a database"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]))
            .map { ($0, rule.reason) }
    }

    static func check(_ line: String) -> Risk? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (regex, reason) in compiled where regex.firstMatch(in: text, range: range) != nil {
            return Risk(reason: reason)
        }
        return nil
    }
}

/// What the user has typed since the last Return, kept alongside the terminal's own line. The
/// terminal shows what the shell put back (history, completion); this catches what scrolled away
/// on a long, wrapped line.
struct TypedLine {
    private(set) var text = ""

    mutating func feed(_ bytes: ArraySlice<UInt8>) {
        var bytes = Array(bytes)
        // A paste arrives wrapped in markers; keep what's inside.
        for marker in ["\u{1b}[200~", "\u{1b}[201~"] {
            let pattern = Array(marker.utf8)
            while let range = bytes.firstRange(of: pattern) { bytes.removeSubrange(range) }
        }
        // Other escape sequences (arrows, function keys) move the shell's cursor; we can't follow
        // them, so this copy stops being reliable. The terminal's own line covers those cases.
        if bytes.first == 0x1B { return }
        for byte in bytes {
            switch byte {
            case 0x7F, 0x08:
                if !text.isEmpty { text.removeLast() }
            case 0x03, 0x15, 0x0D, 0x0A:  // ⌃C, ⌃U, Return
                text = ""
            case 0x17:  // ⌃W: the last word
                while text.last == " " { text.removeLast() }
                while let last = text.last, last != " " { text.removeLast() }
            case 0x20...0x7E:
                text.append(Character(UnicodeScalar(byte)))
            default:
                break
            }
        }
    }

    mutating func reset() { text = "" }
}
