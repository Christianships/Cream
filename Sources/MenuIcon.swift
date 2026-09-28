import AppKit

/// The menu bar icon: the app icon's keycap as an outline (skirt, top face,
/// and the front edges), drawn as a template image so macOS renders it white
/// on a dark menu bar and black on a light one.
enum MenuIcon {
    static let keycap: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Cream"
        return img
    }()

    /// Draws into the current context, in an 18pt box with y down.
    static func draw() {
        // Same shape as Icon/make-icon.swift, scaled into the box.
        let k: CGFloat = 15.4 / 612
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 206) * k + 1.3, y: (y - 262) * k + 2.1) }
        let top = [p(322, 262), p(702, 262), p(722, 540), p(302, 540)]
        let frontL = p(206, 806), frontR = p(818, 806)
        let backL = p(232, 300), backR = p(792, 300)

        func rounded(_ pts: [CGPoint], _ r: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            let n = pts.count
            path.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
            for i in 0..<n { path.appendArc(from: pts[i], to: pts[(i + 1) % n], radius: r) }
            path.close()
            return path
        }

        NSColor.black.setStroke()
        let body = rounded([backL, top[0], top[1], backR, frontR, frontL], 1.8)
        body.lineWidth = 1.4
        body.lineJoinStyle = .round
        body.stroke()

        let face = rounded(top, 1.3)
        NSColor.black.withAlphaComponent(0.3).setFill()
        face.fill()
        face.lineWidth = 1.2
        face.stroke()

        // The front edges, where the skirt turns into the sides.
        let edges = NSBezierPath()
        edges.move(to: top[3]); edges.line(to: CGPoint(x: frontL.x + 0.6, y: frontL.y - 0.4))
        edges.move(to: top[2]); edges.line(to: CGPoint(x: frontR.x - 0.6, y: frontR.y - 0.4))
        edges.lineWidth = 1
        edges.lineCapStyle = .round
        edges.stroke()
    }
}
