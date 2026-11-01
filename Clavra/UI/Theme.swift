import AppKit
import SwiftTerm
import SwiftUI

/// Warm ink in the dark, paper in the light, one brass accent. Depth comes from small steps in
/// lightness and hairlines, never from glows or gradients.
enum Theme {
    static let window = tone(dark: 0x141316, light: 0xF3F1EC)
    static let sidebar = tone(dark: 0x19181C, light: 0xEBE8E1)
    static let card = tone(dark: 0x211F24, light: 0xFBFAF7)
    static let cardHover = tone(dark: 0x28262B, light: 0xFFFFFF)
    static let field = tone(dark: 0x1D1C20, light: 0xFFFFFF)
    static let line = tone(dark: 0xFFFFFF, darkAlpha: 0.07, light: 0x1C1B1F, lightAlpha: 0.09)

    static let ink = tone(dark: 0xECEBE6, light: 0x1D1C20)
    static let secondary = tone(dark: 0xA29E97, light: 0x68645D)
    static let tertiary = tone(dark: 0x6F6B66, light: 0x9A958D)

    static let brass = tone(dark: 0xD8B46C, light: 0xA5802F)
    static let onBrass = tone(dark: 0x1D1810, light: 0xFFFFFF)

    static let terminal = SwiftUI.Color(nsColor: NSColor(hex: 0x121114))

    static func color(for place: Server.Place) -> SwiftUI.Color {
        switch place {
        case .personal: tone(dark: 0x93C7A6, light: 0x4F9467)
        case .staging: tone(dark: 0x8FB3DC, light: 0x4F7FB5)
        case .production: tone(dark: 0xE2857A, light: 0xC4594C)
        }
    }

    static let radius: CGFloat = 12

    private static func tone(dark: UInt32, darkAlpha: CGFloat = 1, light: UInt32, lightAlpha: CGFloat = 1) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The terminal keeps the dark ink in both appearances, with a soft ANSI palette to match.
enum TerminalStyle {
    private static let palette: [UInt32] = [
        0x2A282E, 0xE2857A, 0x93C7A6, 0xD8B46C, 0x8FB3DC, 0xC7A0D8, 0x8CCBC7, 0xD9D6CF,
        0x5A5660, 0xEE9A8F, 0xA9D9B9, 0xE6C68A, 0xA8C6E8, 0xD6B5E4, 0xA4DCD8, 0xF2EFE8,
    ]

    @MainActor
    static func apply(to view: TerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x121114)
        view.nativeForegroundColor = NSColor(hex: 0xE6E3DC)
        view.caretColor = NSColor(hex: 0xD8B46C)
        view.optionAsMetaKey = true
        view.installColors(palette.map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257, green: UInt16((hex >> 8) & 0xFF) * 257, blue: UInt16(hex & 0xFF) * 257)
        })
    }
}
