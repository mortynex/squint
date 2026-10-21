import Foundation

/// UTF-16 offsets of the start of every line ("\n"-separated), kept up to date edit by edit.
struct LineIndex {
    private(set) var starts: [Int] = [0]

    /// A line-level description of an edit: lines `start ..< start + removed` became `start ..< start + inserted`.
    struct Change: Equatable {
        let start: Int
        let removed: Int
        let inserted: Int
    }

    init() {}

    init(_ text: NSString) {
        starts = [0]
        starts.reserveCapacity(text.length / 30 + 1)
        Self.appendLineStarts(of: text, in: NSRange(location: 0, length: text.length), to: &starts)
    }

    var count: Int { starts.count }

    /// 0-based line containing `offset` (an offset at a line's start belongs to that line).
    func line(at offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func start(ofLine line: Int) -> Int { starts[max(0, min(line, starts.count - 1))] }

    /// Range of `line` without its line break.
    func range(ofLine line: Int, length: Int) -> NSRange {
        let s = start(ofLine: line)
        let e = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Range of `line` including its line break.
    func fullRange(ofLine line: Int, length: Int) -> NSRange {
        let s = start(ofLine: line)
        let e = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Applies an edit reported by NSTextStorage: `edited` is the changed range in the new text, `delta` the change
    /// in length, `text` the new text.
    @discardableResult
    mutating func update(edited: NSRange, delta: Int, text: NSString) -> Change {
        let oldStart = edited.location
        let oldEnd = edited.location + edited.length - delta
        let first = line(at: oldStart)
        // Line starts inside the replaced text (just after one of its line breaks) are gone.
        var upper = first + 1
        while upper < starts.count, starts[upper] <= oldEnd { upper += 1 }
        let removedBreaks = upper - (first + 1)
        if delta != 0 {
            for i in upper..<starts.count { starts[i] += delta }
        }
        var fresh: [Int] = []
        Self.appendLineStarts(of: text, in: edited, to: &fresh)
        starts.replaceSubrange((first + 1)..<upper, with: fresh)
        return Change(start: first, removed: removedBreaks + 1, inserted: fresh.count + 1)
    }

    private static func appendLineStarts(of text: NSString, in range: NSRange, to out: inout [Int]) {
        guard range.length > 0 else { return }
        var buffer = [unichar](repeating: 0, count: min(range.length, 65536))
        var pos = range.location
        let end = NSMaxRange(range)
        while pos < end {
            let n = min(buffer.count, end - pos)
            text.getCharacters(&buffer, range: NSRange(location: pos, length: n))
            for i in 0..<n where buffer[i] == 0x0A { out.append(pos + i + 1) }
            pos += n
        }
    }
}
