import AppKit

/// Line numbers beside the editor's scroll view (outside it, so horizontally scrolled text is clipped at its edge,
/// as in VS Code). The active line's number is brighter; clicking or dragging selects whole lines.
final class EditorGutterView: NSView {
    private static let leftPadding: CGFloat = 14
    private static let rightPadding: CGFloat = 14

    private weak var textView: EditorTextView?
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private var textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var color = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var activeColor = NSColor.labelColor { didSet { needsDisplay = true } }
    private var digits = 0
    private(set) var thickness: CGFloat = 40
    private var dragAnchorLine: Int?

    init(textView: EditorTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    @objc private func redraw() { needsDisplay = true }

    func setFont(_ textFont: NSFont) {
        self.textFont = textFont
        font = NSFont.monospacedDigitSystemFont(ofSize: max(9, textFont.pointSize - 1), weight: .regular)
        digits = 0
        _ = updateThickness()
        needsDisplay = true
    }

    /// Recomputes the width for the current line count; true if it changed.
    func updateThickness() -> Bool {
        let count = textView?.lines.count ?? 1
        let d = max(String(count).count, 3)
        guard d != digits else { return false }
        digits = d
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        thickness = ceil(CGFloat(d) * digitWidth + Self.leftPadding + Self.rightPadding)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let lines = tv.lines
        let text = tv.nsString
        let origin = tv.textContainerOrigin
        let visible = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let activeLines = Set((tv.carets.isEmpty ? [tv.selectedRange()] : tv.carets.map(\.range)).map { lines.line(at: $0.location) })
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let active: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: activeColor]
        let baselineOffset = lm.defaultBaselineOffset(for: textFont)

        func drawNumber(_ line: Int, fragment: NSRect) {
            let baseline = fragment.minY + baselineOffset + origin.y
            let y = convert(NSPoint(x: 0, y: baseline), from: tv).y - font.ascender
            let label = String(line + 1) as NSString
            let attrs = activeLines.contains(line) ? active : normal
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - Self.rightPadding, y: y), withAttributes: attrs)
        }

        guard text.length > 0 else {
            drawNumber(0, fragment: lm.extraLineFragmentRect)
            return
        }
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = lines.line(at: chars.location)
        let lastChar = NSMaxRange(chars)
        while line < lines.count {
            let start = lines.start(ofLine: line)
            if start > lastChar { break }
            if start >= text.length {
                // The empty last line after a final line break.
                drawNumber(line, fragment: lm.extraLineFragmentRect)
                break
            }
            let glyph = lm.glyphIndexForCharacter(at: start)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            if fragment.minY > visible.maxY { break }
            drawNumber(line, fragment: fragment)
            line += 1
        }
    }

    // MARK: - Selecting lines

    private func line(at event: NSEvent) -> Int? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let point = tv.convert(event.locationInWindow, from: nil)
        let y = point.y - tv.textContainerOrigin.y
        if tv.nsString.length == 0 { return 0 }
        if y >= lm.usedRect(for: tc).maxY { return tv.lines.count - 1 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc)
        return tv.lines.line(at: lm.characterIndexForGlyph(at: glyph))
    }

    private func select(from a: Int, to b: Int) {
        guard let tv = textView else { return }
        let range = tv.range(ofLines: min(a, b)...max(a, b))
        tv.setSelectedRange(range)
        tv.window?.makeFirstResponder(tv)
        tv.scrollRangeToVisible(NSRange(location: b >= a ? NSMaxRange(range) : range.location, length: 0))
    }

    override func mouseDown(with event: NSEvent) {
        guard let l = line(at: event), let tv = textView else { return }
        if event.modifierFlags.contains(.shift) {
            dragAnchorLine = tv.lines.line(at: tv.selectedRange().location)
        } else {
            dragAnchorLine = l
        }
        select(from: dragAnchorLine!, to: l)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchorLine, let l = line(at: event) else { return }
        select(from: anchor, to: l)
    }

    override func mouseUp(with event: NSEvent) { dragAnchorLine = nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
