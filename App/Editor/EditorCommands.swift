import AppKit

/// Line-based editing commands with VS Code's default shortcuts (wired up in MainMenu.swift).
extension EditorTextView {
    /// The lines touched by the selection; a selection ending at the start of a line doesn't include that line.
    var selectedLines: ClosedRange<Int> {
        let sel = selectedRange()
        let first = lines.line(at: sel.location)
        let last = sel.length > 0 ? lines.line(at: NSMaxRange(sel) - 1) : first
        return first...max(first, last)
    }

    /// Range of whole lines, including the last one's line break (if it has one).
    func range(ofLines lines: ClosedRange<Int>) -> NSRange {
        let length = nsString.length
        let start = self.lines.start(ofLine: lines.lowerBound)
        let end = NSMaxRange(self.lines.fullRange(ofLine: lines.upperBound, length: length))
        return NSRange(location: start, length: end - start)
    }

    /// Where `position` ends up after `edits` (non-overlapping, any order). `sticky` keeps a position that sits
    /// exactly at an insertion point before the inserted text.
    func map(_ position: Int, through edits: [(NSRange, String)], sticky: Bool = false) -> Int {
        var shift = 0
        for (range, string) in edits {
            let len = (string as NSString).length
            if range.length == 0 {
                if position > range.location || (position == range.location && !sticky) { shift += len }
            } else if position >= NSMaxRange(range) {
                shift += len - range.length
            } else if position > range.location {
                // Inside replaced text: clamp into the replacement.
                shift += min(position - range.location, len) - (position - range.location)
            }
        }
        return position + shift
    }

    /// Applies edits as one undo step and keeps the selection on the same text.
    func apply(_ edits: [(NSRange, String)], keepingSelection: Bool = true) {
        guard !edits.isEmpty else { return }
        let sel = selectedRange()
        let start = map(sel.location, through: edits, sticky: sel.length > 0)
        let end = map(NSMaxRange(sel), through: edits)
        replace(ranges: edits.map { $0.0 }, with: edits.map { $0.1 })
        if keepingSelection { setSelectedRange(NSRange(location: start, length: max(0, end - start))) }
    }

    // MARK: - Comments

    /// ⌘/
    @objc func toggleLineComment(_ sender: Any?) {
        guard let token = language.lineComment else {
            if language.blockComment != nil { toggleBlockComment(sender) } else { NSSound.beep() }
            return
        }
        let text = nsString
        let length = text.length
        let range = selectedLines
        var targets: [(line: Int, indent: Int)] = []
        for line in range {
            let r = lines.range(ofLine: line, length: length)
            let indent = (leadingWhitespace(ofLine: line) as NSString).length
            if indent < r.length { targets.append((line, indent)) }
        }
        if targets.isEmpty {
            // Only blank lines: comment the caret's line at its indentation.
            let line = range.lowerBound
            targets = [(line, (leadingWhitespace(ofLine: line) as NSString).length)]
        }
        let tokenLength = (token as NSString).length
        let commented = targets.allSatisfy { t in
            let r = lines.range(ofLine: t.line, length: length)
            let rest = text.substring(with: NSRange(location: r.location + t.indent, length: r.length - t.indent))
            return rest.hasPrefix(token)
        }
        var edits: [(NSRange, String)] = []
        if commented {
            for t in targets {
                let r = lines.range(ofLine: t.line, length: length)
                let at = r.location + t.indent
                var remove = tokenLength
                if at + remove < NSMaxRange(r), text.character(at: at + remove) == 0x20 { remove += 1 }
                edits.append((NSRange(location: at, length: remove), ""))
            }
        } else {
            let column = targets.map(\.indent).min() ?? 0
            for t in targets {
                edits.append((NSRange(location: lines.start(ofLine: t.line) + column, length: 0), token + " "))
            }
        }
        apply(edits)
    }

    /// ⇧⌥A
    @objc func toggleBlockComment(_ sender: Any?) {
        guard let (open, close) = language.blockComment else {
            if language.lineComment != nil { toggleLineComment(sender) } else { NSSound.beep() }
            return
        }
        let text = nsString
        let sel = selectedRange()
        let o = (open as NSString).length, c = (close as NSString).length
        if sel.length == 0 {
            replace(sel, with: "\(open)  \(close)", select: NSRange(location: sel.location + o + 1, length: 0))
            return
        }
        let selected = text.substring(with: sel)
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(open), trimmed.hasSuffix(close), (trimmed as NSString).length >= o + c {
            let lead = (selected as NSString).range(of: open)
            let trail = (selected as NSString).range(of: close, options: .backwards)
            var openRange = NSRange(location: sel.location + lead.location, length: o)
            var closeRange = NSRange(location: sel.location + trail.location, length: c)
            if NSMaxRange(openRange) < closeRange.location, text.character(at: NSMaxRange(openRange)) == 0x20 { openRange.length += 1 }
            if closeRange.location > NSMaxRange(openRange), text.character(at: closeRange.location - 1) == 0x20 { closeRange.location -= 1; closeRange.length += 1 }
            apply([(openRange, ""), (closeRange, "")])
            return
        }
        // The selection is the inside of a comment.
        if sel.location >= o, NSMaxRange(sel) + c <= text.length,
           text.substring(with: NSRange(location: sel.location - o, length: o)) == open,
           text.substring(with: NSRange(location: NSMaxRange(sel), length: c)) == close {
            apply([(NSRange(location: sel.location - o, length: o), ""), (NSRange(location: NSMaxRange(sel), length: c), "")])
            return
        }
        replace(sel, with: "\(open) \(selected) \(close)", select: NSRange(location: sel.location + o + 1, length: sel.length))
    }

    // MARK: - Moving, copying and deleting lines

    /// ⌥↑
    @objc func moveLinesUp(_ sender: Any?) {
        collapseCarets()
        let range = selectedLines
        guard range.lowerBound > 0 else { return }
        let text = nsString
        let block = self.range(ofLines: range)
        let prev = lines.fullRange(ofLine: range.lowerBound - 1, length: text.length)
        var blockText = text.substring(with: block)
        var prevText = text.substring(with: prev)
        if !blockText.hasSuffix("\n") { blockText += "\n"; prevText.removeLast() }
        let sel = selectedRange()
        replace(NSRange(location: prev.location, length: prev.length + block.length), with: blockText + prevText,
                select: NSRange(location: sel.location - prev.length, length: sel.length))
        scrollRangeToVisible(selectedRange())
    }

    /// ⌥↓
    @objc func moveLinesDown(_ sender: Any?) {
        collapseCarets()
        let range = selectedLines
        guard range.upperBound + 1 < lines.count else { return }
        let text = nsString
        let block = self.range(ofLines: range)
        let next = lines.fullRange(ofLine: range.upperBound + 1, length: text.length)
        var blockText = text.substring(with: block)
        var nextText = text.substring(with: next)
        if !nextText.hasSuffix("\n") { nextText += "\n"; blockText.removeLast() }
        let sel = selectedRange()
        let shift = (nextText as NSString).length
        replace(NSRange(location: block.location, length: block.length + next.length), with: nextText + blockText,
                select: NSRange(location: sel.location + shift, length: sel.length))
        scrollRangeToVisible(selectedRange())
    }

    /// ⇧⌥↑
    @objc func copyLinesUp(_ sender: Any?) { copyLines(down: false) }
    /// ⇧⌥↓
    @objc func copyLinesDown(_ sender: Any?) { copyLines(down: true) }

    private func copyLines(down: Bool) {
        collapseCarets()
        let text = nsString
        let block = range(ofLines: selectedLines)
        var copy = text.substring(with: block)
        let sel = selectedRange()
        if copy.hasSuffix("\n") {
            replace(NSRange(location: block.location, length: 0), with: copy,
                    select: down ? NSRange(location: sel.location + block.length, length: sel.length) : sel)
        } else {
            copy = "\n" + copy
            replace(NSRange(location: NSMaxRange(block), length: 0), with: copy,
                    select: down ? NSRange(location: sel.location + block.length + 1, length: sel.length) : sel)
        }
        scrollRangeToVisible(selectedRange())
    }

    /// ⇧⌘K
    @objc func deleteLines(_ sender: Any?) {
        collapseCarets()
        let text = nsString
        let range = selectedLines
        var block = self.range(ofLines: range)
        let column = selectedRange().location - lines.start(ofLine: lines.line(at: selectedRange().location))
        if !text.substring(with: block).hasSuffix("\n"), block.location > 0 {
            block = NSRange(location: block.location - 1, length: block.length + 1)
        }
        replace(block, with: "")
        let line = min(range.lowerBound, lines.count - 1)
        let r = lines.range(ofLine: line, length: nsString.length)
        setSelectedRange(NSRange(location: r.location + min(column, r.length), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// ⌘↩
    @objc func insertLineBelow(_ sender: Any?) {
        collapseCarets()
        setSelectedRange(NSRange(location: lineEnd(from: NSMaxRange(selectedRange())), length: 0))
        insertNewline(sender)
    }

    /// ⇧⌘↩
    @objc func insertLineAbove(_ sender: Any?) {
        collapseCarets()
        let line = lines.line(at: selectedRange().location)
        let indent = leadingWhitespace(ofLine: line)
        let start = lines.start(ofLine: line)
        replace(NSRange(location: start, length: 0), with: indent + "\n", select: NSRange(location: start + (indent as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// ⌘L: selects the current line; repeating it adds the next line.
    @objc func expandLineSelection(_ sender: Any?) {
        collapseCarets()
        let sel = selectedRange()
        let text = nsString
        let wholeLines = sel.length > 0 && sel.location == lines.start(ofLine: lines.line(at: sel.location))
            && (NSMaxRange(sel) == text.length || NSMaxRange(sel) == lines.start(ofLine: lines.line(at: NSMaxRange(sel))))
        var range = self.range(ofLines: selectedLines)
        if wholeLines, NSMaxRange(sel) < text.length {
            range = NSUnionRange(range, lines.fullRange(ofLine: lines.line(at: NSMaxRange(sel)), length: text.length))
        }
        setSelectedRange(range)
        scrollRangeToVisible(NSRange(location: NSMaxRange(range), length: 0))
    }

    // MARK: - Indentation

    /// ⌘]
    @objc func indentLines(_ sender: Any?) {
        collapseCarets()
        let length = nsString.length
        let range = selectedLines
        let edits = range.compactMap { line -> (NSRange, String)? in
            let r = lines.range(ofLine: line, length: length)
            if r.length == 0 && range.count > 1 { return nil }
            return (NSRange(location: r.location, length: 0), indentUnit)
        }
        apply(edits)
    }

    /// ⌘[ and ⇧⇥
    @objc func outdentLines(_ sender: Any?) {
        collapseCarets()
        let text = nsString
        let edits = selectedLines.compactMap { line -> (NSRange, String)? in
            let r = lines.range(ofLine: line, length: text.length)
            guard r.length > 0 else { return nil }
            if text.character(at: r.location) == 0x09 { return (NSRange(location: r.location, length: 1), "") }
            var n = 0
            while n < tabWidth, r.location + n < NSMaxRange(r), text.character(at: r.location + n) == 0x20 { n += 1 }
            return n > 0 ? (NSRange(location: r.location, length: n), "") : nil
        }
        apply(edits)
    }

    /// Re-indents the whole text with spaces or tabs.
    func convertIndentation(toTabs: Bool) {
        var edits: [(NSRange, String)] = []
        for line in 0..<lines.count {
            let lead = leadingWhitespace(ofLine: line)
            guard !lead.isEmpty else { continue }
            let cols = columns(of: lead)
            let fresh = toTabs ? String(repeating: "\t", count: cols / tabWidth) + String(repeating: " ", count: cols % tabWidth)
                               : String(repeating: " ", count: cols)
            if fresh != lead { edits.append((NSRange(location: lines.start(ofLine: line), length: (lead as NSString).length), fresh)) }
        }
        apply(edits)
    }

    // MARK: - Other

    /// ⇧⌘\
    @objc func jumpToBracket(_ sender: Any?) {
        collapseCarets()
        let caret = selectedRange().location
        if let (a, b) = bracketMatch(at: caret) {
            let target = (caret == a || caret == a + 1) ? b : a
            setSelectedRange(NSRange(location: target, length: 0))
        } else if let (_, b) = enclosingBrackets(at: caret) {
            setSelectedRange(NSRange(location: b, length: 0))
        } else { return }
        scrollRangeToVisible(selectedRange())
    }

    /// ⌃J: joins the selected lines (or the next line) into one.
    @objc func joinLines(_ sender: Any?) {
        collapseCarets()
        let text = nsString
        let range = selectedLines
        let last = range.count > 1 ? range.upperBound : min(range.upperBound + 1, lines.count - 1)
        guard last > range.lowerBound else { return }
        var edits: [(NSRange, String)] = []
        for line in range.lowerBound..<last {
            let r = lines.range(ofLine: line, length: text.length)
            var start = NSMaxRange(r)
            while start > r.location, [0x20, 0x09].contains(text.character(at: start - 1)) { start -= 1 }
            let next = lines.range(ofLine: line + 1, length: text.length)
            let lead = (leadingWhitespace(ofLine: line + 1) as NSString).length
            let joiner = (start == r.location || lead == next.length) ? "" : " "
            edits.append((NSRange(location: start, length: next.location + lead - start), joiner))
        }
        apply(edits, keepingSelection: false)
        let end = lineEnd(from: lines.start(ofLine: range.lowerBound))
        setSelectedRange(NSRange(location: end, length: 0))
    }

    @objc func sortLinesAscending(_ sender: Any?) { sortLines(descending: false) }
    @objc func sortLinesDescending(_ sender: Any?) { sortLines(descending: true) }

    private func sortLines(descending: Bool) {
        collapseCarets()
        let text = nsString
        let range = selectedRange().length > 0 ? selectedLines : 0...(lines.count - 1)
        let full = self.range(ofLines: range)
        var body = text.substring(with: full)
        let trailing = body.hasSuffix("\n")
        if trailing { body.removeLast() }
        var parts = body.components(separatedBy: "\n")
        parts.sort { descending ? $0.localizedStandardCompare($1) == .orderedDescending : $0.localizedStandardCompare($1) == .orderedAscending }
        let joined = parts.joined(separator: "\n") + (trailing ? "\n" : "")
        replace(full, with: joined, select: NSRange(location: full.location, length: (joined as NSString).length))
    }

    @objc func trimTrailingWhitespace(_ sender: Any?) {
        collapseCarets()
        let text = nsString
        var edits: [(NSRange, String)] = []
        for line in 0..<lines.count {
            let r = lines.range(ofLine: line, length: text.length)
            var end = NSMaxRange(r)
            while end > r.location, [0x20, 0x09].contains(text.character(at: end - 1)) { end -= 1 }
            if end < NSMaxRange(r) { edits.append((NSRange(location: end, length: NSMaxRange(r) - end), "")) }
        }
        apply(edits)
    }

    @objc func transformToUppercase(_ sender: Any?) { transformSelection { $0.uppercased() } }
    @objc func transformToLowercase(_ sender: Any?) { transformSelection { $0.lowercased() } }

    private func transformSelection(_ transform: (String) -> String) {
        let text = nsString
        var ranges = allCarets.map(\.range).filter { $0.length > 0 }
        if ranges.isEmpty {
            let word = selectionRange(forProposedRange: selectedRange(), granularity: .selectByWord)
            if word.length > 0 { ranges = [word] }
        }
        guard !ranges.isEmpty else { return }
        let sel = selectedRange()
        replace(ranges: ranges, with: ranges.map { transform(text.substring(with: $0)) })
        if carets.isEmpty { setSelectedRange(sel) }
    }

    /// Selects `line` (1-based) and `column` (1-based, in characters) and centres it.
    func goTo(line: Int, column: Int = 1) {
        collapseCarets()
        let l = max(0, min(line - 1, lines.count - 1))
        let r = lines.range(ofLine: l, length: nsString.length)
        let pos = r.location + max(0, min(column - 1, r.length))
        setSelectedRange(NSRange(location: pos, length: 0))
        centerSelectionInVisibleArea(nil)
    }
}
