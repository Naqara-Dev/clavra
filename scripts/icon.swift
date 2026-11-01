// Draws Clavra's app icon: a brass key on a warm ink tile, no gradients or glow.
// swift scripts/icon.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon_1024.png"
let size = args.count > 2 ? CGFloat(Double(args[2]) ?? 1024) : 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let px = Int(size)
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)
// Work top-down like a design tool.
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

// The tile, on Apple's 824-point grid inside the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1A191D))
ctx.fillPath()
// Hairline edge.
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(4)
ctx.strokePath()

let brass = color(0xD8B46C)
ctx.setFillColor(brass)
ctx.setStrokeColor(brass)

// The bow: a ring.
let center = CGPoint(x: 372, y: 512)
ctx.setLineWidth(66)
ctx.addEllipse(in: CGRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236))
ctx.strokePath()

// The blade.
let blade = CGRect(x: center.x + 140, y: center.y - 31, width: 270, height: 62)
ctx.addPath(CGPath(roundedRect: blade, cornerWidth: 31, cornerHeight: 31, transform: nil))
ctx.fillPath()
// Two teeth, different lengths, square-ish with soft corners.
for (x, depth) in [(CGFloat(640), CGFloat(92)), (CGFloat(718), CGFloat(66))] {
    let tooth = CGRect(x: x, y: center.y, width: 52, height: depth + 31)
    ctx.addPath(CGPath(roundedRect: tooth, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.fillPath()
}
// Where bow meets blade.
ctx.fill(CGRect(x: center.x + 120, y: center.y - 31, width: 40, height: 62))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
