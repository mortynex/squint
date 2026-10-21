import AppKit

/// Background view of the editor area, laid out from the top-left.
final class EditorRootView: NSView {
    var onLayout: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChange?() }
}

/// The editing area of a window: text view, line numbers, find widget and status bar. One per window; opening another
/// file replaces its contents (there are no tabs).
final class EditorViewController: NSViewController, NSTextViewDelegate {
    let textView = EditorTextView.make()
    let scrollView = NSScrollView()
    private(set) lazy var gutter = EditorGutterView(textView: textView, scrollView: scrollView)
    let statusBar = StatusBarView()
    let emptyView = EmptyEditorView()
    private(set) var findWidget: FindWidget?

    private var colorer: SyntaxColorer?
    private(set) var settings = Settings.load()
    private(set) var palette = Palette(ui: [:], isDark: false)
    private var options = Highlighter.Options()
    private(set) var language = Language.plainText
    /// A language picked by the user instead of the detected one.
    private(set) var languageOverride: String?
    var format = TextFormat() { didSet { updateDirty(); updateStatus() } }
    private var savedFormat = TextFormat()
    private var savedText: NSString = ""
    private(set) var isDirty = false
    private(set) var hasDocument = false
    private(set) var fileName = ""
    private var undo = UndoManager()

    var fontZoom = 0 { didSet { if fontZoom != oldValue { applyFontAndTheme() } } }
    private(set) var wraps = false
    private(set) var showsLineNumbers = true

    var onDirtyChange: ((Bool) -> Void)?
    var onThemeChange: ((Palette) -> Void)?
    var onStatusItem: ((StatusBarView.Item, NSView) -> Void)?

    // Find state.
    private var findResult = FindModel.Result()
    private var findRefreshPending = false

    // MARK: - Lifecycle

    override func loadView() {
        let root = EditorRootView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layoutEditor() }
        root.onAppearanceChange = { [weak self] in self?.applyFontAndTheme() }
        view = root

        // Space below the last line acts as text (I-beam; a click or drag there starts at the end of the text).
        scrollView.contentView = TextClipView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        textView.delegate = self
        textView.onLinesChanged = { [weak self] change in self?.colorer?.edit(change) }
        root.addSubview(scrollView)
        root.addSubview(gutter)
        statusBar.onClick = { [weak self] item, button in self?.onStatusItem?(item, button) }
        root.addSubview(statusBar)
        root.addSubview(emptyView)

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .squintSettingsChanged, object: nil)
        wraps = settings.wrapLines
        showsLineNumbers = settings.lineNumbers
        applySettingsToTextView()
        applyFontAndTheme()
        showEmpty()
    }

    deinit {
        colorer?.close()
        NotificationCenter.default.removeObserver(self)
    }

    private func layoutEditor() {
        let b = view.bounds
        let statusH = StatusBarView.height
        let editorH = max(0, b.height - statusH)
        let gutterW = showsLineNumbers && hasDocument ? gutter.thickness : 0
        // The text starts below the title bar: AppKit has no scroll-edge effect to keep scrolled text readable there.
        let top = view.safeAreaInsets.top
        statusBar.frame = NSRect(x: 0, y: editorH, width: b.width, height: statusH)
        // An empty status bar would only add a stray hairline under the start page.
        statusBar.isHidden = !hasDocument
        gutter.frame = NSRect(x: 0, y: top, width: gutterW, height: max(0, editorH - top))
        gutter.isHidden = gutterW == 0
        scrollView.frame = NSRect(x: gutterW, y: top, width: max(0, b.width - gutterW), height: max(0, editorH - top))
        emptyView.frame = NSRect(x: 0, y: 0, width: b.width, height: hasDocument ? editorH : b.height)
        let content = scrollView.contentSize
        if !wraps { textView.minSize = NSSize(width: content.width, height: content.height) } else { textView.minSize = NSSize(width: 0, height: content.height) }
        if let widget = findWidget, !widget.isHidden {
            let width = min(FindWidget.width, b.width - 32)
            widget.frame = NSRect(x: b.width - width - 18, y: top + 8, width: width, height: widget.preferredHeight)
        }
    }

    // MARK: - Settings, theme and fonts

    @objc private func settingsChanged() {
        let old = settings
        settings = Settings.load()
        if settings.wrapLines != old.wrapLines { setWrapping(settings.wrapLines) }
        if settings.lineNumbers != old.lineNumbers { showsLineNumbers = settings.lineNumbers; view.needsLayout = true }
        applySettingsToTextView()
        applyFontAndTheme()
    }

    private func applySettingsToTextView() {
        textView.autoClosing = settings.autoClosingBrackets
        textView.highlightsCurrentLine = settings.highlightCurrentLine
        textView.showsIndentGuides = settings.indentGuides
        textView.setWrapping(wraps)
        scrollView.hasHorizontalScroller = !wraps
    }

    var font: NSFont {
        let size = CGFloat(max(6, min(64, settings.fontSize + fontZoom)))
        if !settings.fontFamily.isEmpty, let f = NSFontManager.shared.font(withFamily: settings.fontFamily, traits: [], weight: 5, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let f = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = round(f.pointSize * 0.4)
        paragraph.tabStops = []
        paragraph.defaultTabInterval = textView.spaceWidth * CGFloat(textView.tabWidth)
        return [.font: f, .foregroundColor: palette.fg, .paragraphStyle: paragraph]
    }

    var isDark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private static var themeCache: [String: Highlighter.DocumentInfo] = [:]

    /// Re-reads the theme for the current appearance and re-renders the text.
    func applyFontAndTheme() {
        options = settings.options(dark: isDark)
        options.transparent = false
        let key = "\(options.dark)|\(options.light)|\(options.darkTheme)"
        let info = Self.themeCache[key] ?? EditorEngine.highlighter.openDocument(id: 0, text: "", language: "", options: options)
        if let info { Self.themeCache[key] = info }
        palette = Palette(ui: info?.ui ?? [:], isDark: info?.dark ?? options.dark)
        view.layer?.backgroundColor = settings.glassWindow ? NSColor.clear.cgColor : palette.bg.cgColor
        textView.setFont(font)
        textView.palette = palette
        gutter.setFont(font)
        gutter.color = palette.gutter
        gutter.activeColor = palette.lineNumberActive
        statusBar.apply(textColor: palette.fg.withAlphaComponent(0.7), separatorColor: palette.fg.withAlphaComponent(0.08))
        emptyView.apply(palette: palette)
        if let widget = findWidget { widget.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua) }
        onThemeChange?(palette)
        if hasDocument { restyle() }
        view.needsLayout = true
    }

    /// Re-applies base attributes to the whole text and re-tokenizes it (theme, font or language changed).
    private func restyle() {
        guard let storage = textView.textStorage else { return }
        let attrs = baseAttributes
        SyntaxColorer.clear(textView)
        storage.beginEditing()
        storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = attrs
        openColorer()
    }

    private func openColorer() {
        colorer?.close()
        colorer = nil
        guard !language.id.isEmpty else { return }
        colorer = SyntaxColorer(textView: textView, language: language.id, options: options, fonts: SyntaxColorer.Fonts(font))
        colorer?.tokenize(budget: 40)
    }

    /// Tokenizes the whole text synchronously (tests).
    func finishHighlighting() { colorer?.tokenizeAll() }

    func setWrapping(_ wrap: Bool) {
        wraps = wrap
        textView.setWrapping(wrap)
        scrollView.hasHorizontalScroller = !wrap
        view.needsLayout = true
    }

    func setLineNumbersVisible(_ visible: Bool) {
        showsLineNumbers = visible
        view.needsLayout = true
    }

    // MARK: - Documents

    /// Shows `text` for editing. `language` overrides detection.
    func load(text: String, name: String, format: TextFormat, language: String? = nil) {
        colorer?.close()
        colorer = nil
        hasDocument = true
        emptyView.isHidden = true
        scrollView.isHidden = false
        fileName = name
        languageOverride = language
        detectIndentation(text)
        let id = language ?? EditorEngine.highlighter.detectLanguage(name: name, code: text, options: options)
        self.language = Language(id: id)
        textView.language = self.language
        undo = UndoManager()
        textView.load(text: text, attributes: baseAttributes)
        savedText = text as NSString
        savedFormat = format
        self.format = format
        isDirty = false
        openColorer()
        _ = gutter.updateThickness()
        view.needsLayout = true
        if let widget = findWidget, !widget.isHidden { refreshFind(reveal: false) }
        updateStatus()
        gutter.needsDisplay = true
    }

    /// No file: the watermark with shortcuts (or a message, e.g. for binary files).
    func showEmpty(message: String? = nil) {
        colorer?.close()
        colorer = nil
        hasDocument = false
        fileName = ""
        textView.load(text: "", attributes: baseAttributes)
        savedText = ""
        setClean()
        emptyView.message = message
        emptyView.isHidden = false
        scrollView.isHidden = true
        hideFind()
        view.needsLayout = true
        updateStatus()
    }

    /// Changes the language (status bar or command).
    func setLanguage(_ id: String) {
        languageOverride = id
        language = Language(id: id)
        textView.language = language
        restyle()
        updateStatus()
    }

    var text: String { textView.string }

    func markSaved() {
        savedText = NSString(string: textView.string)
        savedFormat = format
        updateDirty()
    }

    /// Replaces the text with `text` from disk (reload after an external change), keeping the selection and scroll.
    func reload(text: String, format: TextFormat) {
        let sel = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        load(text: text, name: fileName, format: format, language: languageOverride)
        let length = textView.nsString.length
        textView.setSelectedRange(NSRange(location: min(sel.location, length), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The edited text is gone (no file shown): whoever shows the edited state must hear about it.
    private func setClean() {
        guard isDirty else { return }
        isDirty = false
        onDirtyChange?(false)
    }

    private func updateDirty() {
        let current = textView.nsString
        let dirty = hasDocument && (format != savedFormat || current.length != savedText.length || !current.isEqual(savedText))
        if dirty != isDirty {
            isDirty = dirty
            onDirtyChange?(dirty)
        }
    }

    // MARK: - Indentation

    private func detectIndentation(_ text: String) {
        textView.tabWidth = settings.tabSize
        textView.indentUnit = settings.insertSpaces ? String(repeating: " ", count: settings.tabSize) : "\t"
        guard settings.detectIndentation else { return }
        var tabs = 0, spaces = 0
        var deltas: [Int: Int] = [:]
        var previous = 0
        var count = 0
        text.enumerateLines { line, stop in
            count += 1
            if count > 10_000 { stop = true }
            var lead = 0
            var tab = false
            for c in line.utf8 {
                if c == 0x20 { lead += 1 } else if c == 0x09 { tab = true; break } else { break }
            }
            if tab { tabs += 1; return }
            guard line.contains(where: { !$0.isWhitespace }) else { return }
            if lead > 0 { spaces += 1 }
            let d = abs(lead - previous)
            if d >= 2 && d <= 8 { deltas[d, default: 0] += 1 }
            previous = lead
        }
        if tabs > spaces && tabs > 0 {
            textView.indentUnit = "\t"
        } else if spaces > 0, let best = deltas.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), best.value >= 2 {
            textView.tabWidth = best.key
            textView.indentUnit = String(repeating: " ", count: best.key)
        }
    }

    func setIndentation(spaces: Bool, size: Int) {
        textView.tabWidth = size
        textView.indentUnit = spaces ? String(repeating: " ", count: size) : "\t"
        if let storage = textView.textStorage, storage.length > 0 {
            let p = (baseAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
            storage.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: storage.length))
        }
        textView.typingAttributes = baseAttributes
        textView.needsDisplay = true
        updateStatus()
    }

    func redetectIndentation() {
        detectIndentation(text)
        setIndentation(spaces: textView.indentUnit != "\t", size: textView.tabWidth)
    }

    // MARK: - NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
        colorer?.tokenize()
        if gutter.updateThickness() { view.needsLayout = true }
        gutter.needsDisplay = true
        updateDirty()
        scheduleFindRefresh()
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        gutter.needsDisplay = true
        updateStatus()
    }

    // MARK: - Status bar

    func updateStatus() {
        guard hasDocument else {
            for item in StatusBarView.Item.allCases { statusBar.set(item, "") }
            return
        }
        let tv = textView
        let text = tv.nsString
        if tv.carets.count > 1 {
            let chars = tv.carets.reduce(0) { $0 + $1.range.length }
            statusBar.set(.position, "\(tv.carets.count) selections" + (chars > 0 ? " (\(chars) characters selected)" : ""))
        } else {
            let sel = tv.selectedRange()
            let line = tv.lines.line(at: sel.location)
            let start = tv.lines.start(ofLine: line)
            let column = tv.columns(of: text.substring(with: NSRange(location: start, length: max(0, min(sel.location, text.length) - start))))
            var s = "Ln \(line + 1), Col \(column + 1)"
            if sel.length > 0 { s += " (\(sel.length) selected)" }
            statusBar.set(.position, s)
        }
        statusBar.set(.indentation, tv.indentUnit == "\t" ? "Tab Size: \(tv.tabWidth)" : "Spaces: \(tv.tabWidth)")
        statusBar.set(.encoding, format.encoding.rawValue)
        statusBar.set(.lineEnding, format.lineEnding.rawValue)
        statusBar.set(.language, language.name)
    }

    // MARK: - Find

    var isFindVisible: Bool { findWidget.map { !$0.isHidden } ?? false }

    private func makeFindWidget() -> FindWidget {
        let widget = FindWidget(isDark: palette.isDark)
        widget.onChange = { [weak self] _ in self?.refreshFind(reveal: true) }
        widget.onNext = { [weak self] in self?.findNext() }
        widget.onPrevious = { [weak self] in self?.findPrevious() }
        widget.onClose = { [weak self] in self?.hideFind() }
        widget.onReplace = { [weak self] in self?.replaceCurrent() }
        widget.onReplaceAll = { [weak self] in self?.replaceAll() }
        widget.onSelectAll = { [weak self] in self?.selectAllMatches() }
        widget.onInSelection = { [weak self] on in self?.setFindInSelection(on) }
        widget.onReplaceVisibility = { [weak self] _ in self?.view.needsLayout = true }
        findWidget = widget
        view.addSubview(widget)
        return widget
    }

    /// ⌘F / ⌥⌘F. The query is seeded from the selection (or the word at the cursor), like VS Code.
    func showFind(replace: Bool = false) {
        guard hasDocument else { return }
        let widget = findWidget ?? makeFindWidget()
        widget.isHidden = false
        if replace { widget.setReplaceVisible(true) }
        let text = textView.nsString
        var seed = textView.selectedRange()
        if seed.length == 0 { seed = textView.selectionRange(forProposedRange: seed, granularity: .selectByWord) }
        if seed.length > 0, seed.length <= 200, !text.substring(with: seed).contains("\n"),
           !text.substring(with: seed).trimmingCharacters(in: .whitespaces).isEmpty {
            var q = widget.query
            q.text = text.substring(with: seed)
            widget.query = q
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        refreshFind(reveal: true)
        if replace { widget.focusReplace() } else { widget.focusFind() }
    }

    func hideFind() {
        guard let widget = findWidget, !widget.isHidden else { return }
        widget.isHidden = true
        textView.findMatches = []
        textView.findCurrent = -1
        textView.findScope = nil
        widget.inSelection = false
        view.window?.makeFirstResponder(textView)
    }

    /// Finds again; with `reveal`, selects the first match at or after the cursor.
    func refreshFind(reveal: Bool) {
        guard let widget = findWidget, !widget.isHidden else { return }
        let text = textView.nsString
        findResult = FindModel.matches(of: widget.query, in: text, range: textView.findScope)
        textView.findMatches = findResult.matches
        if findResult.matches.isEmpty {
            textView.findCurrent = -1
        } else {
            // The match containing the cursor, else the next one.
            let from = textView.selectedRange().location
            let index = findResult.matches.firstIndex { NSMaxRange($0) > from } ?? 0
            if reveal { select(match: index) } else { textView.findCurrent = findResult.matches.firstIndex(of: textView.selectedRange()) ?? -1 }
        }
        updateFindCounter()
    }

    private func updateFindCounter() {
        findWidget?.update(current: textView.findCurrent + 1, total: findResult.matches.count, truncated: findResult.truncated, error: findResult.error)
    }

    private func scheduleFindRefresh() {
        guard isFindVisible, !findRefreshPending else { return }
        findRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.findRefreshPending = false
            self?.refreshFind(reveal: false)
        }
    }

    private func select(match index: Int) {
        guard index >= 0, index < findResult.matches.count else { return }
        let range = findResult.matches[index]
        textView.findCurrent = index
        textView.setSelectedRange(range)
        reveal(range)
        updateFindCounter()
    }

    /// Scrolls `range` into view, centring it vertically when it is off screen.
    func reveal(_ range: NSRange) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(forCharacterRange: range)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        let topInset: CGFloat = 0
        var origin = clip.bounds.origin
        let margin: CGFloat = 30
        let findHeight = isFindVisible ? (findWidget?.preferredHeight ?? 0) + 12 : 0
        if rect.minY < visible.minY + findHeight + margin || rect.maxY > visible.maxY - margin {
            origin.y = rect.midY - (visible.height) / 2 - topInset / 2
        }
        if rect.minX < visible.minX || rect.maxX > visible.maxX {
            origin.x = max(0, rect.minX - visible.width / 3)
        }
        let maxY = max(-topInset, textView.frame.height - clip.bounds.height)
        origin.y = min(max(-topInset, origin.y), maxY)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func findNext() {
        if !isFindVisible { showFind(); return }
        guard !findResult.matches.isEmpty else { return }
        let sel = textView.selectedRange()
        let after = sel.length > 0 ? sel.location + 1 : sel.location
        let index = findResult.matches.firstIndex { $0.location >= after && $0 != sel } ?? 0
        select(match: index)
    }

    func findPrevious() {
        if !isFindVisible { showFind(); return }
        guard !findResult.matches.isEmpty else { return }
        let sel = textView.selectedRange()
        let index = findResult.matches.lastIndex { $0.location < sel.location } ?? findResult.matches.count - 1
        select(match: index)
    }

    func replaceCurrent() {
        guard let widget = findWidget, !findResult.matches.isEmpty else { return }
        let sel = textView.selectedRange()
        guard let index = findResult.matches.firstIndex(of: sel) else { findNext(); return }
        let text = textView.nsString
        let replacement = FindModel.replacement(for: sel, in: text, query: widget.query, with: widget.replaceText, preserveCase: widget.preserveCase)
        textView.replace(sel, with: replacement, select: NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        findResult = FindModel.matches(of: widget.query, in: textView.nsString, range: textView.findScope)
        textView.findMatches = findResult.matches
        if findResult.matches.isEmpty { textView.findCurrent = -1; updateFindCounter(); return }
        let caret = textView.selectedRange().location
        _ = index
        select(match: findResult.matches.firstIndex { $0.location >= caret } ?? 0)
    }

    @discardableResult
    func replaceAll() -> Int {
        guard let widget = findWidget, !findResult.matches.isEmpty else { return 0 }
        let text = textView.nsString
        let matches = findResult.matches
        let query = widget.query
        let replacements = matches.map { FindModel.replacement(for: $0, in: text, query: query, with: widget.replaceText, preserveCase: widget.preserveCase) }
        textView.replace(ranges: matches, with: replacements)
        refreshFind(reveal: false)
        statusBar.show(message: "Replaced \(matches.count) occurrence\(matches.count == 1 ? "" : "s")")
        return matches.count
    }

    /// ⌥↩ in the find field: a cursor on every match.
    func selectAllMatches() {
        guard !findResult.matches.isEmpty else { return }
        let carets = findResult.matches.map { EditorTextView.Caret($0) }
        view.window?.makeFirstResponder(textView)
        textView.setCarets(carets, primary: 0)
        updateStatus()
    }

    func setFindInSelection(_ on: Bool) {
        if on {
            var sel = textView.selectedRange()
            if let current = findResult.matches.first(where: { $0 == sel }), textView.findScope == nil, current.length > 0 {
                // The selection is just the current match: use the lines around it instead.
                sel = textView.range(ofLines: textView.selectedLines)
            }
            textView.findScope = sel.length > 0 ? sel : textView.range(ofLines: textView.selectedLines)
        } else {
            textView.findScope = nil
        }
        findWidget?.inSelection = on
        refreshFind(reveal: false)
    }

    func toggleFindOption(_ keyPath: KeyPath<FindWidget, OptionToggle>) {
        if !isFindVisible { showFind() }
        guard let widget = findWidget else { return }
        widget[keyPath: keyPath].isOn.toggle()
        refreshFind(reveal: true)
    }

    var findCounterText: String { findWidget?.counterText ?? "" }
}

/// Shown when no file is open: a quiet start page with the actions that matter and the recent folders and files, like
/// Xcode's or Zed's. With a `message` (a file that could not be opened) it shows that instead.
final class EmptyEditorView: NSView {
    private struct Action {
        let title, symbol, shortcut: String
        let selector: Selector
    }
    private static let goToFile = Action(title: "Go to File…", symbol: "magnifyingglass", shortcut: "⌘P", selector: #selector(EditorWindowController.goToFile(_:)))
    private static let newFile = Action(title: "New File", symbol: "square.and.pencil", shortcut: "⌘N", selector: #selector(EditorWindowController.newDocument(_:)))
    private static let openFile = Action(title: "Open File…", symbol: "doc", shortcut: "⌘O", selector: #selector(AppDelegate.openDocument(_:)))
    private static let openFolder = Action(title: "Open Folder…", symbol: "folder", shortcut: "⌃⌘O", selector: #selector(AppDelegate.openFolderPanel(_:)))
    private static let maxRecents = 5

    private let stack = NSStackView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let openFolderButton = NSButton(title: EmptyEditorView.openFolder.title, target: nil, action: nil)
    private let actions = NSStackView()
    private let recents = NSStackView()
    private let recentsHeader = NSTextField(labelWithString: "Recent")
    private var contentWidth: NSLayoutConstraint!
    private var centerY: NSLayoutConstraint!
    private var palette = Palette(ui: [:], isDark: false)
    private var keyObserver: NSObjectProtocol?

    var message: String? { didSet { rebuild() } }
    /// The window shows a folder: Go to File instead of the Open Folder button, and no recents.
    var hasFolder = false { didSet { if hasFolder != oldValue { rebuild() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.stringValue = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "Version \($0)" } ?? ""
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        openFolderButton.image = NSImage(systemSymbolName: Self.openFolder.symbol, accessibilityDescription: nil)
        openFolderButton.imagePosition = .imageLeading
        openFolderButton.bezelStyle = .push
        openFolderButton.controlSize = .large
        openFolderButton.keyEquivalent = ""
        openFolderButton.toolTip = "\(Self.openFolder.title) (\(Self.openFolder.shortcut))"
        openFolderButton.action = Self.openFolder.selector
        if #available(macOS 26.0, *) { openFolderButton.bezelStyle = .glass }

        for list in [actions, recents] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 1
        }
        recentsHeader.font = .systemFont(ofSize: 11, weight: .semibold)

        for v in [icon, titleLabel, versionLabel, messageLabel, openFolderButton, actions, recents] as [NSView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(26, after: versionLabel)
        stack.setCustomSpacing(26, after: messageLabel)
        stack.setCustomSpacing(18, after: openFolderButton)
        stack.setCustomSpacing(24, after: actions)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        contentWidth = actions.widthAnchor.constraint(equalToConstant: 340)
        centerY = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            contentWidth,
            recents.widthAnchor.constraint(equalTo: actions.widthAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        // Another window may have opened something since: keep the recents current.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, !self.isHidden, self.message == nil, !self.hasFolder else { return }
            self.rebuild()
        }
        fit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    func apply(palette: Palette) {
        self.palette = palette
        // Controls follow the theme, not the system appearance.
        appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        titleLabel.textColor = palette.fg.withAlphaComponent(message == nil ? 0.85 : 0.75)
        versionLabel.textColor = palette.fg.withAlphaComponent(0.4)
        messageLabel.textColor = palette.fg.withAlphaComponent(0.55)
        recentsHeader.textColor = palette.fg.withAlphaComponent(0.45)
        if message != nil { icon.contentTintColor = palette.fg.withAlphaComponent(0.25) }
        for case let row as WelcomeRow in actions.arrangedSubviews + recents.arrangedSubviews { row.apply(palette: palette) }
    }

    /// Fills the page for the current state.
    private func rebuild() {
        let welcome = message == nil
        if let message {
            // "name\n\ndetails" from the window controller: the name as the title.
            let parts = message.components(separatedBy: "\n\n")
            titleLabel.stringValue = parts.count > 1 ? parts[0] : ""
            messageLabel.stringValue = parts.count > 1 ? parts.dropFirst().joined(separator: "\n\n") : message
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 40, weight: .light))
        } else {
            titleLabel.stringValue = "Squint"
            titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
            icon.image = NSApp.applicationIconImage
            icon.contentTintColor = nil
        }
        titleLabel.isHidden = titleLabel.stringValue.isEmpty
        messageLabel.isHidden = welcome
        openFolderButton.isHidden = !welcome || hasFolder
        actions.isHidden = !welcome

        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = hasFolder ? [Self.goToFile, Self.newFile, Self.openFile, Self.openFolder] : [Self.newFile, Self.openFile]
        for action in list {
            let row = WelcomeRow(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), title: action.title,
                                 detail: action.shortcut, isShortcut: true) { [weak self] in
                NSApp.sendAction(action.selector, to: nil, from: self)
            }
            add(row, to: actions)
        }

        recents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if welcome && !hasFolder {
            let fm = FileManager.default
            let urls = NSDocumentController.shared.recentDocumentURLs.filter { fm.fileExists(atPath: $0.path) }.prefix(Self.maxRecents)
            if !urls.isEmpty {
                let header = NSView()
                recentsHeader.translatesAutoresizingMaskIntoConstraints = false
                header.addSubview(recentsHeader)
                NSLayoutConstraint.activate([
                    recentsHeader.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
                    recentsHeader.topAnchor.constraint(equalTo: header.topAnchor),
                    recentsHeader.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
                ])
                recents.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: recents.widthAnchor).isActive = true
                for url in urls {
                    let image = NSWorkspace.shared.icon(forFile: url.path)
                    image.size = NSSize(width: 16, height: 16)
                    let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    let row = WelcomeRow(image: image, title: url.lastPathComponent, detail: parent, isShortcut: false) {
                        (NSApp.delegate as? AppDelegate)?.open([url])
                    }
                    row.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
                    add(row, to: recents)
                }
            }
        }
        apply(palette: palette)
        fit()
    }

    private func add(_ row: WelcomeRow, to list: NSStackView) {
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    /// Sizes the content to the view and drops the least important parts (recents, version, icon) while it does not
    /// fit the height.
    private func fit() {
        let width = max(120, bounds.width - 48)
        contentWidth.constant = min(340, width)
        messageLabel.preferredMaxLayoutWidth = min(420, width)
        // Centred in the area below the title bar, a little above the middle.
        let top = window == nil ? 0 : safeAreaInsets.top
        centerY.constant = top / 2 - 12
        let welcome = message == nil
        let optional: [(NSView, Bool)] = [(recents, welcome && !recents.arrangedSubviews.isEmpty),
                                          (versionLabel, welcome && !versionLabel.stringValue.isEmpty), (icon, true)]
        for (v, wanted) in optional { v.isHidden = !wanted }
        let available = bounds.height - top - 24
        for (v, _) in optional where !v.isHidden {
            spaceTitle()
            if stack.fittingSize.height > available { v.isHidden = true }
        }
        spaceTitle()
    }

    /// The version sits right under the title; without it, the title keeps its distance from what follows.
    private func spaceTitle() {
        stack.setCustomSpacing(!versionLabel.isHidden ? 2 : message != nil ? 6 : 22, after: titleLabel)
    }
}

/// A clickable line of the start page: an icon, a title and a shortcut (or a path) on the right, highlighted on hover.
private final class WelcomeRow: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let isShortcut: Bool
    private let onClick: () -> Void
    private var tracking: NSTrackingArea?
    private var hoverColor = NSColor.clear
    private var pressColor = NSColor.clear
    private var hovering = false { didSet { updateBackground() } }
    private var pressed = false { didSet { updateBackground() } }

    init(image: NSImage?, title: String, detail: String, isShortcut: Bool, onClick: @escaping () -> Void) {
        self.isShortcut = isShortcut
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        iconView.image = image
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.stringValue = detail
        detailLabel.font = isShortcut ? .systemFont(ofSize: 12) : .systemFont(ofSize: 11.5)
        // Paths keep both ends (~/Developer/…/App/Editor).
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.alignment = .right
        // Shortcuts never truncate; for recents the name wins over the path.
        titleLabel.setContentCompressionResistancePriority(isShortcut ? .defaultLow : .defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(isShortcut ? .required : .defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for v in [iconView, titleLabel, detailLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(palette: Palette) {
        iconView.contentTintColor = palette.fg.withAlphaComponent(0.55)
        titleLabel.textColor = palette.fg.withAlphaComponent(0.85)
        detailLabel.textColor = palette.fg.withAlphaComponent(isShortcut ? 0.4 : 0.38)
        hoverColor = palette.fg.withAlphaComponent(0.07)
        pressColor = palette.fg.withAlphaComponent(0.13)
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = (pressed ? pressColor : hovering ? hoverColor : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(tracking!)
    }

    /// The whole row is the button, not its labels.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick() }
    }

    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}
