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

    /// The side of a pane another one is dropped on.
    enum Edge { case left, right, top, bottom }

    /// Puts `new` next to `target`. Splitting along the axis a pane already sits in adds a sibling
    /// instead of nesting, so three side-by-side panes share the width evenly.
    func splitting(_ target: UUID, with new: UUID, along axis: Axis) -> PaneNode {
        inserting(new, beside: target, along: axis, before: false)
    }

    /// Takes pane `id` out and puts it on `edge` of `target`, the way iTerm moves a dragged pane.
    /// Nil when nothing would change.
    func moving(_ id: UUID, to target: UUID, edge: Edge) -> PaneNode? {
        guard id != target, ids.contains(id), ids.contains(target), let rest = removing(id) else { return nil }
        let axis: Axis = edge == .left || edge == .right ? .sideBySide : .stacked
        let moved = rest.inserting(id, beside: target, along: axis, before: edge == .left || edge == .top)
        return moved == self ? nil : moved
    }

    private func inserting(_ new: UUID, beside target: UUID, along axis: Axis, before: Bool) -> PaneNode {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(axis, before ? [.leaf(new), .leaf(id)] : [.leaf(id), .leaf(new)])
        case .split(let own, let children):
            if own == axis, let index = children.firstIndex(of: .leaf(target)) {
                var next = children
                next.insert(.leaf(new), at: before ? index : index + 1)
                return .split(own, next)
            }
            return .split(own, children.map { $0.inserting(new, beside: target, along: axis, before: before) })
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
