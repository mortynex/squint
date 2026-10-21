import AppKit

extension NSColor {
    /// Parses CSS hex colours: #rgb, #rrggbb, #rrggbbaa.
    convenience init?(cssHex string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Colours of the preview chrome (gutter and find widget), taken from the Shiki theme.
struct Palette {
    let isDark: Bool
    let bg, fg, gutter, widgetBg, widgetBorder, widgetFg, inputBg, inputFg, focus, match, matchHighlight, error, selection: NSColor
    /// Editor-only colours.
    let cursor, lineHighlight, lineNumberActive, indentGuide, bracketMatch, bracketMatchBorder, selectionHighlight, findRange: NSColor

    init(ui: [String: String], isDark: Bool) {
        func color(_ key: String, _ fallback: String) -> NSColor { NSColor(cssHex: ui[key] ?? "") ?? NSColor(cssHex: fallback)! }
        self.isDark = isDark
        bg = color("bg", isDark ? "#1e1e1e" : "#ffffff")
        fg = color("fg", isDark ? "#d4d4d4" : "#000000")
        gutter = color("gutter", isDark ? "#858585" : "#237893")
        widgetBg = color("widgetBg", isDark ? "#252526" : "#f3f3f3")
        widgetBorder = color("widgetBorder", isDark ? "#454545" : "#c8c8c8")
        widgetFg = color("widgetFg", isDark ? "#cccccc" : "#616161")
        inputBg = color("inputBg", isDark ? "#3c3c3c" : "#ffffff")
        inputFg = color("inputFg", isDark ? "#cccccc" : "#616161")
        focus = color("focus", "#007fd4")
        match = color("match", isDark ? "#515c6a" : "#a8ac94")
        matchHighlight = color("matchHL", "#ea5c0055")
        error = color("error", "#be1100")
        selection = color("selection", isDark ? "#264f78" : "#add6ff")
        cursor = color("cursor", isDark ? "#aeafad" : "#000000")
        lineHighlight = color("lineHighlight", isDark ? "#ffffff0a" : "#0000000a")
        lineNumberActive = color("lineNumberActive", isDark ? "#c6c6c6" : "#0b216f")
        indentGuide = color("indentGuide", isDark ? "#404040" : "#d3d3d3")
        bracketMatch = color("bracketMatch", "#0064001a")
        bracketMatchBorder = color("bracketMatchBorder", isDark ? "#888888" : "#b9b9b9")
        selectionHighlight = color("selectionHighlight", isDark ? "#add6ff26" : "#add6ff80")
        findRange = color("findRange", isDark ? "#3a3d4166" : "#b4b4b44d")
    }
}
