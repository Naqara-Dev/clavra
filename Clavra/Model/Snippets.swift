import Foundation

/// A command you run often, typed into the front terminal from ⌘;.
struct Snippet: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    /// Press Return after typing it. Off leaves the command on the line to finish by hand.
    var runs = true
}

@MainActor @Observable
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    private var file: URL { Library.dataFolder.appending(path: "snippets.json") }

    init() {
        reload()
        if snippets.isEmpty, Library.load([Snippet].self, from: file) == nil {
            snippets = Self.starters
        }
    }

    func reload() {
        if let saved = Library.load([Snippet].self, from: file), saved != snippets { snippets = saved }
    }

    func merge(_ others: [Snippet]) {
        let new = others.filter { other in !snippets.contains { $0.id == other.id } }
        guard !new.isEmpty else { return }
        snippets += new
        persist()
    }

    func save(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet } else { snippets.append(snippet) }
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    func matching(_ query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return snippets }
        return snippets.filter { $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q) }
    }

    private func persist() {
        Library.save(snippets, to: file)
    }

    /// A few everyday ones so the list isn't empty the first time.
    private static let starters = [
        Snippet(name: "Disk space", command: "df -h"),
        Snippet(name: "Biggest folders here", command: "du -sh * 2>/dev/null | sort -h | tail -n 15"),
        Snippet(name: "What's listening", command: "ss -ltnp 2>/dev/null || netstat -ltn"),
        Snippet(name: "Follow the system log", command: "journalctl -f -n 50"),
        Snippet(name: "Running containers", command: "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"),
    ]
}
