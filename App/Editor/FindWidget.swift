import AppKit

/// Flat icon button with a soft hover background.
final class IconButton: NSButton {
    private var tracking: NSTrackingArea?

    init(symbol: String, tooltip: String, pointSize: CGFloat = 12) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor } }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small on/off option inside a find field (Aa, ab, .*, AB) or an icon toggle.
final class OptionToggle: NSButton {
    var isOn = false { didSet { refresh() } }
    var onToggle: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false

    init(label: String, underline: Bool = false, tooltip: String) {
        super.init(frame: .zero)
        isBordered = false
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 5
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        title = label
        attributedTitle = NSAttributedString(string: label, attributes: attrs)
        target = self
        action = #selector(toggled)
        refresh()
    }

    init(symbol: String, tooltip: String) {
        super.init(frame: .zero)
        isBordered = false
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 6
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        target = self
        action = #selector(toggled)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggled() {
        isOn.toggle()
        onToggle?(isOn)
    }

    private func refresh() {
        let fg: NSColor = isOn ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.7)
        if let attributed = attributedTitle.mutableCopy() as? NSMutableAttributedString, attributed.length > 0 {
            attributed.addAttribute(.foregroundColor, value: fg, range: NSRange(location: 0, length: attributed.length))
            attributedTitle = attributed
        }
        contentTintColor = fg
        let bg: NSColor? = isOn ? NSColor.controlAccentColor.withAlphaComponent(0.2) : (hovering ? NSColor.labelColor.withAlphaComponent(0.1) : nil)
        layer?.backgroundColor = bg?.cgColor
        layer?.borderWidth = isOn ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FindField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// An input with a rounded background, a focus ring and option toggles on its right.
private final class InputBox: NSView {
    let field = FindField()
    var toggles: [OptionToggle] = []
    var focused = false { didSet { refreshBorder() } }
    var invalid = false { didSet { refreshBorder() } }

    init(placeholder: String, isDark: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.clear.cgColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        field.onFocusChange = { [weak self] in self?.focused = $0 }
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func add(_ toggle: OptionToggle) {
        toggles.append(toggle)
        addSubview(toggle)
    }

    private func refreshBorder() {
        let color: NSColor = invalid ? NSColor.systemRed.withAlphaComponent(0.8) : (focused ? NSColor.controlAccentColor.withAlphaComponent(0.8) : .clear)
        layer?.borderColor = color.cgColor
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size: CGFloat = 22
        var x = bounds.width - 4
        for t in toggles.reversed() {
            x -= size
            t.frame = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
            x -= 1
        }
        field.frame = NSRect(x: 8, y: (bounds.height - 18) / 2, width: max(20, x - 12), height: 18)
    }
}

/// VS Code's find widget on glass: find and replace inputs with match case / whole word / regex / preserve case,
/// an "n of m" counter, previous / next, find in selection and close.
final class FindWidget: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 520
    static let rowHeight: CGFloat = 38

    var onChange: ((FindQuery) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onInSelection: ((Bool) -> Void)?
    var onReplaceVisibility: ((Bool) -> Void)?

    private let content = FlippedView()
    private let glass: NSView
    private let findBox: InputBox
    private let replaceBox: InputBox
    private let expand = IconButton(symbol: "chevron.right", tooltip: "Toggle Replace (⌥⌘F)", pointSize: 11)
    private let counter = NSTextField(labelWithString: "")
    private let previous = IconButton(symbol: "arrow.up", tooltip: "Previous Match (⇧↩)")
    private let next = IconButton(symbol: "arrow.down", tooltip: "Next Match (↩)")
    private let inSelectionToggle = OptionToggle(symbol: "text.line.first.and.arrowtriangle.forward", tooltip: "Find in Selection (⌥⌘L)")
    private let close = IconButton(symbol: "xmark", tooltip: "Close (Esc)")
    private let replaceOne = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAll = NSButton(title: "All", target: nil, action: nil)
    let caseToggle = OptionToggle(label: "Aa", tooltip: "Match Case (⌥⌘C)")
    let wordToggle = OptionToggle(label: "ab", underline: true, tooltip: "Match Whole Word (⌥⌘W)")
    let regexToggle = OptionToggle(label: ".*", tooltip: "Use Regular Expression (⌥⌘R)")
    let preserveCaseToggle = OptionToggle(label: "AB", tooltip: "Preserve Case (⌥⌘P)")

    private(set) var showsReplace = false

    var query: FindQuery {
        get { FindQuery(text: findBox.field.stringValue, caseSensitive: caseToggle.isOn, wholeWord: wordToggle.isOn, regex: regexToggle.isOn) }
        set {
            findBox.field.stringValue = newValue.text
            caseToggle.isOn = newValue.caseSensitive
            wordToggle.isOn = newValue.wholeWord
            regexToggle.isOn = newValue.regex
        }
    }

    var replaceText: String {
        get { replaceBox.field.stringValue }
        set { replaceBox.field.stringValue = newValue }
    }

    var preserveCase: Bool { preserveCaseToggle.isOn }
    var inSelection: Bool {
        get { inSelectionToggle.isOn }
        set { inSelectionToggle.isOn = newValue }
    }

    var preferredHeight: CGFloat { showsReplace ? Self.rowHeight * 2 - 6 : Self.rowHeight }

    init(isDark: Bool) {
        findBox = InputBox(placeholder: "Find", isDark: isDark)
        replaceBox = InputBox(placeholder: "Replace", isDark: isDark)
        glass = Glass.panel(content: content, cornerRadius: 14)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight))
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDark ? 0.4 : 0.16
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        addSubview(glass)

        for t in [caseToggle, wordToggle, regexToggle] {
            t.onToggle = { [weak self] _ in self?.changed() }
            findBox.add(t)
        }
        preserveCaseToggle.onToggle = { [weak self] _ in self?.changed() }
        replaceBox.add(preserveCaseToggle)
        findBox.field.delegate = self
        replaceBox.field.delegate = self
        content.addSubview(findBox)
        content.addSubview(replaceBox)

        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .left
        counter.lineBreakMode = .byClipping
        content.addSubview(counter)

        expand.target = self
        expand.action = #selector(toggleReplace)
        content.addSubview(expand)
        for (button, action) in [(previous, #selector(previousTapped)), (next, #selector(nextTapped)), (close, #selector(closeTapped))] {
            button.target = self
            button.action = action
            content.addSubview(button)
        }
        inSelectionToggle.onToggle = { [weak self] on in self?.onInSelection?(on) }
        content.addSubview(inSelectionToggle)

        for (button, action, tip) in [(replaceOne, #selector(replaceTapped), "Replace (↩)"), (replaceAll, #selector(replaceAllTapped), "Replace All (⌘↩)")] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11.5, weight: .medium)
            button.target = self
            button.action = action
            button.toolTip = tip
            content.addSubview(button)
        }
        setReplaceVisible(false)
        update(current: 0, total: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func setReplaceVisible(_ visible: Bool) {
        showsReplace = visible
        replaceBox.isHidden = !visible
        replaceOne.isHidden = !visible
        replaceAll.isHidden = !visible
        expand.image = NSImage(systemSymbolName: visible ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        needsLayout = true
        onReplaceVisibility?(visible)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let rowH = Self.rowHeight - 6
        let button: CGFloat = 24
        expand.frame = NSRect(x: 6, y: (Self.rowHeight - button) / 2, width: 20, height: showsReplace ? bounds.height - (Self.rowHeight - button) : button)
        var x = bounds.width - 7
        for b in [close, inSelectionToggle, next, previous] as [NSView] {
            x -= button
            b.frame = NSRect(x: x, y: (Self.rowHeight - button) / 2, width: button, height: button)
            x -= 1
        }
        let counterW: CGFloat = 76
        x -= counterW + 2
        counter.frame = NSRect(x: x + 6, y: (Self.rowHeight - 16) / 2, width: counterW - 6, height: 16)
        let boxX: CGFloat = 30
        findBox.frame = NSRect(x: boxX, y: 6, width: max(80, x - boxX), height: rowH - 6)
        if showsReplace {
            let y = Self.rowHeight - 4
            let allW = replaceAll.intrinsicContentSize.width + 6
            let oneW = replaceOne.intrinsicContentSize.width + 6
            replaceAll.frame = NSRect(x: bounds.width - 9 - allW, y: y + (rowH - 6 - 20) / 2, width: allW, height: 20)
            replaceOne.frame = NSRect(x: replaceAll.frame.minX - 4 - oneW, y: replaceAll.frame.minY, width: oneW, height: 20)
            replaceBox.frame = NSRect(x: boxX, y: y, width: findBox.frame.width, height: rowH - 6)
        }
    }

    // MARK: - Focus and state

    func focusFind(selectAll: Bool = true) {
        window?.makeFirstResponder(findBox.field)
        if selectAll { findBox.field.currentEditor()?.selectAll(nil) }
    }

    func focusReplace() {
        window?.makeFirstResponder(replaceBox.field)
        replaceBox.field.currentEditor()?.selectAll(nil)
    }

    var isFindFieldFocused: Bool { findBox.focused }
    var isReplaceFieldFocused: Bool { replaceBox.focused }

    func update(current: Int, total: Int, truncated: Bool = false, error: String? = nil) {
        let q = findBox.field.stringValue
        findBox.invalid = error != nil || (total == 0 && !q.isEmpty)
        if let error { counter.stringValue = error == "Invalid regular expression" ? "Invalid" : error }
        else if q.isEmpty { counter.stringValue = "No results" }
        else if total == 0 { counter.stringValue = "No results" }
        else { counter.stringValue = "\(current == 0 ? "?" : String(current)) of \(total)\(truncated ? "+" : "")" }
        counter.textColor = (total == 0 && !q.isEmpty) || error != nil ? .systemRed : .secondaryLabelColor
        if q.isEmpty { counter.textColor = .tertiaryLabelColor }
        previous.isEnabled = total > 0
        next.isEnabled = total > 0
        replaceOne.isEnabled = total > 0
        replaceAll.isEnabled = total > 0
    }

    var counterText: String { counter.stringValue }

    private func changed() { onChange?(query) }

    // MARK: - Actions

    @objc private func toggleReplace() {
        setReplaceVisible(!showsReplace)
        if showsReplace { focusReplace() } else { focusFind(selectAll: false) }
    }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func replaceTapped() { onReplace?() }
    @objc private func replaceAllTapped() { onReplaceAll?() }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === findBox.field { changed() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76, findBox.focused || replaceBox.focused {
            if replaceBox.focused || showsReplace { onReplaceAll?() } else { onSelectAll?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let isReplace = control === replaceBox.field
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if isReplace { onReplace?() }
            else if flags.contains(.option) { onSelectAll?() }
            else if flags.contains(.shift) { onPrevious?() }
            else { onNext?() }
            return true
        case #selector(NSResponder.insertTab(_:)):
            if !isReplace && showsReplace { focusReplace(); return true }
            return false
        case #selector(NSResponder.insertBacktab(_:)):
            if isReplace { focusFind(); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
