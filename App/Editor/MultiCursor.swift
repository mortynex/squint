import AppKit

/// Multiple cursors (VS Code's ⌘D, ⇧⌘L, ⌥⌘↑/↓, ⌥-click). NSTextView supports only one insertion point, so the extra
/// cursors are kept in `carets` and drawn by the view; the primary one is mirrored to NSTextView's selection.
extension EditorTextView {
    var allCarets: [Caret] { carets.isEmpty ? [Caret(selectedRange())] : carets }

    /// Sets the cursors (sorted and merged); a single cursor goes back to the plain NSTextView selection.
    func setCarets(_ list: [Caret], primary: Int? = nil) {
        var sorted = list.enumerated().sorted { $0.element.range.location < $1.element.range.location }
        let wantedPrimary = primary.flatMap { p in sorted.firstIndex { $0.offset == p } } ?? sorted.count - 1
        var merged: [Caret] = []
        var primaryIndex = 0
        for (i, item) in sorted.enumerated() {
            if let last = merged.last, item.element.range.location < NSMaxRange(last.range) || (item.element.range == last.range) {
                let union = NSUnionRange(last.range, item.element.range)
                merged[merged.count - 1] = Caret(union)
            } else {
                merged.append(item.element)
            }
            if i == wantedPrimary { primaryIndex = merged.count - 1 }
        }
        sorted.removeAll()
        isApplyingCarets = true
        defer { isApplyingCarets = false }
        if merged.count <= 1 {
            carets = []
            let only = merged.first ?? Caret(0, 0)
            setSelectedRange(only.range)
        } else {
            carets = merged
            primaryCaret = primaryIndex
            setSelectedRange(merged[primaryIndex].range)
        }
        setNeedsDisplay(visibleRect)
    }

    func collapseCarets() {
        guard !carets.isEmpty else { return }
        let primary = carets[min(primaryCaret, carets.count - 1)]
        setCarets([primary])
    }

    func addCaret(at location: Int) {
        var list = allCarets
        if let existing = list.firstIndex(where: { $0.isEmpty && $0.head == location }), list.count > 1 {
            list.remove(at: existing)
            setCarets(list)
            return
        }
        list.append(Caret(location, location))
        setCarets(list, primary: list.count - 1)
    }

    // MARK: - Adding cursors

    /// ⌘D: selects the word at the cursor, then adds the next occurrence of the selection.
    @objc func addSelectionToNextFindMatch(_ sender: Any?) {
        let text = nsString
        let list = allCarets
        let primary = list[carets.isEmpty ? 0 : primaryCaret]
        if primary.isEmpty {
            let word = selectionRange(forProposedRange: NSRange(location: primary.head, length: 0), granularity: .selectByWord)
            guard word.length > 0 else { return }
            var updated = list
            updated[carets.isEmpty ? 0 : primaryCaret] = Caret(word)
            setCarets(updated, primary: carets.isEmpty ? 0 : primaryCaret)
            return
        }
        let needle = text.substring(with: primary.range)
        let last = list.max { $0.range.location < $1.range.location }!
        var found = text.range(of: needle, options: [.literal], range: NSRange(location: NSMaxRange(last.range), length: text.length - NSMaxRange(last.range)))
        if found.location == NSNotFound {
            found = text.range(of: needle, options: [.literal], range: NSRange(location: 0, length: text.length))
        }
        guard found.location != NSNotFound, !list.contains(where: { $0.range == found }) else { return }
        setCarets(list + [Caret(found)], primary: list.count)
        scrollRangeToVisible(found)
    }

    /// ⇧⌘L: a cursor on every occurrence of the selection (or of the word at the cursor).
    @objc func selectAllOccurrences(_ sender: Any?) {
        let text = nsString
        var sel = selectedRange()
        if sel.length == 0 { sel = selectionRange(forProposedRange: sel, granularity: .selectByWord) }
        guard sel.length > 0 else { return }
        let needle = text.substring(with: sel)
        var result: [Caret] = []
        var search = NSRange(location: 0, length: text.length)
        while result.count < 10_000 {
            let found = text.range(of: needle, options: [.literal], range: search)
            if found.location == NSNotFound { break }
            result.append(Caret(found))
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        setCarets(result, primary: result.firstIndex { $0.range == sel })
    }

    @objc func addCursorAbove(_ sender: Any?) { addCursorVertically(-1) }
    @objc func addCursorBelow(_ sender: Any?) { addCursorVertically(1) }

    private func addCursorVertically(_ direction: Int) {
        let list = allCarets
        let edge = direction < 0 ? list.min { $0.head < $1.head }! : list.max { $0.head < $1.head }!
        let line = lines.line(at: edge.head) + direction
        guard line >= 0, line < lines.count else { return }
        let column = edge.head - lines.start(ofLine: lines.line(at: edge.head))
        let target = lines.range(ofLine: line, length: nsString.length)
        let pos = target.location + min(column, target.length)
        setCarets(list + [Caret(pos, pos)], primary: list.count)
        scrollRangeToVisible(NSRange(location: pos, length: 0))
    }

    /// ⇧⌥I: a cursor at the end of every selected line.
    @objc func addCursorsToLineEnds(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let first = lines.line(at: sel.location)
        let last = lines.line(at: max(sel.location, NSMaxRange(sel) - 1))
        let length = nsString.length
        let list = (first...last).map { line -> Caret in
            let end = NSMaxRange(lines.range(ofLine: line, length: length))
            return Caret(end, end)
        }
        setCarets(list)
    }

    // MARK: - Editing at every cursor

    /// Replaces every cursor's range with what `edit` returns: (range to replace, replacement, caret offset in it).
    private func editCarets(_ edit: (Caret) -> (NSRange, String, Int)?) {
        let list = allCarets
        var edits: [(NSRange, String, Int)] = []
        var lastEnd = -1
        for caret in list {
            guard let e = edit(caret) else { edits.append((NSRange(location: caret.head, length: 0), "", 0)); continue }
            // Two cursors deleting into each other: keep the edits apart.
            var range = e.0
            if range.location < lastEnd { range = NSRange(location: lastEnd, length: max(0, NSMaxRange(range) - lastEnd)) }
            lastEnd = NSMaxRange(range)
            edits.append((range, e.1, e.2))
        }
        let changes = edits.filter { $0.0.length > 0 || !$0.1.isEmpty }
        guard !changes.isEmpty else { return }
        isApplyingCarets = true
        replace(ranges: changes.map { $0.0 }, with: changes.map { $0.1 })
        isApplyingCarets = false
        var delta = 0
        var result: [Caret] = []
        for e in edits {
            let pos = e.0.location + delta + e.2
            result.append(Caret(pos, pos))
            delta += (e.1 as NSString).length - e.0.length
        }
        setCarets(result, primary: primaryCaret)
        scrollRangeToVisible(selectedRange())
    }

    func insertAtCarets(_ string: String) {
        let n = (string as NSString).length
        editCarets { ($0.range, string, n) }
    }

    func insertNewlineAtCarets() {
        editCarets { caret in
            let indent = leadingWhitespace(ofLine: lines.line(at: caret.range.location))
            let s = "\n" + indent
            return (caret.range, s, (s as NSString).length)
        }
    }

    func deleteAtCarets(forward: Bool, selectionsOnly: Bool = false) {
        let text = nsString
        editCarets { caret in
            if !caret.isEmpty { return (caret.range, "", 0) }
            if selectionsOnly { return nil }
            if forward {
                guard caret.head < text.length else { return nil }
                return (text.rangeOfComposedCharacterSequence(at: caret.head), "", 0)
            }
            guard caret.head > 0 else { return nil }
            return (text.rangeOfComposedCharacterSequence(at: caret.head - 1), "", 0)
        }
    }

    func pasteAtCarets(_ string: String) {
        var parts = string.components(separatedBy: "\n")
        if parts.last == "", parts.count == allCarets.count + 1 { parts.removeLast() }
        if parts.count == allCarets.count {
            var i = 0
            editCarets { caret in
                defer { i += 1 }
                return (caret.range, parts[i], (parts[i] as NSString).length)
            }
        } else {
            insertAtCarets(string)
        }
    }

    func copyCarets() {
        let text = nsString
        let parts = allCarets.filter { !$0.isEmpty }.map { text.substring(with: $0.range) }
        guard !parts.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(parts.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Moving every cursor

    func moveCarets(extend: Bool, _ target: (Int) -> Int) {
        setCarets(allCarets.map { c in
            let head = target(c.head)
            return Caret(extend ? c.anchor : head, head)
        }, primary: primaryCaret)
    }

    private func moveHorizontally(_ forward: Bool, extend: Bool) {
        let text = nsString
        setCarets(allCarets.map { c in
            if !extend && !c.isEmpty { let p = forward ? NSMaxRange(c.range) : c.range.location; return Caret(p, p) }
            var head = c.head
            if forward, head < text.length { head = NSMaxRange(text.rangeOfComposedCharacterSequence(at: head)) }
            if !forward, head > 0 { head = text.rangeOfComposedCharacterSequence(at: head - 1).location }
            return Caret(extend ? c.anchor : head, head)
        }, primary: primaryCaret)
    }

    private func moveVertically(_ direction: Int, extend: Bool) {
        let length = nsString.length
        setCarets(allCarets.map { c in
            let line = lines.line(at: c.head)
            let column = c.head - lines.start(ofLine: line)
            let target = line + direction
            let head: Int
            if target < 0 { head = 0 } else if target >= lines.count { head = length } else {
                let r = lines.range(ofLine: target, length: length)
                head = r.location + min(column, r.length)
            }
            return Caret(extend ? c.anchor : head, head)
        }, primary: primaryCaret)
    }

    private func moveByWord(_ forward: Bool, extend: Bool) {
        guard let storage = textStorage else { return }
        let length = storage.length
        setCarets(allCarets.map { c in
            var head = c.head
            if forward { head = head < length ? storage.nextWord(from: head, forward: true) : length }
            else { head = head > 0 ? storage.nextWord(from: head, forward: false) : 0 }
            return Caret(extend ? c.anchor : head, head)
        }, primary: primaryCaret)
    }

    override func moveLeft(_ sender: Any?) { carets.isEmpty ? super.moveLeft(sender) : moveHorizontally(false, extend: false) }
    override func moveRight(_ sender: Any?) { carets.isEmpty ? super.moveRight(sender) : moveHorizontally(true, extend: false) }
    override func moveBackward(_ sender: Any?) { carets.isEmpty ? super.moveBackward(sender) : moveHorizontally(false, extend: false) }
    override func moveForward(_ sender: Any?) { carets.isEmpty ? super.moveForward(sender) : moveHorizontally(true, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { carets.isEmpty ? super.moveLeftAndModifySelection(sender) : moveHorizontally(false, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { carets.isEmpty ? super.moveRightAndModifySelection(sender) : moveHorizontally(true, extend: true) }
    override func moveUp(_ sender: Any?) { carets.isEmpty ? super.moveUp(sender) : moveVertically(-1, extend: false) }
    override func moveDown(_ sender: Any?) { carets.isEmpty ? super.moveDown(sender) : moveVertically(1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { carets.isEmpty ? super.moveUpAndModifySelection(sender) : moveVertically(-1, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { carets.isEmpty ? super.moveDownAndModifySelection(sender) : moveVertically(1, extend: true) }
    override func moveWordLeft(_ sender: Any?) { carets.isEmpty ? super.moveWordLeft(sender) : moveByWord(false, extend: false) }
    override func moveWordRight(_ sender: Any?) { carets.isEmpty ? super.moveWordRight(sender) : moveByWord(true, extend: false) }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { carets.isEmpty ? super.moveWordLeftAndModifySelection(sender) : moveByWord(false, extend: true) }
    override func moveWordRightAndModifySelection(_ sender: Any?) { carets.isEmpty ? super.moveWordRightAndModifySelection(sender) : moveByWord(true, extend: true) }

    override func deleteWordBackward(_ sender: Any?) {
        guard !carets.isEmpty, let storage = textStorage else { return super.deleteWordBackward(sender) }
        editCarets { c in
            if !c.isEmpty { return (c.range, "", 0) }
            let start = c.head > 0 ? storage.nextWord(from: c.head, forward: false) : 0
            return (NSRange(location: start, length: c.head - start), "", 0)
        }
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        guard !carets.isEmpty else { return super.deleteToBeginningOfLine(sender) }
        editCarets { c in
            if !c.isEmpty { return (c.range, "", 0) }
            let start = lines.start(ofLine: lines.line(at: c.head))
            return (NSRange(location: start, length: c.head - start), "", 0)
        }
    }

    override func selectAll(_ sender: Any?) {
        carets = []
        super.selectAll(sender)
    }

    // MARK: - Drawing

    func drawCaretSelections(lm: NSLayoutManager, tc: NSTextContainer) {
        guard carets.count > 1 else { return }
        palette.selection.setFill()
        for (i, c) in carets.enumerated() where i != primaryCaret && !c.isEmpty {
            fill(range: c.range, lm: lm, tc: tc)
        }
    }

    func drawExtraCarets() {
        guard carets.count > 1, let lm = layoutManager, let tc = textContainer else { return }
        palette.cursor.setFill()
        let length = nsString.length
        for (i, c) in carets.enumerated() where i != primaryCaret {
            var rect: NSRect
            if c.head >= length, length > 0 {
                let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
                rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                rect.origin.x = rect.maxX
                if nsString.character(at: length - 1) == 0x0A { rect = lm.extraLineFragmentRect; rect.origin.x = tc.lineFragmentPadding }
            } else {
                let glyph = lm.glyphIndexForCharacter(at: c.head)
                let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                rect = frag
                rect.origin.x = lm.location(forGlyphAt: glyph).x + frag.minX
            }
            rect.size.width = 2
            rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            backingAlignedRect(rect, options: .alignAllEdgesNearest).fill()
        }
    }
}
