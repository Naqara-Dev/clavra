import Foundation

/// Places reached by typing them (`deploy@10.0.1.12:2222`) or through an `ssh://` link, without
/// saving them as hosts. Home lists them under Recent; ↑ in the field brings them back.
@MainActor @Observable
final class QuickHistory {
    static let limit = 12
    private(set) var targets: [String] = []

    init() {
        targets = UserDefaults.standard.stringArray(forKey: "QuickHistory") ?? []
    }

    /// Moves `target` to the front.
    func record(_ target: String) {
        let clean = target.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        targets.removeAll { $0 == clean }
        targets.insert(clean, at: 0)
        if targets.count > Self.limit { targets.removeLast(targets.count - Self.limit) }
        persist()
    }

    func remove(_ target: String) {
        targets.removeAll { $0 == target }
        persist()
    }

    func matching(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return targets }
        return targets.filter { $0.lowercased().contains(q) && $0.lowercased() != q }
    }

    private func persist() {
        UserDefaults.standard.set(targets, forKey: "QuickHistory")
    }
}
