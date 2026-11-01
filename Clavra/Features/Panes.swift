import Foundation

/// How a tab is cut up: one terminal, or terminals side by side or stacked, nested as deep as you
/// like. ⌘D splits beside, ⇧⌘D splits below, like iTerm.
indirect enum PaneNode: Equatable {
    enum Axis { case sideBySide, stacked }

    case leaf(UUID)
    case split(Axis, [PaneNode])

    /// Pane ids left to right, top to bottom.
    var ids: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, let children): children.flatMap(\.ids)
        }
    }

    /// Puts `new` next to `target`. Splitting along the axis a pane already sits in adds a sibling
    /// instead of nesting, so three side-by-side panes share the width evenly.
    func splitting(_ target: UUID, with new: UUID, along axis: Axis) -> PaneNode {
        switch self {
        case .leaf(let id):
            return id == target ? .split(axis, [.leaf(id), .leaf(new)]) : self
        case .split(let own, let children):
            if own == axis, let index = children.firstIndex(of: .leaf(target)) {
                var next = children
                next.insert(.leaf(new), at: index + 1)
                return .split(own, next)
            }
            return .split(own, children.map { $0.splitting(target, with: new, along: axis) })
        }
    }

    /// Without `target`; nil when nothing is left. A split left with one child becomes that child.
    func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let axis, let children):
            let rest = children.compactMap { $0.removing(target) }
            if rest.isEmpty { return nil }
            return rest.count == 1 ? rest[0] : .split(axis, rest)
        }
    }
}

/// One tab: its panes and which of them has the keyboard.
@MainActor @Observable
final class TabGroup: Identifiable {
    let id = UUID()
    var root: PaneNode
    var focused: UUID

    init(_ session: UUID) {
        root = .leaf(session)
        focused = session
    }

    var paneIDs: [UUID] { root.ids }
    var isSplit: Bool { paneIDs.count > 1 }

    /// The pane after (or before) the focused one, wrapping around.
    func neighbor(_ step: Int) -> UUID? {
        let ids = paneIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focused) else { return nil }
        return ids[(index + step + ids.count) % ids.count]
    }
}
