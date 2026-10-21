import AppKit

/// The read-only code preview: a scrollable highlighted text view with line numbers, used in Quick Look and in the
/// settings window's preview. (Editing happens in the app's editor windows.)
final class PreviewRootView: NSView {
    enum Mode {
        /// Inside Quick Look.
        case quickLook
        /// Display only (settings preview).
        case embedded
    }

    /// What the preview says about the file besides its text, outside the text itself.
    enum Notice {
        /// Only the start of the file is shown: a bar below the text says how much and, when `editorOpensAll`, opens
        /// the whole file in the editor.
        case truncated(shownBytes: Int, totalBytes: Int, editorOpensAll: Bool)
        /// There's no text to show (a binary or unreadable file): a message takes the text view's place.
        case unavailable(title: String, detail: String)
    }

    private let scrollView = NSScrollView()
    private let clipView = TextClipView()
    private let textView = PreviewTextView(usingTextLayoutManager: false)
    private let backdrop: NSView?
    private var gutter: LineNumberGutterView?
    private let palette: Palette
    private let mode: Mode
    private let wraps: Bool
    private var cursorMonitor: Any?
    private var draggingSelection = false
    private var editButton: NSView?
    private var noticeBar: NSView?
    private var noticeBarWidth: CGFloat = 0
    private let onOpenInEditor: (() -> Void)?

    private static let editButtonSize: CGFloat = 28
    private static let editButtonMargin: CGFloat = 10
    private static let noticeBarHeight: CGFloat = 24
    private static let noticeBarMargin: CGFloat = 8

    /// `onOpenInEditor`, when given, adds a small "Open in Squint" button in the top-right corner that calls it.
    init(frame: NSRect, text: String, result: Highlighter.Result?, options: Highlighter.Options, mode: Mode,
         notice: Notice? = nil, onOpenInEditor: (() -> Void)? = nil) {
        self.onOpenInEditor = onOpenInEditor
        palette = Palette(ui: result?.ui ?? [:], isDark: result?.dark ?? options.dark)
        self.mode = mode
        wraps = options.wrap
        if options.transparent {
            backdrop = nil
        } else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = palette.bg.cgColor
            backdrop = v
        }
        super.init(frame: frame)
        appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.masksToBounds = true
        // Quick Look only passes a click to the preview where the preview has drawn something; elsewhere it keeps the
        // click for its own panel. A transparent preview would then ignore clicks below the text, so it gets an
        // invisible background.
        if backdrop == nil { layer?.backgroundColor = NSColor(white: 0, alpha: 1 / 255).cgColor }

        let font = Self.font(options)
        let layoutManager = SelectionLayoutManager()
        layoutManager.lineEndWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        textView.textContainer?.replaceLayoutManager(layoutManager)
        textView.textStorage?.setAttributedString(Self.attributedText(text, result: result, palette: palette, font: font, options: options))
        configureTextView(options: options)
        configureScrollView(options: options, font: font)

        if let backdrop { addSubview(backdrop) }
        if case .unavailable(let title, let detail) = notice {
            addMessage(title: title, detail: detail)
        } else {
            addSubview(scrollView)
            if let gutter { addSubview(gutter) }
        }
        if case .truncated(let shownBytes, let totalBytes, let editorOpensAll) = notice {
            addNoticeBar(shownBytes: shownBytes, totalBytes: totalBytes, editorOpensAll: editorOpensAll)
        }
        if onOpenInEditor != nil { addEditButton() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let monitor = cursorMonitor { NSEvent.removeMonitor(monitor) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The theme's editor background, for windows that should blend with the content.
    var themeBackground: NSColor { palette.bg }

    // MARK: - Construction

    private static func font(_ options: Highlighter.Options, bold: Bool = false) -> NSFont {
        let size = CGFloat(options.fontSize)
        if !options.fontFamily.isEmpty,
           let base = NSFontManager.shared.font(withFamily: options.fontFamily, traits: [], weight: 5, size: size) {
            return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        }
        return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private static func attributedText(_ text: String, result: Highlighter.Result?, palette: Palette, font: NSFont, options: Highlighter.Options) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = font.pointSize * 0.4
        paragraph.defaultTabInterval = font.maximumAdvancement.width * 4
        paragraph.tabStops = []
        if options.wrap { paragraph.lineBreakMode = .byWordWrapping }
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.fg, .paragraphStyle: paragraph])
        guard let result else { return out }
        let colors = result.colors.map { NSColor(cssHex: $0) ?? palette.fg }
        let bold = Self.font(options, bold: true)
        let length = out.length
        out.beginEditing()
        var i = 0
        while i + 3 < result.spans.count {
            let start = result.spans[i], len = result.spans[i + 1], ci = result.spans[i + 2], style = result.spans[i + 3]
            i += 4
            guard start >= 0, start + len <= length else { continue }
            var attrs: [NSAttributedString.Key: Any] = [:]
            if ci >= 0 { attrs[.foregroundColor] = colors[ci] }
            if style & 2 != 0 { attrs[.font] = bold }
            if style & 1 != 0 { attrs[.obliqueness] = 0.2 }
            if style & 4 != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style & 8 != 0 { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.addAttributes(attrs, range: NSRange(location: start, length: len))
        }
        out.endEditing()
        return out
    }

    private func configureTextView(options: Highlighter.Options) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFindBar = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 6, height: 12)
        textView.selectedTextAttributes = [.backgroundColor: palette.selection]
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if options.wrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func configureScrollView(options: Highlighter.Options, font: NSFont) {
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !options.wrap
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        if options.lineNumbers {
            gutter = LineNumberGutterView(scrollView: scrollView, textView: textView, font: font, color: palette.gutter)
        }
    }

    private func addEditButton() {
        let button = FirstMouseButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Open in Squint")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.contentTintColor = palette.fg.withAlphaComponent(0.75)
        button.toolTip = "Open in Squint"
        button.target = self
        button.action = #selector(openInEditor)
        let size = Self.editButtonSize
        let panel = Glass.panel(content: button, cornerRadius: size / 2)
        panel.frame.size = NSSize(width: size, height: size)
        button.frame = panel.bounds
        button.autoresizingMask = [.width, .height]
        addSubview(panel)
        editButton = panel
        textView.cursorExclusion = panel
        clipView.cursorExclusion = panel
        // The text view's cursor rects leave out the button's spot in its visible rect, which scrolling moves.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(invalidateTextCursorRects),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    /// A quiet centred message in place of the text; not selectable, as it isn't the file's content.
    private func addMessage(title: String, detail: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = palette.fg.withAlphaComponent(0.85)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = palette.fg.withAlphaComponent(0.6)
        detailLabel.alignment = .center
        detailLabel.isSelectable = false
        detailLabel.preferredMaxLayoutWidth = 360
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    /// A glass pill below the text saying how much of the file is shown. It's a button rather than a label because
    /// Quick Look's tooltips and hover don't work: when the editor can show the whole file, a click opens it there.
    private func addNoticeBar(shownBytes: Int, totalBytes: Int, editorOpensAll: Bool) {
        func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        let font = NSFont.systemFont(ofSize: 11)
        let title = NSMutableAttributedString(string: "Showing the first \(size(shownBytes)) of \(size(totalBytes))",
                                              attributes: [.font: font, .foregroundColor: palette.fg.withAlphaComponent(0.75)])
        let button = FirstMouseButton()
        button.isBordered = false
        if editorOpensAll && onOpenInEditor != nil {
            title.append(NSAttributedString(string: " · Open in Squint to see all of it", attributes: [.font: font, .foregroundColor: palette.focus]))
            button.target = self
            button.action = #selector(openInEditor)
        }
        button.attributedTitle = title
        button.lineBreakMode = .byTruncatingTail
        let height = Self.noticeBarHeight
        let panel = Glass.panel(content: button, cornerRadius: height / 2)
        noticeBarWidth = ceil(button.intrinsicContentSize.width) + height
        panel.frame.size = NSSize(width: noticeBarWidth, height: height)
        button.frame = panel.bounds
        button.autoresizingMask = [.width, .height]
        addSubview(panel)
        noticeBar = panel
    }

    @objc private func openInEditor() { onOpenInEditor?() }

    @objc private func invalidateTextCursorRects() {
        window?.invalidateCursorRects(for: textView)
        window?.invalidateCursorRects(for: clipView)
    }

    override func layout() {
        super.layout()
        if let editButton {
            let m = Self.editButtonMargin
            editButton.frame.origin = NSPoint(x: bounds.width - editButton.frame.width - m, y: m)
            invalidateTextCursorRects()
        }
        backdrop?.frame = bounds
        // The notice bar gets its own strip below the text rather than covering the last lines.
        var textHeight = bounds.height
        if let noticeBar {
            let m = Self.noticeBarMargin, height = noticeBar.frame.height
            let width = max(0, min(noticeBarWidth, bounds.width - 2 * m))
            noticeBar.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - m - height, width: width, height: height)
            textHeight = max(0, bounds.height - height - 2 * m)
        }
        let gutterWidth = gutter?.thickness ?? 0
        gutter?.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: textHeight)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: textHeight)
        // The text view fills the visible area even when the text is shorter or narrower, so the space below the last
        // line is still text (the clip view covers any strip AppKit leaves anyway).
        let content = scrollView.contentSize
        let minSize = NSSize(width: wraps ? 0 : content.width, height: content.height)
        if textView.minSize != minSize {
            textView.minSize = minSize
            textView.sizeToFit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = cursorMonitor { NSEvent.removeMonitor(monitor); cursorMonitor = nil }
        guard window != nil else { return }
        if mode != .quickLook { window?.makeFirstResponder(textView) }
        // The window server sometimes shows the arrow over the text view (also while dragging a selection, when
        // AppKit's own cursor still is the I-beam), so the I-beam is re-asserted on every move and drag.
        cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.updateCursor(for: event)
            return event
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Makes AppKit deliver mouse-moved events (also in Quick Look, whose window is never key) for the monitor above.
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {}

    private func updateCursor(for event: NSEvent) {
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown: draggingSelection = isOverText(event)
        case .leftMouseUp: draggingSelection = false
        default: break
        }
        if draggingSelection || isOverText(event) { NSCursor.iBeam.set() }
        else if let hit = hitView(event), [editButton, noticeBar].contains(where: { $0.map(hit.isDescendant) ?? false }) { NSCursor.arrow.set() }
    }

    /// Over the text view, or the part of its clip view it doesn't cover (which acts as text, see TextClipView).
    private func isOverText(_ event: NSEvent) -> Bool {
        let hit = hitView(event)
        return hit === textView || hit === clipView
    }

    private func hitView(_ event: NSEvent) -> NSView? {
        guard let frameView = window?.contentView?.superview else { return nil }
        return frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
    }
}

/// Adds I-beam cursor rects to `view` over `rect` minus `hole` (as up to four bands around it). Returns false when the
/// hole misses `rect`, so the caller can keep its default cursor rects.
private func addIBeamRects(to view: NSView, in r: NSRect, excluding hole: NSRect?) -> Bool {
    guard let hole = hole?.intersection(r), !hole.isEmpty else { return false }
    let bands = [NSRect(x: r.minX, y: r.minY, width: r.width, height: hole.minY - r.minY),
                 NSRect(x: r.minX, y: hole.maxY, width: r.width, height: r.maxY - hole.maxY),
                 NSRect(x: r.minX, y: hole.minY, width: hole.minX - r.minX, height: hole.height),
                 NSRect(x: hole.maxX, y: hole.minY, width: r.maxX - hole.maxX, height: hole.height)]
    for band in bands where band.width > 0 && band.height > 0 { view.addCursorRect(band, cursor: .iBeam) }
    return true
}

/// The clip view of a code view: whatever part of it the text view doesn't cover (below a short text, or a strip AppKit
/// leaves when it sizes the text view) still belongs to the text, as in VS Code. It shows the I-beam, and a click or drag
/// there goes to the text view, which puts points past the text at its end: the click lands on the last line's last
/// character, and a drag selects from there.
final class TextClipView: NSClipView {
    /// A view floating over the text (the preview's edit button) that keeps its own cursor.
    weak var cursorExclusion: NSView?

    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? NSTextView else { return super.mouseDown(with: event) }
        if textView.acceptsFirstResponder, window?.firstResponder !== textView { window?.makeFirstResponder(textView) }
        textView.mouseDown(with: event)
    }

    override func resetCursorRects() {
        guard (documentView as? NSTextView)?.isSelectable == true else { return super.resetCursorRects() }
        let hole = cursorExclusion.flatMap { v in v.window === window && !v.isHidden ? convert(v.bounds, from: v) : nil }
        if !addIBeamRects(to: self, in: bounds, excluding: hole) { addCursorRect(bounds, cursor: .iBeam) }
    }
}

/// The preview's text view, which leaves `cursorExclusion` (the edit button floating over it) out of its I-beam:
/// cursor rects overlapping the button's are undefined, and Quick Look's remote view host applies the text view's.
private final class PreviewTextView: NSTextView {
    weak var cursorExclusion: NSView?

    private var exclusionRect: NSRect? {
        guard let v = cursorExclusion, v.window === window, !v.isHidden else { return nil }
        return convert(v.bounds, from: v)
    }

    private func isOverExclusion(_ event: NSEvent) -> Bool {
        exclusionRect?.contains(convert(event.locationInWindow, from: nil)) ?? false
    }

    override func resetCursorRects() {
        if !addIBeamRects(to: self, in: visibleRect, excluding: exclusionRect) { super.resetCursorRects() }
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverExclusion(event) { NSCursor.arrow.set() } else { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverExclusion(event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }
}

/// A button that also reacts to the click that would otherwise only activate its window (Quick Look's is never key),
/// and shows the arrow rather than the I-beam of the text view it floats over.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Draws selection (and find-match) backgrounds only behind the selected characters, like VS Code, instead of across
/// the whole line fragment: a selected line ending adds one space's width rather than running to the container's edge.
/// The rects are pixel-aligned, so deselecting never leaves an antialiased sliver of highlight behind.
final class SelectionLayoutManager: NSLayoutManager {
    var lineEndWidth: CGFloat = 0
    /// Replaces AppKit's grey selection colour while the text view isn't focused (the editor uses the theme's).
    var inactiveSelectionColor: NSColor?

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        var color = color
        if let inactive = inactiveSelectionColor,
           color == .unemphasizedSelectedTextBackgroundColor || color == .secondarySelectedControlColor || color == .unemphasizedSelectedContentBackgroundColor {
            color = inactive
        }
        guard rectCount > 0, let tc = textContainers.first, let tv = tc.textView, let text = textStorage?.string as NSString? else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        let origin = tv.textContainerOrigin
        var area = rectArray[0]
        for i in 1..<rectCount { area = area.union(rectArray[i]) }
        // Only the line fragments AppKit asked to fill, so huge selections stay cheap to draw.
        let first = glyphIndex(for: NSPoint(x: 0, y: area.minY - origin.y), in: tc)
        var lastLine = NSRange()
        lineFragmentRect(forGlyphAt: glyphIndex(for: NSPoint(x: 0, y: area.maxY - origin.y - 0.5), in: tc), effectiveRange: &lastLine)
        let visible = NSRange(location: first, length: max(0, NSMaxRange(lastLine) - first))
        let selected = NSIntersectionRange(glyphRange(forCharacterRange: charRange, actualCharacterRange: nil), visible)
        guard selected.length > 0 else { return }

        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: selected) { frag, _, _, lineGlyphs, _ in
            let sel = NSIntersectionRange(lineGlyphs, selected)
            guard sel.length > 0 else { return }
            // Trailing line-break glyphs are drawn as an extra space-wide block, as VS Code does.
            var end = NSMaxRange(sel)
            while end > sel.location, Self.isLineBreak(text.character(at: self.characterIndexForGlyph(at: end - 1))) { end -= 1 }
            let minX = self.location(forGlyphAt: sel.location).x
            var maxX = end < NSMaxRange(lineGlyphs) ? self.location(forGlyphAt: end).x : self.lineFragmentUsedRect(forGlyphAt: sel.location, effectiveRange: nil).maxX - frag.minX - tc.lineFragmentPadding
            if end < NSMaxRange(sel) { maxX += self.lineEndWidth }
            guard maxX > minX else { return }
            let rect = NSRect(x: frag.minX + minX + origin.x, y: frag.minY + origin.y, width: maxX - minX, height: frag.height)
            rects.append(tv.backingAlignedRect(rect, options: .alignAllEdgesNearest))
        }
        guard !rects.isEmpty else { return }
        super.fillBackgroundRectArray(rects, count: rects.count, forCharacterRange: charRange, color: color)
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 }
}
