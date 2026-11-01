// Draws Clavra's app icon: a terminal card with the three place colours in its title bar, and a
// brass key lying across its corner. swift scripts/icon.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon_1024.png"
let size = args.count > 2 ? CGFloat(Double(args[2]) ?? 1024) : 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let px = Int(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, _ c: CGColor) {
    ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath()
}

/// Two flat tones, lighter above: depth without a glow.
func vertical(_ path: CGPath, top: UInt32, bottom: UInt32, in rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()
}

func shadow(_ blur: CGFloat, y: CGFloat, alpha: CGFloat) {
    // Flipped context: a positive y offset in user space reads as "down" here.
    ctx.setShadow(offset: CGSize(width: 0, height: -y * size / 1024), blur: blur * size / 1024, color: color(0x000000, alpha))
}

// Tile.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 186)
ctx.saveGState()
shadow(28, y: 12, alpha: 0.35)
fill(tilePath, color(0x1A191D))
ctx.restoreGState()
vertical(tilePath, top: 0x232127, bottom: 0x161519, in: tile)

/// The key, drawn around the bow's centre, pointing along +x with the teeth below.
func key(at origin: CGPoint, angle: CGFloat, scale: CGFloat) {
    func place(_ dy: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: origin.x, y: origin.y + dy).rotated(by: angle).scaledBy(x: scale, y: scale)
    }
    func shape(_ dy: CGFloat) -> CGPath {
        var t = place(dy)
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: -128, y: -128, width: 256, height: 256), transform: t)
        p.addPath(rounded(CGRect(x: 100, y: -34, width: 330, height: 68), 34), transform: t)
        p.addPath(rounded(CGRect(x: 300, y: 0, width: 50, height: 112), 16), transform: t)
        p.addPath(rounded(CGRect(x: 370, y: 0, width: 46, height: 84), 16), transform: t)
        t = .identity
        return p
    }
    func hole(_ dy: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -64, y: -64, width: 128, height: 128), transform: [place(dy)])
    }
    ctx.saveGState()
    shadow(30, y: 18, alpha: 0.45)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // Bottom up: the key's thickness, a thin lit top edge, then the face slightly lower.
    fill(shape(12 * scale), color(0x9C772C))
    fill(shape(0), color(0xF1D9A4))
    fill(shape(5 * scale), color(0xD8B46C))
    ctx.setBlendMode(.clear)
    for dy in [0, 5 * scale, 12 * scale] { ctx.addPath(hole(dy)); ctx.fillPath() }
    ctx.setBlendMode(.normal)
    // Through the ring you see its far inner wall.
    ctx.saveGState()
    ctx.addPath(hole(5 * scale)); ctx.clip()
    ctx.addPath(hole(12 * scale)); ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024)); ctx.clip(using: .evenOdd)
    ctx.setFillColor(color(0x9C772C)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// Terminal card, a little raised.
let card = CGRect(x: 196, y: 228, width: 632, height: 470)
let cardPath = rounded(card, 64)
ctx.saveGState()
shadow(36, y: 16, alpha: 0.4)
fill(cardPath, color(0x2B292F))
ctx.restoreGState()
vertical(cardPath, top: 0x323037, bottom: 0x28262C, in: card)
ctx.addPath(rounded(card.insetBy(dx: 1.5, dy: 1.5), 62.5)); ctx.setStrokeColor(color(0xFFFFFF, 0.09)); ctx.setLineWidth(3); ctx.strokePath()
// Title bar: the three place colours instead of traffic lights.
for (i, hex) in [UInt32(0xE2857A), 0x8FB3DC, 0x93C7A6].enumerated() {
    ctx.addEllipse(in: CGRect(x: card.minX + 52 + CGFloat(i) * 46, y: card.minY + 44, width: 26, height: 26))
    ctx.setFillColor(color(hex)); ctx.fillPath()
}
ctx.setFillColor(color(0xFFFFFF, 0.06)); ctx.fill(CGRect(x: card.minX, y: card.minY + 110, width: card.width, height: 3))
// Prompt: a brass chevron and a paper cursor.
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: 262, y: 186 + 0 + 200)); chevron.addLine(to: CGPoint(x: 318, y: 228 + 200)); chevron.addLine(to: CGPoint(x: 262, y: 270 + 200))
ctx.addPath(chevron); ctx.setStrokeColor(color(0xD8B46C)); ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
fill(rounded(CGRect(x: 352, y: 392, width: 58, height: 76), 8), color(0xECEBE6))
// Faint lines of output.
for (i, w) in [CGFloat(300), 220].enumerated() {
    fill(rounded(CGRect(x: 262, y: 512 + CGFloat(i) * 52, width: w, height: 22), 11), color(0xFFFFFF, 0.10))
}
// The key, crossing the card's lower right corner.
key(at: CGPoint(x: 512, y: 716), angle: -.pi / 7, scale: 0.8)

// Hairline edge on the tile.
ctx.addPath(rounded(tile.insetBy(dx: 2, dy: 2), 184)); ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(4); ctx.strokePath()

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
