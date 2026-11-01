import Foundation
import SwiftTerm

/// A terminal's lines as rows of styled runs, for the phone page to draw: the screen, and the
/// scrollback above it.
/// A run is `[text, fg, bg, flags]`: colours are -1 for the default, 0–255 for the palette, or
/// "#rrggbb"; flags are SwiftTerm's style bits (bold 1, underline 2, inverse 8, dim 32, italic 64).
enum ScreenSnapshot {
    /// How many lines above the screen a phone can scroll back through.
    static let history = 500

    /// One terminal line as JSON runs.
    @MainActor
    static func render(_ line: BufferLine?, of term: Terminal) -> String {
        guard let line else { return "[]" }
        var runs: [[Any]] = []
        var text = ""
        var current: (fg: Any, bg: Any, flags: Int)?
        for x in 0..<min(term.cols, line.count) {
            let cell = line[x]
            if cell.width == 0 { continue }
            let style = (fg: color(cell.attribute.fg), bg: color(cell.attribute.bg), flags: Int(cell.attribute.style.rawValue))
            let character = term.getCharacter(for: cell)
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
        return String(decoding: data, as: UTF8.self)
    }

    /// The scroll-invariant number of the oldest line the terminal still keeps. Line numbers counted
    /// from it never change as output scrolls, so a phone is only sent lines it hasn't got.
    /// `hint` is the answer from last time; the number only grows, so the search starts there.
    @MainActor
    static func oldestLine(of term: Terminal, hint: Int) -> Int {
        let exists = { (row: Int) in row >= 0 && term.getScrollInvariantLine(row: row) != nil }
        if exists(0) { return 0 }
        var below: Int
        var above: Int
        if exists(hint) {
            // The kept lines start at or before the hint.
            if !exists(hint - 1) { return hint }
            below = 0
            above = hint - 1
        } else {
            // Further on: step by a screen (the terminal always keeps at least that many), then narrow.
            let step = max(term.rows, 1)
            var row = hint + step
            var tries = 0
            while !exists(row) {
                row += step
                tries += 1
                if tries > 2_000_000 { return hint }
            }
            below = row - step
            above = row
        }
        while above - below > 1 {
            let middle = (below + above) / 2
            if exists(middle) { above = middle } else { below = middle }
        }
        return above
    }

    /// Where the screen's top row sits in scroll-invariant numbers.
    @MainActor
    static func screenTop(of term: Terminal, oldest: Int) -> Int {
        // The line at the top of the screen, found among the kept lines near where it should be.
        guard let first = term.getLine(row: 0) else { return oldest }
        let guess = oldest + term.buffer.yDisp
        if term.getScrollInvariantLine(row: guess) === first { return guess }
        var row = oldest
        while let line = term.getScrollInvariantLine(row: row) {
            if line === first { return row }
            row += 1
        }
        return guess
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
