import AppKit
import SwiftTerm

/// Grey text after the cursor showing the rest of a suggestion. It lives inside the terminal view,
/// in the terminal's own font, so it sits exactly where the characters would.
@MainActor
final class GhostText {
    private let label: NSTextField

    init(in terminal: TerminalView) {
        label = NSTextField(labelWithString: "")
        label.textColor = NSColor(hex: 0x6F6B66)
        label.isHidden = true
        label.lineBreakMode = .byClipping
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        terminal.addSubview(label)
    }

    func show(_ text: String, column: Int, row: Int, in terminal: TerminalView) {
        let font = terminal.font
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        label.font = font
        label.stringValue = text
        let x = CGFloat(column) * width
        let y = terminal.frame.height - CGFloat(row + 1) * height
        let available = max(terminal.frame.width - x - 16, 0)
        // NSTextField adds a couple of points of inset; nudge it back onto the grid.
        label.frame = NSRect(x: x - 2, y: y, width: available, height: height)
        label.isHidden = text.isEmpty || available < width
    }

    func hide() {
        label.isHidden = true
        label.stringValue = ""
    }
}
