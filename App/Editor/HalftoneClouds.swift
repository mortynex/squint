import AppKit

/// Soft halftone clouds drawn over the window glass and under the editor, like the clouds on the app icon: a few
/// patches of round dots that grow toward each patch's middle. Drawn in the theme's text colour at low opacity, so they
/// read as a shade in the glass; the clouds that float free of the edges are half as strong. Never takes clicks.
final class HalftoneCloudsView: NSView {
    typealias Cloud = (x: CGFloat, y: CGFloat, r: CGFloat)
    /// Patch centres as fractions of the view (top-left origin) and radii in points, so they keep their size.
    private static let edgeClouds: [Cloud] = [(0.03, 0.93, 150), (0.95, 0.05, 130), (0.38, 0.99, 75)]
    private static let floatingClouds: [Cloud] = [(0.84, 0.72, 90), (0.62, 0.18, 55)]
    private static let cell: CGFloat = 6

    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    /// Height kept clear at the bottom (the editor's status bar), so the dots stop where the code does.
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bottomInset))
        for (clouds, strength) in [(Self.edgeClouds, 1.0), (Self.floatingClouds, 0.5)] {
            ctx.setFillColor(color.withAlphaComponent(color.alphaComponent * strength).cgColor)
            ctx.addPath(dots(in: dirtyRect, clouds: clouds))
            ctx.fillPath()
        }
    }

    /// One circle per grid cell, sized by the density of `clouds` there.
    private func dots(in rect: NSRect, clouds: [Cloud]) -> CGPath {
        let path = CGMutablePath()
        let cell = Self.cell
        let h = bounds.height
        let (x0, x1) = (Int(rect.minX / cell), Int(rect.maxX / cell) + 1)
        let (y0, y1) = (Int(rect.minY / cell), Int(rect.maxY / cell) + 1)
        for j in y0...y1 {
            for i in x0...x1 {
                let p = CGPoint(x: (CGFloat(i) + 0.5) * cell, y: (CGFloat(j) + 0.5) * cell)
                let d = density(at: p, height: h, clouds: clouds)
                guard d > 0.06 else { continue }
                let r = sqrt(d) * cell * 0.5
                path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        return path
    }

    /// 0…1: the strongest cloud at `p`, a gaussian lump roughened by noise so its outline isn't a circle.
    private func density(at p: CGPoint, height h: CGFloat, clouds: [Cloud]) -> CGFloat {
        var best: CGFloat = 0
        for c in clouds {
            let dx = p.x - c.x * bounds.width, dy = p.y - c.y * h
            let r = c.r
            best = max(best, exp(-(dx * dx + dy * dy) / (2 * r * r / 4)))
        }
        let n = Self.noise(p.x / 70, p.y / 70) * 0.65 + Self.noise(p.x / 28, p.y / 28) * 0.35
        return min(1, max(0, best * (0.15 + 1.5 * n) - 0.1))
    }

    /// Smooth value noise in 0…1.
    private static func noise(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let (ix, iy) = (floor(x), floor(y))
        let (fx, fy) = (x - ix, y - iy)
        let (u, v) = (fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy))
        func h(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let s = sin(a * 127.1 + b * 311.7) * 43758.5453
            return s - floor(s)
        }
        let top = h(ix, iy) + (h(ix + 1, iy) - h(ix, iy)) * u
        let bottom = h(ix, iy + 1) + (h(ix + 1, iy + 1) - h(ix, iy + 1)) * u
        return top + (bottom - top) * v
    }
}
