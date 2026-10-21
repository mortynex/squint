import AppKit

/// The code editor's text view: VS Code-like editing behaviour on top of NSTextView (TextKit 1).
/// Line-based commands live in EditorCommands.swift, multiple cursors in MultiCursor.swift.
final class EditorTextView: NSTextView, NSTextStorageDelegate {
    // MARK: Configuration

    var palette = Palette(ui: [:], isDark: false) { didSet { applyPalette() } }
    var language = Language.plainText
    /// One level of indentation: a tab or some spaces.
    var indentUnit = "    "
    var tabWidth = 4 { didSet { updateTabStops() } }
    var autoClosing = true
    var highlightsCurrentLine = true
    var showsIndentGuides = true

    // MARK: State

    /// Line starts of the text, updated on every edit (before NSTextView's own observers run).
    private(set) var lines = LineIndex()
    /// Called after `lines` was updated for an edit.
    var onLinesChanged: ((LineIndex.Change) -> Void)?
    /// Positions of closing brackets/quotes the editor inserted itself; typing that character there steps over it.
    var autoClosed: [Int] = []
    /// All cursors when there are several (sorted, non-overlapping); empty with a single cursor.
    var carets: [Caret] = []
    var primaryCaret = 0
    var isApplyingCarets = false
    /// Set while a full-line copy (copy with an empty selection) is on the pasteboard.
    static let fullLinePasteboardType = NSPasteboard.PasteboardType("com.martin.squint.full-line")

    private var bracketPair: (Int, Int)?
    var spaceWidth: CGFloat = 7

    /// Find widget matches (sorted), the current one, and the "find in selection" scope.
    var findMatches: [NSRange] = [] { didSet { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) } }
    var findCurrent = -1 { didSet { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) } }
    var findScope: NSRange? { didSet { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) } }

    struct Caret: Equatable {
        var anchor: Int
        var head: Int
        init(_ anchor: Int, _ head: Int) { self.anchor = anchor; self.head = head }
        init(_ range: NSRange) { anchor = range.location; head = NSMaxRange(range) }
        var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
        var isEmpty: Bool { anchor == head }
    }

    // MARK: Setup

    static func make() -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = SelectionLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        storage.delegate = view
        return view
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        textContainerInset = NSSize(width: 4, height: 8)
        layoutManager?.allowsNonContiguousLayout = true
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setWrapping(_ wrap: Bool) {
        if wrap {
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            textContainer?.widthTracksTextView = true
            if let width = enclosingScrollView?.contentSize.width { frame.size.width = width }
            textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            isHorizontallyResizable = true
            autoresizingMask = []
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        (layoutManager as? SelectionLayoutManager)?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0), actualCharacterRange: nil)
        sizeToFit()
    }

    private func applyPalette() {
        insertionPointColor = palette.cursor
        selectedTextAttributes = [.backgroundColor: palette.selection]
        (layoutManager as? SelectionLayoutManager)?.inactiveSelectionColor = palette.selection.withAlphaComponent(palette.selection.alphaComponent * 0.6)
        needsDisplay = true
    }

    // MARK: - Dropping files opens them

    /// Files dropped on the editor are opened rather than inserted as text.
    var onOpenFiles: (([URL]) -> Void)?

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onOpenFiles != nil, !droppedFiles(sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onOpenFiles != nil, !droppedFiles(sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        if let onOpenFiles, !files.isEmpty { onOpenFiles(files); return true }
        return super.performDragOperation(sender)
    }

    func setFont(_ font: NSFont) {
        self.font = font
        spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        (layoutManager as? SelectionLayoutManager)?.lineEndWidth = spaceWidth
        updateTabStops()
    }

    private func updateTabStops() {
        guard let base = defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle ?? NSParagraphStyle.default.mutableCopy() as? NSMutableParagraphStyle else { return }
        base.tabStops = []
        base.defaultTabInterval = spaceWidth * CGFloat(tabWidth)
        defaultParagraphStyle = base
    }

    /// Replaces the whole text (a newly opened file): resets the line index, cursors and undo.
    func load(text: String, attributes: [NSAttributedString.Key: Any]) {
        carets = []
        autoClosed = []
        bracketPair = nil
        lines = LineIndex(text as NSString)
        SyntaxColorer.clear(self)
        textStorage?.delegate = nil
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textStorage?.delegate = self
        typingAttributes = attributes
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: 0, length: 0))
        scroll(.zero)
    }

    // MARK: - Edits

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let change = lines.update(edited: editedRange, delta: delta, text: textStorage.mutableString)
        // Keep remembered auto-closed positions in place; drop those inside the replaced text.
        let oldEnd = editedRange.location + editedRange.length - delta
        autoClosed = autoClosed.compactMap { p in
            if p < editedRange.location { return p }
            if p >= oldEnd { return p + delta }
            return nil
        }
        if var scope = findScope {
            if oldEnd <= scope.location { scope.location += delta }
            else if editedRange.location < NSMaxRange(scope) { scope.length = max(0, scope.length + delta) }
            findScope = scope
        }
        onLinesChanged?(change)
    }

    /// Replaces `range` with `string` as one undoable user edit and selects `selection` afterwards.
    func replace(_ range: NSRange, with string: String, select selection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        if let selection { setSelectedRange(selection) }
    }

    /// Several replacements as one undoable edit. Ranges must not overlap.
    func replace(ranges: [NSRange], with strings: [String]) {
        guard !ranges.isEmpty, shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings) else { return }
        let order = ranges.indices.sorted { ranges[$0].location > ranges[$1].location }
        textStorage?.beginEditing()
        for i in order { textStorage?.replaceCharacters(in: ranges[i], with: strings[i]) }
        textStorage?.endEditing()
        didChangeText()
    }

    /// The text without copying it (bridging NSTextStorage.string to a Swift String copies the whole buffer).
    var nsString: NSString { textStorage?.mutableString ?? "" }

    // MARK: - Typing

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]
    /// Auto-closing only happens before these (or at the end of a line), as in VS Code.
    private static let closeBefore = Set(";:.,=}])>` \t\n\"'")

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if !carets.isEmpty, replacementRange.location == NSNotFound, let s = (string as? String) ?? (string as? NSAttributedString)?.string {
            insertAtCarets(s)
            return
        }
        guard let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
              typed.count == 1, let ch = typed.first, replacementRange.location == NSNotFound, !hasMarkedText() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let sel = selectedRange()
        let text = nsString
        // Step over a closer this editor inserted.
        if sel.length == 0, Self.closers.contains(ch), sel.location < text.length,
           text.character(at: sel.location) == ch.utf16.first, let i = autoClosed.firstIndex(of: sel.location) {
            autoClosed.remove(at: i)
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }
        // Wrap a selection in brackets or quotes.
        if autoClosing, !language.id.isEmpty, sel.length > 0, let close = Self.pairs[ch] {
            let inner = text.substring(with: sel)
            replace(sel, with: "\(ch)\(inner)\(close)", select: NSRange(location: sel.location + 1, length: sel.length))
            return
        }
        // Closing bracket typed on a blank line: re-indent to its opening bracket's line.
        if sel.length == 0, "}])".contains(ch), let indent = indentForClosingBracket(ch, at: sel.location) {
            let lineStart = lines.start(ofLine: lines.line(at: sel.location))
            let lead = NSRange(location: lineStart, length: sel.location - lineStart)
            replace(lead, with: indent + String(ch), select: NSRange(location: lineStart + (indent as NSString).length + 1, length: 0))
            return
        }
        // Auto-close brackets and quotes: the pair is inserted as one edit, so one undo removes both.
        if autoClosing, !language.id.isEmpty, sel.length == 0, let close = Self.pairs[ch], shouldAutoClose(ch, at: sel.location) {
            replace(sel, with: "\(ch)\(close)", select: NSRange(location: sel.location + 1, length: 0))
            autoClosed.append(sel.location + 1)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    private func shouldAutoClose(_ ch: Character, at location: Int) -> Bool {
        let text = nsString
        if location < text.length, let next = UnicodeScalar(text.character(at: location)).map(Character.init), !Self.closeBefore.contains(next) { return false }
        guard ch == "\"" || ch == "'" || ch == "`" else { return true }
        // Not after a word character (an apostrophe, or the end of a string) or a backslash.
        if location > 0, let prev = UnicodeScalar(text.character(at: location - 1)),
           CharacterSet.alphanumerics.contains(prev) || prev == "\\" || prev == UnicodeScalar(UInt8(ch.asciiValue ?? 0)) { return false }
        if ch == "'" && ["markdown", "rust", "lisp", "common-lisp", "clojure", "scheme", "racket", "ocaml"].contains(language.id) { return false }
        return true
    }

    /// The indentation a closing bracket typed at `location` should get, if the line is blank up to there.
    private func indentForClosingBracket(_ ch: Character, at location: Int) -> String? {
        let text = nsString
        let lineStart = lines.start(ofLine: lines.line(at: location))
        guard location > lineStart else { return nil }
        let lead = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
        guard lead.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        guard let open = matchingBracket(forCloser: ch, before: lineStart) else { return nil }
        let indent = leadingWhitespace(ofLine: lines.line(at: open))
        return indent == lead ? nil : indent
    }

    func leadingWhitespace(ofLine line: Int) -> String {
        let text = nsString
        let range = lines.range(ofLine: line, length: text.length)
        var end = range.location
        while end < NSMaxRange(range), [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        return text.substring(with: NSRange(location: range.location, length: end - range.location))
    }

    /// Indentation width in columns (tabs advance to the next tab stop).
    func columns(of whitespace: String) -> Int {
        var col = 0
        for c in whitespace { col = c == "\t" ? (col / tabWidth + 1) * tabWidth : col + 1 }
        return col
    }

    override func insertNewline(_ sender: Any?) {
        if !carets.isEmpty { insertNewlineAtCarets(); return }
        let sel = selectedRange()
        let text = nsString
        let line = lines.line(at: sel.location)
        let lineStart = lines.start(ofLine: line)
        var indent = leadingWhitespace(ofLine: line)
        if (indent as NSString).length > sel.location - lineStart {
            indent = text.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        }
        let before = text.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
            .trimmingCharacters(in: .whitespaces)
        let afterIndex = NSMaxRange(sel)
        let next: unichar? = afterIndex < text.length ? text.character(at: afterIndex) : nil
        let last = before.last
        let opens = last.map { "{[(".contains($0) } ?? false
        let colonBlock = last == ":" && ["python", "yaml", "nim", "coffee"].contains(language.id)
        if opens, let next, let close = Self.pairs[last!], close.utf16.first == next {
            // Between brackets: put the closer on its own line.
            let insert = "\n" + indent + indentUnit + "\n" + indent
            replace(sel, with: insert, select: NSRange(location: sel.location + 1 + (indent as NSString).length + (indentUnit as NSString).length, length: 0))
        } else if opens || colonBlock {
            let insert = "\n" + indent + indentUnit
            replace(sel, with: insert, select: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        } else {
            let insert = "\n" + indent
            replace(sel, with: insert, select: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if !carets.isEmpty { insertAtCarets(indentUnit); return }
        let sel = selectedRange()
        if sel.length > 0, nsString.substring(with: sel).contains("\n") { indentLines(sender); return }
        if indentUnit == "\t" { insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0)); return }
        let lineStart = lines.start(ofLine: lines.line(at: sel.location))
        let col = columns(of: nsString.substring(with: NSRange(location: lineStart, length: sel.location - lineStart)))
        let count = tabWidth - col % tabWidth
        replace(sel, with: String(repeating: " ", count: count), select: NSRange(location: sel.location + count, length: 0))
    }

    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    override func deleteBackward(_ sender: Any?) {
        if !carets.isEmpty { deleteAtCarets(forward: false); return }
        let sel = selectedRange()
        let text = nsString
        if sel.length == 0, sel.location > 0, sel.location < text.length {
            // Delete an empty auto-closed pair at once.
            let prev = text.character(at: sel.location - 1), next = text.character(at: sel.location)
            if let p = UnicodeScalar(prev).map(Character.init), let close = Self.pairs[p], close.utf16.first == next, autoClosed.contains(sel.location) {
                replace(NSRange(location: sel.location - 1, length: 2), with: "", select: NSRange(location: sel.location - 1, length: 0))
                return
            }
        }
        if sel.length == 0, sel.location > 0, indentUnit != "\t" {
            // In leading spaces, delete back to the previous tab stop.
            let lineStart = lines.start(ofLine: lines.line(at: sel.location))
            let lead = text.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
            if !lead.isEmpty, lead.allSatisfy({ $0 == " " }) {
                let n = lead.count
                let remove = n % tabWidth == 0 ? tabWidth : n % tabWidth
                replace(NSRange(location: sel.location - remove, length: remove), with: "", select: NSRange(location: sel.location - remove, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if !carets.isEmpty { deleteAtCarets(forward: true); return }
        super.deleteForward(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard var string = pb.string(forType: .string) else { super.paste(sender); return }
        if string.utf16.contains(0x0D) { string = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        if !carets.isEmpty { pasteAtCarets(string); return }
        let sel = selectedRange()
        if sel.length == 0, pb.types?.contains(Self.fullLinePasteboardType) == true, string.hasSuffix("\n") {
            // A line copied without a selection is pasted above the current line, like VS Code.
            let lineStart = lines.start(ofLine: lines.line(at: sel.location))
            replace(NSRange(location: lineStart, length: 0), with: string, select: NSRange(location: sel.location + (string as NSString).length, length: 0))
            return
        }
        replace(sel, with: string, select: NSRange(location: sel.location + (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func copy(_ sender: Any?) {
        if !carets.isEmpty { copyCarets(); return }
        let sel = selectedRange()
        guard sel.length == 0 else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(nsString.substring(with: sel), forType: .string)
            return
        }
        copyCurrentLine()
    }

    override func cut(_ sender: Any?) {
        if !carets.isEmpty { copyCarets(); deleteAtCarets(forward: false, selectionsOnly: true); return }
        let sel = selectedRange()
        guard sel.length == 0 else { super.cut(sender); return }
        let range = copyCurrentLine()
        replace(range, with: "", select: NSRange(location: range.location, length: 0))
    }

    @discardableResult
    private func copyCurrentLine() -> NSRange {
        let text = nsString
        var range = lines.fullRange(ofLine: lines.line(at: selectedRange().location), length: text.length)
        var string = text.substring(with: range)
        if !string.hasSuffix("\n") {
            string += "\n"
            // Cutting the last line also takes the line break before it.
            if range.location > 0 { range = NSRange(location: range.location - 1, length: range.length + 1) }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, Self.fullLinePasteboardType], owner: nil)
        pb.setString(string, forType: .string)
        pb.setString("1", forType: Self.fullLinePasteboardType)
        return range
    }

    // MARK: - Smart Home / End, page keys

    private var isHomeOrEndKey: Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown else { return false }
        return e.keyCode == 115 || e.keyCode == 119
    }

    /// First non-blank column of the caret's line, or the line start when already there (VS Code's Home).
    func smartHome(from location: Int) -> Int {
        let line = lines.line(at: location)
        let start = lines.start(ofLine: line)
        let firstText = start + (leadingWhitespace(ofLine: line) as NSString).length
        return location == firstText ? start : firstText
    }

    func lineEnd(from location: Int) -> Int { NSMaxRange(lines.range(ofLine: lines.line(at: location), length: nsString.length)) }

    /// Moves the caret (or, extending, the start of the selection) to `position`.
    private func moveStart(to position: Int, extend: Bool) {
        let sel = selectedRange()
        let range = extend ? NSRange(location: min(position, NSMaxRange(sel)), length: abs(NSMaxRange(sel) - position)) : NSRange(location: position, length: 0)
        setSelectedRange(range, affinity: .upstream, stillSelecting: false)
        scrollRangeToVisible(NSRange(location: position, length: 0))
    }

    /// Moves the caret (or, extending, the end of the selection) to `position`.
    private func moveEnd(to position: Int, extend: Bool) {
        let sel = selectedRange()
        let range = extend ? NSRange(location: min(sel.location, position), length: abs(position - sel.location)) : NSRange(location: position, length: 0)
        setSelectedRange(range, affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(NSRange(location: position, length: 0))
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        if !carets.isEmpty { moveCarets(extend: false) { self.smartHome(from: $0) }; return }
        moveStart(to: smartHome(from: selectedRange().location), extend: false)
    }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        if !carets.isEmpty { moveCarets(extend: true) { self.smartHome(from: $0) }; return }
        moveStart(to: smartHome(from: selectedRange().location), extend: true)
    }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    override func moveToEndOfLine(_ sender: Any?) {
        if !carets.isEmpty { moveCarets(extend: false) { self.lineEnd(from: $0) }; return }
        moveEnd(to: lineEnd(from: NSMaxRange(selectedRange())), extend: false)
    }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        if !carets.isEmpty { moveCarets(extend: true) { self.lineEnd(from: $0) }; return }
        moveEnd(to: lineEnd(from: NSMaxRange(selectedRange())), extend: true)
    }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }

    // Home / End move within the line (macOS only scrolls), as in VS Code.
    override func scrollToBeginningOfDocument(_ sender: Any?) {
        if isHomeOrEndKey { moveToBeginningOfLine(sender) } else { super.scrollToBeginningOfDocument(sender) }
    }
    override func scrollToEndOfDocument(_ sender: Any?) {
        if isHomeOrEndKey { moveToEndOfLine(sender) } else { super.scrollToEndOfDocument(sender) }
    }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        if isHomeOrEndKey { moveToBeginningOfLineAndModifySelection(sender) } else { super.moveToBeginningOfDocumentAndModifySelection(sender) }
    }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        if isHomeOrEndKey { moveToEndOfLineAndModifySelection(sender) } else { super.moveToEndOfDocumentAndModifySelection(sender) }
    }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }

    override func cancelOperation(_ sender: Any?) {
        if !carets.isEmpty { collapseCarets(); return }
        if selectedRange().length > 0 { setSelectedRange(NSRange(location: NSMaxRange(selectedRange()), length: 0)); return }
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }

    // MARK: - Selection tracking

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isApplyingCarets, !carets.isEmpty {
            carets = []
            setNeedsDisplay(visibleRect)
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { updateBracketMatch() }
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option, event.clickCount == 1 {
            let point = convert(event.locationInWindow, from: nil)
            addCaret(at: characterIndexForInsertion(at: point))
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: - Brackets

    private static let openers: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]   // ( [ {
    private static let closersMap: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
    private static let scanLimit = 200_000

    /// The bracket pair touching the caret (the character before it first, then after it).
    func bracketMatch(at location: Int) -> (Int, Int)? {
        let text = nsString
        for p in [location - 1, location] where p >= 0 && p < text.length {
            let c = text.character(at: p)
            if let close = Self.openers[c], let m = scan(from: p + 1, forward: true, open: c, close: close) { return (p, m) }
            if let open = Self.closersMap[c], let m = scan(from: p - 1, forward: false, open: open, close: c) { return (m, p) }
        }
        return nil
    }

    /// The innermost bracket pair enclosing `location`.
    func enclosingBrackets(at location: Int) -> (Int, Int)? {
        let text = nsString
        var depth: [unichar: Int] = [:]
        var p = location - 1
        let stop = max(0, location - Self.scanLimit)
        while p >= stop {
            let c = text.character(at: p)
            if let open = Self.closersMap[c] { depth[open, default: 0] += 1 }
            else if let close = Self.openers[c] {
                if depth[c, default: 0] == 0 {
                    if let m = scan(from: p + 1, forward: true, open: c, close: close) { return (p, m) }
                    return nil
                }
                depth[c, default: 0] -= 1
            }
            p -= 1
        }
        return nil
    }

    private func scan(from start: Int, forward: Bool, open: unichar, close: unichar) -> Int? {
        let text = nsString
        var depth = 0
        var p = start
        var steps = 0
        while p >= 0 && p < text.length && steps < Self.scanLimit {
            let c = text.character(at: p)
            if c == (forward ? open : close) { depth += 1 }
            else if c == (forward ? close : open) {
                if depth == 0 { return p }
                depth -= 1
            }
            p += forward ? 1 : -1
            steps += 1
        }
        return nil
    }

    private func matchingBracket(forCloser ch: Character, before location: Int) -> Int? {
        guard let close = ch.utf16.first, let open = Self.closersMap[close] else { return nil }
        return scan(from: location - 1, forward: false, open: open, close: close)
    }

    private func updateBracketMatch() {
        let sel = selectedRange()
        let pair = sel.length == 0 && carets.isEmpty ? bracketMatch(at: sel.location) : nil
        if pair?.0 != bracketPair?.0 || pair?.1 != bracketPair?.1 {
            bracketPair = pair
            setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
        }
    }

    // MARK: - Drawing

    private func lineRect(forCharacter index: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let length = nsString.length
        if index >= length, lm.extraLineFragmentTextContainer != nil, index == length,
           length == 0 || nsString.character(at: length - 1) == 0x0A {
            return lm.extraLineFragmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        let line = lines.line(at: min(index, max(0, length - 1)))
        let range = lines.fullRange(ofLine: line, length: length)
        guard range.length > 0 else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        if glyphs.length > 1 { rect = rect.union(lm.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)) }
        _ = tc
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let sel = selectedRange()
        if highlightsCurrentLine, sel.length == 0, carets.isEmpty,
           var line = lineRect(forCharacter: sel.location) {
            line.origin.x = 0
            line.size.width = bounds.width
            palette.lineHighlight.setFill()
            line.fill(using: .sourceOver)
        }
        if let scope = findScope, scope.length > 0 {
            palette.findRange.setFill()
            fill(range: scope, lm: lm, tc: tc)
        }
        if showsIndentGuides { drawIndentGuides(in: rect, lm: lm, tc: tc) }
        drawFindMatches(in: rect, lm: lm, tc: tc)
        if findMatches.isEmpty { drawSelectionOccurrences(in: rect, lm: lm, tc: tc) }
        drawCaretSelections(lm: lm, tc: tc)
        if let (a, b) = bracketPair {
            for p in [a, b] {
                let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: p, length: 1), actualCharacterRange: nil)
                let box = backingAlignedRect(lm.boundingRect(forGlyphRange: glyphs, in: tc)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), options: .alignAllEdgesNearest)
                palette.bracketMatch.setFill()
                box.fill(using: .sourceOver)
                palette.bracketMatchBorder.setStroke()
                let path = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func visibleLines(in rect: NSRect, lm: NSLayoutManager, tc: NSTextContainer) -> ClosedRange<Int>? {
        let length = nsString.length
        guard length > 0 else { return nil }
        let r = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: r, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lines.line(at: chars.location)
        let last = lines.line(at: max(chars.location, NSMaxRange(chars) - 1))
        return first...last
    }

    private func indentColumns(ofLine line: Int, text: NSString) -> Int? {
        let range = lines.range(ofLine: line, length: text.length)
        var col = 0
        var p = range.location
        while p < NSMaxRange(range) {
            let c = text.character(at: p)
            if c == 0x20 { col += 1 } else if c == 0x09 { col = (col / tabWidth + 1) * tabWidth } else { return col }
            p += 1
        }
        return nil   // blank
    }

    private func drawIndentGuides(in rect: NSRect, lm: NSLayoutManager, tc: NSTextContainer) {
        guard let visible = visibleLines(in: rect, lm: lm, tc: tc) else { return }
        let text = nsString
        let x0 = textContainerOrigin.x + tc.lineFragmentPadding
        let step = spaceWidth * CGFloat(tabWidth)
        palette.indentGuide.setFill()
        var cache: [Int: Int?] = [:]
        func indent(_ line: Int) -> Int? {
            if let v = cache[line] { return v }
            let v = indentColumns(ofLine: line, text: text)
            cache[line] = v
            return v
        }
        for line in visible {
            var cols = indent(line)
            if cols == nil {
                // Blank line: between the surrounding lines' indentation, like VS Code.
                var above = 0, below = 0
                var l = line - 1
                while l >= max(0, line - 300) { if let v = indent(l) { above = v; break }; l -= 1 }
                l = line + 1
                while l < min(lines.count, line + 300) { if let v = indent(l) { below = v; break }; l += 1 }
                cols = above == below ? above : min(min(above, below) + tabWidth, max(above, below))
            }
            let levels = (cols ?? 0) / tabWidth
            guard levels > 0, let lr = lineRect(forCharacter: lines.start(ofLine: line)) else { continue }
            for level in 0..<levels {
                let x = x0 + CGFloat(level) * step
                backingAlignedRect(NSRect(x: x, y: lr.minY, width: 1, height: lr.height), options: .alignAllEdgesNearest).fill(using: .sourceOver)
            }
        }
    }

    /// Other occurrences of the selected text, highlighted as in VS Code.
    private func drawSelectionOccurrences(in rect: NSRect, lm: NSLayoutManager, tc: NSTextContainer) {
        let sel = selectedRange()
        guard carets.isEmpty, sel.length > 0, sel.length <= 200, let visible = visibleLines(in: rect, lm: lm, tc: tc) else { return }
        let text = nsString
        let needle = text.substring(with: sel)
        guard !needle.contains("\n"), !needle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let start = lines.start(ofLine: visible.lowerBound)
        let end = NSMaxRange(lines.fullRange(ofLine: visible.upperBound, length: text.length))
        var search = NSRange(location: start, length: end - start)
        palette.selectionHighlight.setFill()
        while search.length > 0 {
            let found = text.range(of: needle, options: [.literal], range: search)
            guard found.location != NSNotFound else { break }
            if found != sel { fill(range: found, lm: lm, tc: tc) }
            search = NSRange(location: NSMaxRange(found), length: end - NSMaxRange(found))
        }
    }

    private func drawFindMatches(in rect: NSRect, lm: NSLayoutManager, tc: NSTextContainer) {
        guard !findMatches.isEmpty, let visible = visibleLines(in: rect, lm: lm, tc: tc) else { return }
        let start = lines.start(ofLine: visible.lowerBound)
        let end = NSMaxRange(lines.fullRange(ofLine: visible.upperBound, length: nsString.length))
        var lo = 0, hi = findMatches.count
        while lo < hi { let mid = (lo + hi) / 2; if NSMaxRange(findMatches[mid]) < start { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < findMatches.count, findMatches[i].location <= end {
            (i == findCurrent ? palette.match : palette.matchHighlight).setFill()
            fill(range: findMatches[i], lm: lm, tc: tc)
            i += 1
        }
    }

    func fill(range: NSRange, lm: NSLayoutManager, tc: NSTextContainer) {
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
            self.backingAlignedRect(r.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), options: .alignAllEdgesNearest).fill(using: .sourceOver)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawExtraCarets()
    }
}
