import AppKit

/// Per-language editing behaviour: comment tokens and display names.
struct Language {
    let id: String
    let name: String
    let lineComment: String?
    let blockComment: (open: String, close: String)?

    static let plainText = Language(id: "", name: "Plain Text", lineComment: nil, blockComment: nil)

    private static let slashes = Set([
        "javascript", "typescript", "tsx", "jsx", "java", "c", "cpp", "csharp", "go", "rust", "swift", "kotlin", "scala",
        "dart", "php", "objective-c", "objective-cpp", "groovy", "jsonc", "json5", "jsonl", "less", "scss", "solidity", "zig",
        "glsl", "hlsl", "wgsl", "proto", "prisma", "d", "haxe", "v", "vala", "odin", "typespec", "hjson", "apex", "actionscript-3",
        "angular-ts", "qml", "verilog", "system-verilog", "shaderlab", "cuda", "gleam", "jsonnet", "typst", "kusto", "bicep", "pkl",
    ])
    private static let hashes = Set([
        "python", "ruby", "shellscript", "fish", "perl", "r", "yaml", "toml", "docker", "make", "cmake", "powershell", "elixir",
        "nim", "crystal", "coffee", "julia", "nix", "dotenv", "properties", "gitignore", "terraform", "hcl", "graphql", "nginx",
        "ssh-config", "tcl", "awk", "just", "starlark", "nushell", "gdscript", "raku", "zsh", "bash", "conf", "apache", "codeowners",
        "desktop", "systemd", "jinja", "puppet", "sparql", "julia", "mojo", "gnuplot", "makefile", "requirements",
    ])
    private static let dashes = Set(["sql", "lua", "haskell", "elm", "ada", "vhdl", "applescript", "purescript", "plsql", "cypher", "sdbl", "luau"])
    private static let semicolons = Set(["clojure", "common-lisp", "scheme", "racket", "emacs-lisp", "asm", "nasm", "ini", "fennel", "riscv", "lisp", "reg"])
    private static let percents = Set(["latex", "tex", "erlang", "matlab", "prolog", "bibtex", "postscript"])
    private static let markup = Set(["html", "xml", "markdown", "vue", "svelte", "astro", "mdx", "vue-html", "handlebars", "razor", "erb", "blade", "liquid", "twig", "php-html"])

    private static let names: [String: String] = {
        guard let data = try? Data(contentsOf: EditorEngine.resources.appendingPathComponent("langs.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [:] }
        var out: [String: String] = [:]
        for item in list { if let id = item["id"], let name = item["name"] { out[id] = name } }
        return out
    }()

    /// Every language with a grammar, sorted by name.
    static var all: [Language] { names.keys.map { Language(id: $0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    init(id: String, name: String, lineComment: String?, blockComment: (open: String, close: String)?) {
        self.id = id
        self.name = name
        self.lineComment = lineComment
        self.blockComment = blockComment
    }

    init(id: String) {
        guard !id.isEmpty else { self = .plainText; return }
        self.id = id
        name = Self.names[id] ?? id.capitalized
        var line: String?
        var block: (String, String)?
        if Self.slashes.contains(id) { line = "//"; block = ("/*", "*/") }
        else if Self.hashes.contains(id) { line = "#" }
        else if Self.dashes.contains(id) { line = "--" }
        else if Self.semicolons.contains(id) { line = ";" }
        else if Self.percents.contains(id) { line = "%" }
        else if Self.markup.contains(id) { block = ("<!--", "-->") }
        switch id {
        case "css", "postcss": block = ("/*", "*/")
        case "sass", "stylus": line = "//"; block = ("/*", "*/")
        case "python": block = ("\"\"\"", "\"\"\"")
        case "haskell", "elm", "purescript": block = ("{-", "-}")
        case "lua": block = ("--[[", "]]")
        case "ocaml", "fsharp": line = id == "fsharp" ? "//" : nil; block = ("(*", "*)")
        case "sql": block = ("/*", "*/")
        case "vb", "vbnet": line = "'"
        case "bat": line = "REM"
        case "viml", "vim": line = "\""
        case "fortran-free-form", "fortran-fixed-form": line = "!"
        case "html", "xml", "markdown", "mdx": break
        case "php": line = "//"; block = ("/*", "*/")
        case "graphql": line = "#"
        default: break
        }
        if line == nil && block == nil && Self.names[id] != nil && id.hasSuffix("script") { line = "//" }
        lineComment = line
        blockComment = block
    }
}

/// Small coloured SF Symbols for the Explorer, in the spirit of VS Code's file icons.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL, isDirectory: Bool, expanded: Bool = false) -> NSImage {
        let (symbol, color) = isDirectory ? ("folder.fill", NSColor.systemBlue.withAlphaComponent(0.85)) : style(for: url)
        let key = "\(symbol)|\(color.description)"
        if let image = cache[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
        cache[key] = image
        return image
    }

    private static func style(for url: URL) -> (String, NSColor) {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        switch name {
        case "dockerfile", "containerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yaml": return ("shippingbox", .systemBlue)
        case "makefile", "gnumakefile", "justfile", "rakefile": return ("hammer", .systemOrange)
        case "license", "license.md", "license.txt", "copying": return ("checkmark.seal", .systemYellow)
        case ".gitignore", ".gitattributes", ".gitmodules", ".dockerignore", ".npmignore": return ("arrow.triangle.branch", .systemOrange)
        case "package.json", "package-lock.json": return ("shippingbox", .systemGreen)
        case "readme", "readme.md", "readme.txt": return ("info.circle", .systemBlue)
        default: break
        }
        if name.hasPrefix(".env") { return ("key", .systemYellow) }
        switch ext {
        case "swift": return ("swift", .systemOrange)
        case "js", "mjs", "cjs", "jsx": return ("curlybraces", .systemYellow)
        case "ts", "mts", "cts", "tsx": return ("curlybraces", .systemBlue)
        case "json", "jsonc", "json5", "jsonl", "geojson", "webmanifest": return ("curlybraces.square", .systemYellow)
        case "py", "pyw", "pyi", "ipynb": return ("chevron.left.forwardslash.chevron.right", .systemBlue)
        case "rb", "erb", "gemspec": return ("diamond", .systemRed)
        case "rs": return ("gearshape.2", .systemOrange)
        case "go": return ("chevron.left.forwardslash.chevron.right", .systemCyan)
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return ("chevron.left.forwardslash.chevron.right", .systemIndigo)
        case "java", "kt", "kts", "scala", "groovy", "gradle": return ("cup.and.saucer", .systemRed)
        case "cs", "fs", "vb": return ("number", .systemPurple)
        case "php": return ("chevron.left.forwardslash.chevron.right", .systemPurple)
        case "html", "htm", "xhtml", "vue", "svelte", "astro": return ("chevron.left.slash.chevron.right", .systemOrange)
        case "xml", "plist", "xib", "storyboard", "svg", "entitlements": return ("chevron.left.slash.chevron.right", .systemTeal)
        case "css", "scss", "sass", "less", "styl": return ("paintbrush", .systemPink)
        case "md", "markdown", "mdx", "rst", "adoc", "org": return ("text.alignleft", .systemBlue)
        case "sh", "bash", "zsh", "fish", "command", "ps1", "bat", "cmd": return ("terminal", .systemGreen)
        case "yml", "yaml", "toml", "ini", "cfg", "conf", "properties", "editorconfig", "xcconfig", "env": return ("gearshape", .secondaryLabelColor)
        case "sql", "db", "sqlite", "prisma": return ("cylinder", .systemOrange)
        case "lock", "sum": return ("lock", .tertiaryLabelColor)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns": return ("photo", .systemPurple)
        case "pdf": return ("doc.richtext", .systemRed)
        case "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "tar", "dmg": return ("doc.zipper", .secondaryLabelColor)
        case "mp3", "wav", "aiff", "m4a", "flac": return ("waveform", .systemPink)
        case "mp4", "mov", "m4v", "webm", "mkv": return ("film", .systemPink)
        case "txt", "text", "log", "csv", "tsv": return ("doc.text", .secondaryLabelColor)
        case "lua", "r", "jl", "dart", "ex", "exs", "erl", "hs", "elm", "clj", "ml", "zig", "nim", "pl", "pm":
            return ("chevron.left.forwardslash.chevron.right", .systemGreen)
        default: return ("doc", .secondaryLabelColor)
        }
    }
}
