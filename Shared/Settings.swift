import Foundation

/// User preferences, stored as JSON at ~/.config/squint/config.json.
/// The app writes it; the sandboxed Quick Look extension reads it (via a read-only home-relative exception).
struct Settings: Codable, Equatable {
    var lightTheme = "github-light-default"
    var darkTheme = "github-dark-default"
    /// Font family name; empty means the system monospaced font (SF Mono).
    var fontFamily = ""
    var fontSize = 13
    var lineNumbers = true
    var wrapLines = false
    /// Transparent: the preview shows the Quick Look window's own glass. Otherwise the theme's editor colour is used.
    var transparentBackground = true
    // Editor (app window) only.
    /// The whole editor window is translucent glass, like the Quick Look window.
    var glassWindow = true
    var tabSize = 4
    var insertSpaces = true
    var detectIndentation = true
    var autoClosingBrackets = true
    var highlightCurrentLine = true
    var indentGuides = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        lightTheme = try c.decodeIfPresent(String.self, forKey: .lightTheme) ?? d.lightTheme
        darkTheme = try c.decodeIfPresent(String.self, forKey: .darkTheme) ?? d.darkTheme
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? d.fontSize
        lineNumbers = try c.decodeIfPresent(Bool.self, forKey: .lineNumbers) ?? d.lineNumbers
        wrapLines = try c.decodeIfPresent(Bool.self, forKey: .wrapLines) ?? d.wrapLines
        transparentBackground = try c.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? d.transparentBackground
        glassWindow = try c.decodeIfPresent(Bool.self, forKey: .glassWindow) ?? d.glassWindow
        tabSize = try c.decodeIfPresent(Int.self, forKey: .tabSize) ?? d.tabSize
        insertSpaces = try c.decodeIfPresent(Bool.self, forKey: .insertSpaces) ?? d.insertSpaces
        detectIndentation = try c.decodeIfPresent(Bool.self, forKey: .detectIndentation) ?? d.detectIndentation
        autoClosingBrackets = try c.decodeIfPresent(Bool.self, forKey: .autoClosingBrackets) ?? d.autoClosingBrackets
        highlightCurrentLine = try c.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? d.highlightCurrentLine
        indentGuides = try c.decodeIfPresent(Bool.self, forKey: .indentGuides) ?? d.indentGuides
    }

    /// The real home directory (a sandboxed process's NSHomeDirectory() is its container).
    private static var home: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Tests point this somewhere else.
    static var fileURL = URL(fileURLWithPath: home + "/.config/squint/config.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func options(dark: Bool) -> Highlighter.Options {
        var o = Highlighter.Options()
        o.dark = dark
        o.light = lightTheme
        o.darkTheme = darkTheme
        o.fontFamily = fontFamily
        o.fontSize = fontSize
        o.lineNumbers = lineNumbers
        o.wrap = wrapLines
        o.transparent = transparentBackground
        return o
    }
}
