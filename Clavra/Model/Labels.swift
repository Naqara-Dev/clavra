import Foundation

/// A label the user made for hosts, next to Personal, Staging and Production: "Client A", "Lab".
struct HostLabel: Identifiable, Codable, Hashable, Sendable {
    /// The soft colours a label can wear, from the same family as the built-in ones.
    enum Tint: String, Codable, CaseIterable, Sendable {
        case sage, mist, coral, brass, lilac, teal, stone
    }

    var id = UUID()
    var name: String
    var tint: Tint = .lilac

    var place: Server.Place { Server.Place(rawValue: "label:\(id.uuidString)") }
}

/// The user's own labels, kept with the hosts (and synced with them through iCloud Drive).
@MainActor @Observable
final class LabelStore {
    static let shared = LabelStore()

    private(set) var labels: [HostLabel] = []
    private var file: URL { Library.dataFolder.appending(path: "labels.json") }

    init() {
        reload()
    }

    func reload() {
        if let saved = Library.load([HostLabel].self, from: file), saved != labels { labels = saved }
    }

    func label(for place: Server.Place) -> HostLabel? { labels.first { $0.place == place } }

    /// A place whose label was deleted (perhaps on another Mac) counts as Personal.
    func resolve(_ place: Server.Place) -> Server.Place {
        place.isBuiltIn || label(for: place) != nil ? place : .personal
    }

    /// Every place, in the order groups are shown: production, staging, the user's, personal.
    var order: [Server.Place] { [.production, .staging] + labels.map(\.place) + [.personal] }

    /// Every place, in the order the editor offers them.
    var choices: [Server.Place] { [.personal, .staging, .production] + labels.map(\.place) }

    func name(of place: Server.Place) -> String {
        switch resolve(place) {
        case .production: "Production"
        case .staging: "Staging"
        case .personal: "Personal"
        default: label(for: place)?.name ?? "Personal"
        }
    }

    @discardableResult
    func add(name: String, tint: HostLabel.Tint) -> HostLabel {
        let made = HostLabel(name: name.trimmingCharacters(in: .whitespaces), tint: tint)
        labels.append(made)
        Library.save(labels, to: file)
        return made
    }

    func save(_ label: HostLabel) {
        guard let index = labels.firstIndex(where: { $0.id == label.id }) else { return }
        labels[index] = label
        Library.save(labels, to: file)
    }

    func delete(_ label: HostLabel) {
        labels.removeAll { $0.id == label.id }
        Library.save(labels, to: file)
    }
}

extension Server.Place {
    /// "Production", or the name the user gave their label.
    @MainActor var label: String { LabelStore.shared.name(of: self) }
}
