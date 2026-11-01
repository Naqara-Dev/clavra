import Foundation
import SwiftTerm

/// The visible screen of a terminal as rows of styled runs, for the phone page to draw.
/// A run is `[text, fg, bg, flags]`: colours are -1 for the default, 0–255 for the palette, or
/// "#rrggbb"; flags are SwiftTerm's style bits (bold 1, underline 2, inverse 8, dim 32, italic 64).
enum ScreenSnapshot {
    @MainActor
    static func rows(of view: TerminalView) -> (cols: Int, rows: [String], cursor: [Int]) {
        let term = view.getTerminal()
        var rows: [String] = []
        for y in 0..<term.rows {
            guard let line = term.getLine(row: y) else { rows.append("[]"); continue }
            var runs: [[Any]] = []
            var text = ""
            var current: (fg: Any, bg: Any, flags: Int)?
            for x in 0..<min(term.cols, line.count) {
                let cell = line[x]
                if cell.width == 0 { continue }
                let style = (fg: color(cell.attribute.fg), bg: color(cell.attribute.bg), flags: Int(cell.attribute.style.rawValue))
                let character = cell.getCharacter()
                if let open = current, same(open, style) {
                    text.append(character == "\u{0}" ? " " : character)
                } else {
                    if let open = current { runs.append([text, open.fg, open.bg, open.flags]) }
                    current = style
                    text = character == "\u{0}" ? " " : String(character)
                }
            }
            if let open = current {
                // Trailing plain spaces carry nothing.
                let trimmed = isPlain(open) ? String(text.reversed().drop(while: { $0 == " " }).reversed()) : text
                if !trimmed.isEmpty { runs.append([trimmed, open.fg, open.bg, open.flags]) }
            }
            let data = (try? JSONSerialization.data(withJSONObject: runs)) ?? Data("[]".utf8)
            rows.append(String(decoding: data, as: UTF8.self))
        }
        let cursor = term.getCursorLocation()
        return (term.cols, rows, [cursor.x, cursor.y])
    }

    private static func color(_ value: Attribute.Color) -> Any {
        switch value {
        case .ansi256(let code): Int(code)
        case .trueColor(let r, let g, let b): String(format: "#%02x%02x%02x", r, g, b)
        case .defaultColor, .defaultInvertedColor: -1
        }
    }

    private static func same(_ a: (fg: Any, bg: Any, flags: Int), _ b: (fg: Any, bg: Any, flags: Int)) -> Bool {
        a.flags == b.flags && "\(a.fg)" == "\(b.fg)" && "\(a.bg)" == "\(b.bg)"
    }

    private static func isPlain(_ style: (fg: Any, bg: Any, flags: Int)) -> Bool {
        "\(style.bg)" == "-1" && style.flags & 8 == 0
    }
}
