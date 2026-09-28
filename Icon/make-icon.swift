// Draws the app icon: a single cream keycap, seen from a little above the
// front: a sculpted skirt, a dished top and a "C" legend in the corner.
// Usage: swift Icon/make-icon.swift Icon/AppIcon.iconset && iconutil -c icns Icon/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon/AppIcon.iconset")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Drawn top-down in a 1024 grid.
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 1024, y: -s / 1024)

    // The skirt: the keycap's footprint on the macOS icon grid.
    let base = CGRect(x: 112, y: 120, width: 800, height: 790)
    let baseShape = CGPath(roundedRect: base, cornerWidth: 150, cornerHeight: 150, transform: nil)
    // The top face: narrower than the base (the sides slope in) and set back,
    // so the front of the skirt shows taller than the back.
    let top = CGRect(x: 222, y: 168, width: 580, height: 560)
    let topShape = CGPath(roundedRect: top, cornerWidth: 96, cornerHeight: 96, transform: nil)

    // Shadow on the "desk". (Shadow offsets ignore the flipped CTM, so down is negative.)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 40, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(baseShape); ctx.setFillColor(rgb(0xD9C7A5)); ctx.fillPath()
    ctx.restoreGState()

    // Skirt shading: light from above, so the back is brightest, the front
    // mid, and the left/right sides fall off towards their edges.
    ctx.saveGState()
    ctx.addPath(baseShape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xF3E7CF, 1, 0), (0xE4D2B0, 1, 0.55), (0xCDB58C, 1, 1)]),
                           start: CGPoint(x: 512, y: 120), end: CGPoint(x: 512, y: 910), options: [])
    ctx.drawLinearGradient(gradient([(0x8C7250, 0.28, 0), (0x8C7250, 0, 0.22), (0x8C7250, 0, 0.78), (0x8C7250, 0.34, 1)]),
                           start: CGPoint(x: 112, y: 500), end: CGPoint(x: 912, y: 500), options: [])
    // Corner seams where the sides meet, from each base corner towards the top face.
    ctx.setStrokeColor(rgb(0x9C8260, 0.28)); ctx.setLineWidth(5); ctx.setLineCap(.round)
    for (a, b) in [(CGPoint(x: 175, y: 180), CGPoint(x: 250, y: 196)), (CGPoint(x: 849, y: 180), CGPoint(x: 774, y: 196)),
                   (CGPoint(x: 172, y: 852), CGPoint(x: 252, y: 700)), (CGPoint(x: 852, y: 852), CGPoint(x: 772, y: 700))] {
        ctx.move(to: a); ctx.addLine(to: b)
    }
    ctx.strokePath()
    ctx.restoreGState()
    // A thin darker rim at the bottom edge of the skirt.
    ctx.addPath(baseShape); ctx.setStrokeColor(rgb(0xA88E68, 0.55)); ctx.setLineWidth(6); ctx.strokePath()

    // The top face, with a soft edge shadow where it meets the skirt.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x7A6242, 0.35))
    ctx.addPath(topShape); ctx.setFillColor(rgb(0xF6ECD8)); ctx.fillPath()
    ctx.restoreGState()
    // Cylindrical dish: darker at the back edge, brighter towards the front lip.
    ctx.saveGState()
    ctx.addPath(topShape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xE3D2B2, 1, 0), (0xF1E5CC, 1, 0.35), (0xFBF4E6, 1, 0.82), (0xEFE2C8, 1, 1)]),
                           start: CGPoint(x: 512, y: 168), end: CGPoint(x: 512, y: 728), options: [])
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.35, 0), (0xFFFFFF, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 520), endRadius: 300, options: [])
    ctx.restoreGState()
    ctx.addPath(topShape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(4); ctx.strokePath()

    // The legend, top left like an alpha key. Skipped where it'd be a smudge.
    if px >= 64 {
        let font = NSFont.systemFont(ofSize: 150, weight: .semibold)
        let attr = NSAttributedString(string: "C", attributes: [.font: font, .foregroundColor: NSColor(cgColor: rgb(0x6E5838))!])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 292, y: 368); ctx.scaleBy(x: 1, y: -1)    // text draws y-up
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
