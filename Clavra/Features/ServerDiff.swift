import Foundation

/// Two servers side by side: packages, running services, listening ports, a config file, a whole
/// folder by checksum, or what any read-only command prints. Catches the drift between staging and
/// production before it bites.
enum ServerDiff {
    enum Subject: String, CaseIterable, Identifiable {
        case packages, services, ports, file, folder, command
        var id: String { rawValue }

        var label: String {
            switch self {
            case .packages: "Packages"
            case .services: "Services"
            case .ports: "Ports"
            case .file: "A file"
            case .folder: "A folder"
            case .command: "A command"
            }
        }

        var placeholder: String? {
            switch self {
            case .file: "/etc/nginx/nginx.conf"
            case .folder: "/etc/nginx"
            case .command: "cat /etc/os-release"
            default: nil
            }
        }

        /// Compared by name (a package, a unit, a file), not line by line.
        var isKeyed: Bool { self != .file && self != .command }
    }

    /// What runs on both servers, in `sh`. Nil when the field isn't usable.
    static func command(for subject: Subject, input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespaces)
        let script: String
        switch subject {
        case .packages:
            script = "(dpkg-query -W -f='${Package} ${Version}\\n' 2>/dev/null || rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\\n' 2>/dev/null || apk info -v 2>/dev/null) | sort"
        case .services:
            script = "systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | sort"
        case .ports:
            script = "(ss -ltnH 2>/dev/null || netstat -ltn 2>/dev/null | tail -n +3) | awk '{print $4}' | sed 's/.*[:.]//' | sort -n -u"
        case .file:
            guard !text.isEmpty else { return nil }
            script = "cat -- " + BlastRadius.quote(text) + " 2>&1; exit 0"
        case .folder:
            guard !text.isEmpty else { return nil }
            script = "cd " + BlastRadius.quote(text) + " 2>/dev/null || { echo 'No such folder here.'; exit 0; }; H=sha256sum; command -v sha256sum >/dev/null 2>&1 || H='shasum -a 256'; "
                + "find . -type f 2>/dev/null | head -n 20000 | while IFS= read -r f; do $H \"$f\"; done 2>/dev/null"
        case .command:
            // Run as typed on both, so it's for commands that read. Anything the guard would hold
            // back isn't run at all, and the page asks before running the rest.
            guard !text.isEmpty, CommandGuard.check(text) == nil else { return nil }
            script = "(" + text + "\n) 2>&1; exit 0"
        }
        return "sh -c " + BlastRadius.quote(script)
    }

    struct Row: Identifiable, Hashable {
        enum Kind { case same, onlyLeft, onlyRight, changed }
        var id: Int
        var kind: Kind
        /// For keyed lists, the name; for files, empty.
        var key: String
        var left: String
        var right: String
    }

    static func rows(_ left: String, _ right: String, subject: Subject) -> [Row] {
        let a = lines(left), b = lines(right)
        return subject.isKeyed ? keyed(a, b, subject: subject) : aligned(a, b)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }.reversed().drop { $0.isEmpty }.reversed()
    }

    /// Name and value: `nginx 1.24.0-2`, `abc123…  ./conf.d/site.conf`, or just a name.
    private static func split(_ line: String, subject: Subject) -> (String, String) {
        if subject == .folder, let range = line.range(of: "  ") {
            return (String(line[range.upperBound...]), String(line[..<range.lowerBound].prefix(12)))
        }
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    private static func keyed(_ a: [String], _ b: [String], subject: Subject) -> [Row] {
        var left: [String: String] = [:], right: [String: String] = [:]
        for line in a where !line.isEmpty { let (k, v) = split(line, subject: subject); left[k] = v }
        for line in b where !line.isEmpty { let (k, v) = split(line, subject: subject); right[k] = v }
        let keys = Set(left.keys).union(right.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return keys.enumerated().map { index, key in
            switch (left[key], right[key]) {
            case let (l?, r?): Row(id: index, kind: l == r ? .same : .changed, key: key, left: l, right: r)
            case let (l?, nil): Row(id: index, kind: .onlyLeft, key: key, left: l, right: "")
            case let (nil, r?): Row(id: index, kind: .onlyRight, key: key, left: "", right: r)
            default: Row(id: index, kind: .same, key: key, left: "", right: "")
            }
        }
    }

    /// Line by line, lined up the way `diff` would; a removed line next to an added one reads as a change.
    private static func aligned(_ a: [String], _ b: [String]) -> [Row] {
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        var lefts: [String] = [], rights: [String] = []
        func flush() {
            for k in 0..<max(lefts.count, rights.count) {
                let l = k < lefts.count ? lefts[k] : nil, r = k < rights.count ? rights[k] : nil
                let kind: Row.Kind = l != nil && r != nil ? .changed : l != nil ? .onlyLeft : .onlyRight
                rows.append(Row(id: rows.count, kind: kind, key: "", left: l ?? "", right: r ?? ""))
            }
            lefts = []; rights = []
        }
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { lefts.append(a[i]); i += 1; continue }
            if j < b.count, inserted.contains(j) { rights.append(b[j]); j += 1; continue }
            flush()
            if i < a.count, j < b.count {
                rows.append(Row(id: rows.count, kind: .same, key: "", left: a[i], right: b[j]))
            }
            i += 1; j += 1
        }
        flush()
        return rows
    }
}
