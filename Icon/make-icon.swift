// Draws the app icon: a white mechanical-keyboard keycap on a black tile, seen
// from the front and a little above: dished top face, tall front skirt, and
// slim sloped sides, lit from the top left.
// Usage: swift Icon/make-icon.swift Icon/AppIcon.iconset && iconutil -c icns Icon/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon/AppIcon.iconset")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }
func gradient(_ stops: [(CGFloat, CGFloat)], alpha: CGFloat = 1) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { gray($0.0, alpha) } as CFArray, locations: stops.map { $0.1 })!
}

/// A closed polygon with every corner rounded by `r`.
func rounded(_ pts: [CGPoint], _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n = pts.count
    let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    p.move(to: mid(pts[n - 1], pts[0]))
    for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: r) }
    p.closeSubpath()
    return p
}

// Keycap geometry in the 1024 grid, y down. The top face is a trapezoid (a
// little wider at the front); the skirt flares out from it to the base.
let top = [CGPoint(x: 322, y: 262), CGPoint(x: 702, y: 262), CGPoint(x: 722, y: 540), CGPoint(x: 302, y: 540)]
let baseFront = [CGPoint(x: 206, y: 806), CGPoint(x: 818, y: 806)]     // front bottom edge
let baseBack = [CGPoint(x: 232, y: 300), CGPoint(x: 792, y: 300)]      // back bottom corners (hidden behind the top)
let silhouette = [baseBack[0], top[0], top[1], baseBack[1], baseFront[1], baseFront[0]]
let front = [top[3], top[2], baseFront[1], baseFront[0]]
let left = [baseBack[0], top[0], top[3], baseFront[0]]
let right = [top[1], baseBack[1], baseFront[1], top[2]]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 1024, y: -s / 1024)

    // Black tile on the macOS icon grid. (Shadow offsets ignore the flipped CTM: down is negative.)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: gray(0, 0.4))
    ctx.addPath(tile); ctx.setFillColor(gray(0.04)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient([(0.13, 0), (0.03, 1)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // A soft pool of light on the "desk" under the key.
    let pool = CGGradient(colorsSpace: space, colors: [gray(1, 0.1), gray(1, 0)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 812); ctx.scaleBy(x: 1, y: 0.28)
    ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 420, options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    let r: CGFloat = 46
    let body = rounded(silhouette, 70)
    // Contact shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: gray(0, 0.7))
    ctx.addPath(body); ctx.setFillColor(gray(0.9)); ctx.fillPath()
    ctx.restoreGState()

    // Skirt faces, clipped to the rounded silhouette so the corners stay soft.
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    for (face, shade) in [(left, (0.97, 0.88)), (right, (0.84, 0.74)), (front, (0.93, 0.84))] {
        ctx.saveGState()
        ctx.addPath(rounded(face, 8)); ctx.clip()
        ctx.drawLinearGradient(gradient([(shade.0, 0), (shade.1, 1)]),
                               start: CGPoint(x: 512, y: 262), end: CGPoint(x: 512, y: 806), options: [])
        ctx.restoreGState()
    }
    // Soft highlight along the front skirt, and seams where the faces meet.
    ctx.setStrokeColor(gray(1, 0.18)); ctx.setLineWidth(6); ctx.setLineCap(.round)
    for (a, b) in [(top[3], baseFront[0]), (top[2], baseFront[1])] { ctx.move(to: a); ctx.addLine(to: b) }
    ctx.strokePath()
    ctx.restoreGState()

    // Top face with a cylindrical dish: shaded at the back, brightest near the front lip.
    let face = rounded(top, r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: gray(0, 0.25))
    ctx.addPath(face); ctx.setFillColor(gray(0.97)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(face); ctx.clip()
    ctx.drawLinearGradient(gradient([(0.86, 0), (0.95, 0.3), (1, 0.78), (0.93, 1)]),
                           start: CGPoint(x: 512, y: 262), end: CGPoint(x: 512, y: 540), options: [])
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [gray(1, 0.35), gray(1, 0), gray(0, 0), gray(0, 0.08)] as CFArray,
                                      locations: [0, 0.3, 0.7, 1])!,
                           start: CGPoint(x: 302, y: 400), end: CGPoint(x: 722, y: 400), options: [])
    ctx.restoreGState()
    ctx.addPath(face); ctx.setStrokeColor(gray(1, 0.9)); ctx.setLineWidth(3); ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
