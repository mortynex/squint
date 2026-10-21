import AppKit

/// Line-number gutter shown beside (not inside) a scroll view, so horizontally scrolled text is clipped at its edge
/// like in VS Code. It has no background, so a glass backdrop shows through.
final class LineNumberGutterView: NSView {
    private static let leftPadding: CGFloat = 10
    private static let rightPadding: CGFloat = 12

    private let font: NSFont
    private let textFont: NSFont
    private let color: NSColor
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    /// Width the gutter wants; the owner lays it out at this width.
    let thickness: CGFloat

    init(scrollView: NSScrollView, textView: NSTextView, font: NSFont, color: NSColor) {
        self.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        self.textFont = font
        self.color = color
        self.textView = textView
        let ns = textView.string as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { break }
            starts.append(r.upperBound)
            i = r.upperBound
        }
        lineStarts = starts
        let digits = max(String(starts.count).count, 2)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: self.font]).width
        thickness = ceil(CGFloat(digits) * digitWidth + Self.leftPadding + Self.rightPadding)
        super.init(frame: .zero)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(setNeedsRedraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func setNeedsRedraw() { needsDisplay = true }

    private func lineNumber(at charIndex: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let inset = tv.textContainerInset
        let visible = tv.visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let text = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var g = glyphs.location
        while g < NSMaxRange(glyphs) {
            let chars = lm.characterRange(forGlyphRange: NSRange(location: g, length: 1), actualGlyphRange: nil)
            let line = text.lineRange(for: NSRange(location: chars.location, length: 0))
            let firstGlyph = lm.glyphIndexForCharacter(at: line.location)
            let frag = lm.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            // Align the number's baseline with the first line fragment's baseline.
            let baseline = frag.minY + lm.defaultBaselineOffset(for: textFont) + inset.height
            let y = convert(NSPoint(x: 0, y: baseline), from: tv).y - font.ascender
            let label = String(lineNumber(at: line.location)) as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - Self.rightPadding, y: y), withAttributes: attrs)
            g = max(NSMaxRange(lm.glyphRange(forCharacterRange: line, actualCharacterRange: nil)), g + 1)
        }
    }
}
