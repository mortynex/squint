import AppKit

/// Colours an editor's text with Shiki, incrementally: edits are forwarded line by line to the JS document, and dirty
/// lines are re-tokenized right away for a few milliseconds, the rest in small chunks on later run-loop turns.
final class SyntaxColorer {
    struct Fonts {
        let regular, bold, italic, boldItalic: NSFont
        let italicIsSynthetic: Bool

        init(_ font: NSFont) {
            regular = font
            let manager = NSFontManager.shared
            bold = manager.convert(font, toHaveTrait: .boldFontMask)
            let italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
            italicIsSynthetic = !manager.traits(of: italicFont).contains(.italicFontMask)
            italic = italicFont
            boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        }
    }

    let language: String
    private let id = EditorEngine.makeDocumentId()
    private let highlighter: Highlighter
    private weak var textView: EditorTextView?
    private var colors: [NSColor?] = []
    private let fonts: Fonts
    private var scheduled = false
    private var closed = false
    /// Time spent tokenizing synchronously after an edit; the rest is done later.
    static let editBudget = 6.0
    static let backgroundBudget = 12.0

    /// Opens `text` (already in the text view) for colouring; nil for plain text.
    init?(textView: EditorTextView, language: String, options: Highlighter.Options, fonts: Fonts,
          highlighter: Highlighter = EditorEngine.highlighter) {
        guard !language.isEmpty, let storage = textView.textStorage else { return nil }
        self.language = language
        self.highlighter = highlighter
        self.textView = textView
        self.fonts = fonts
        guard let info = highlighter.openDocument(id: id, text: storage.string, language: language, options: options), !info.lang.isEmpty else { return nil }
        colors = info.colors.map { $0.flatMap { NSColor(cssHex: $0) } }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        highlighter.closeDocument(id: id)
    }

    /// Forwards an edit (already applied to the text view and its line index) to the tokenizer.
    func edit(_ change: LineIndex.Change) {
        guard !closed, let tv = textView else { return }
        let lines = tv.lines
        let text = tv.nsString
        let start = lines.start(ofLine: change.start)
        let lastLine = change.start + change.inserted - 1
        let end = NSMaxRange(lines.range(ofLine: lastLine, length: text.length))
        highlighter.editDocument(id: id, start: change.start, removed: change.removed, text: text.substring(with: NSRange(location: start, length: end - start)))
    }

    /// Tokenizes for `budget` ms and applies the result; schedules the remaining work.
    func tokenize(budget: Double = SyntaxColorer.editBudget) {
        guard !closed, let tv = textView, let storage = tv.textStorage else { return }
        let tokens = highlighter.tokenizeDocument(id: id, budget: budget)
        apply(tokens, to: storage, lines: tv.lines)
        if tokens.more { scheduleBackground() }
    }

    private func scheduleBackground() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.tokenize(budget: Self.backgroundBudget)
        }
    }

    /// Tokenizes everything now (tests, small files).
    func tokenizeAll() {
        guard !closed, let tv = textView, let storage = tv.textStorage else { return }
        var tokens: Highlighter.Tokens
        repeat {
            tokens = highlighter.tokenizeDocument(id: id, budget: 1000)
            apply(tokens, to: storage, lines: tv.lines)
        } while tokens.more
    }

    /// Colours go into the layout manager's temporary attributes, which (unlike text storage attributes) don't make
    /// every later edit slower; only bold / italic, which change glyphs, are set on the text storage.
    private func apply(_ tokens: Highlighter.Tokens, to storage: NSTextStorage, lines: LineIndex) {
        guard !tokens.ranges.isEmpty, let lm = textView?.layoutManager else { return }
        let length = storage.length
        var fontEdits: [(NSRange, [NSAttributedString.Key: Any])] = []
        for r in tokens.ranges {
            let start = lines.start(ofLine: r.lowerBound)
            let end = r.upperBound < lines.count ? lines.start(ofLine: r.upperBound) : length
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            for key in [NSAttributedString.Key.foregroundColor, .underlineStyle, .strikethroughStyle] {
                lm.removeTemporaryAttribute(key, forCharacterRange: range)
            }
            // Reset styled fonts left from before.
            storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                if let f = value as? NSFont, f != fonts.regular { fontEdits.append((sub, [.font: fonts.regular])) }
            }
            storage.enumerateAttribute(.obliqueness, in: range, options: []) { value, sub, _ in
                if value != nil { fontEdits.append((sub, [.obliqueness: 0])) }
            }
        }
        let spans = tokens.spans
        var i = 0
        while i + 4 < spans.count {
            let line = Int(spans[i]), column = Int(spans[i + 1]), len = Int(spans[i + 2]), color = Int(spans[i + 3]), style = Int(spans[i + 4])
            i += 5
            guard line < lines.count, len > 0 else { continue }
            let location = lines.start(ofLine: line) + column
            guard location >= 0, location + len <= length else { continue }
            let range = NSRange(location: location, length: len)
            var temp: [NSAttributedString.Key: Any] = [:]
            if color > 1, color < colors.count, let c = colors[color] { temp[.foregroundColor] = c }
            if style & 4 != 0 { temp[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style & 8 != 0 { temp[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if !temp.isEmpty { lm.addTemporaryAttributes(temp, forCharacterRange: range) }
            if style & 3 != 0 {
                let italic = style & 1 != 0, bold = style & 2 != 0
                var attrs: [NSAttributedString.Key: Any] = [.font: bold && italic ? fonts.boldItalic : bold ? fonts.bold : fonts.italic]
                if italic && fonts.italicIsSynthetic { attrs[.obliqueness] = 0.2 }
                fontEdits.append((range, attrs))
            }
        }
        guard !fontEdits.isEmpty else { return }
        storage.beginEditing()
        for (range, attrs) in fontEdits { storage.addAttributes(attrs, range: range) }
        storage.endEditing()
    }

    /// Removes all colouring (before re-colouring with another theme or language).
    static func clear(_ textView: NSTextView) {
        guard let lm = textView.layoutManager, let length = textView.textStorage?.length, length > 0 else { return }
        let all = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.foregroundColor, .underlineStyle, .strikethroughStyle] { lm.removeTemporaryAttribute(key, forCharacterRange: all) }
    }
}
