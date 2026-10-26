import AppKit

// Headless tests for the editor: test/editor.sh builds this with the app's sources and runs it.

var failures = 0
var checks = 0
var currentTest = ""

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✗ [\(currentTest)] \(message()) (line \(line))")
    }
}

func equal<T: Equatable>(_ a: T, _ b: T, _ message: String = "", line: UInt = #line) {
    check(a == b, "\(message) expected \(String(reflecting: b)), got \(String(reflecting: a))", line: line)
}

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures
    let start = Date()
    do { try body() } catch { failures += 1; print("  ✗ [\(name)] threw \(error)") }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print(failures == before ? "✓ \(name) (\(ms) ms)" : "✗ \(name)")
}

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        spin(0.02)
    }
    return condition()
}

let repo = URL(fileURLWithPath: CommandLine.arguments[1])
EditorEngine.resources = repo.appendingPathComponent("Resources")
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("squint-tests-\(getpid())").resolvingSymlinksInPath()
try? FileManager.default.removeItem(at: scratch)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

Settings.fileURL = scratch.appendingPathComponent("config.json")
if let i = CommandLine.arguments.firstIndex(of: "--settings"), i + 1 < CommandLine.arguments.count {
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[i + 1]), to: Settings.fileURL)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Showcase: real windows on screen for screenshots (test/editor.sh --showcase <state> [glass style]).
if let i = CommandLine.arguments.firstIndex(of: "--showcase") {
    let state = CommandLine.arguments[i + 1]
    if i + 2 < CommandLine.arguments.count { UserDefaults.standard.set(CommandLine.arguments[i + 2], forKey: "GlassStyle") }
    app.setActivationPolicy(.regular)
    let screen = NSScreen.main!.visibleFrame
    let frame = NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 1180, height: 760)
    // A colourful backdrop so translucency is visible.
    let backdrop = NSWindow(contentRect: frame.insetBy(dx: -30, dy: -30), styleMask: [.borderless], backing: .buffered, defer: false)
    let gradient = NSView()
    gradient.wantsLayer = true
    let layer = CAGradientLayer()
    layer.colors = [NSColor.systemPink.cgColor, NSColor.systemOrange.cgColor, NSColor.systemTeal.cgColor, NSColor.systemIndigo.cgColor]
    layer.startPoint = CGPoint(x: 0, y: 0); layer.endPoint = CGPoint(x: 1, y: 1)
    gradient.layer = layer
    let label = NSTextField(labelWithString: "BACKDROP  BACKDROP  BACKDROP  BACKDROP")
    label.font = .systemFont(ofSize: 90, weight: .black)
    label.textColor = .white
    label.frame = NSRect(x: 20, y: 300, width: 2400, height: 120)
    gradient.addSubview(label)
    backdrop.contentView = gradient
    backdrop.orderFront(nil)
    let w = EditorWindowController(root: repo)
    w.window?.setFrame(frame, display: true)
    w.showWindow(nil)
    w.window?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    let tv = w.editor.textView
    w.open(repo.appendingPathComponent("App/Editor/FindModel.swift"))
    w.explorer.reveal(repo.appendingPathComponent("App/Editor/FindModel.swift"))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        switch state {
        case "find":
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "query").location, length: 5))
            w.editor.showFind(replace: true)
        case "quickopen":
            w.goToFile(nil)
            w.quickOpen?.query = "edvc"
        case "multicursor":
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "matches").location, length: 0))
            tv.addSelectionToNextFindMatch(nil); tv.addSelectionToNextFindMatch(nil); tv.addSelectionToNextFindMatch(nil)
        case "unsaved":
            tv.insertText("// unsaved\n", replacementRange: NSRange(location: 0, length: 0))
        case "nosidebar":
            w.setSidebarVisible(false)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "language":
            w.showLanguagePicker()
        case "setup":
            DefaultApps.appBundle = URL(fileURLWithPath: "/Applications/Squint.app")
            for c in QuickLookExtensions.status().competitors { print("COMPETITOR \(c.info.name) \(c.info.id) \(c.sharedTypes)") }
            print("SQUINT \(QuickLookExtensions.status().squint)")
            AppDelegate().showSetup(nil)
            if let s = NSApp.windows.first(where: { $0.title == "Set Up Squint" }) {
                s.setFrameOrigin(NSPoint(x: frame.minX + 60, y: frame.minY + 20))
                print("WINDOW \(s.windowNumber)")
                fflush(stdout)
            }
            return
        case "settings":
            DefaultApps.appBundle = URL(fileURLWithPath: "/Applications/Squint.app")
            let st = DefaultApps.status()
            print("STATUS squint \(st.squint) of \(st.total); restorable \(DefaultApps.restorable)")
            for o in st.others { print("STATUS  \(o.name): \(o.types.count) — \(o.summary)") }
            let d = AppDelegate()
            d.showSettings(nil)
            if let s = NSApp.windows.first(where: { $0.title == "Squint Settings" }) {
                s.setFrameOrigin(NSPoint(x: frame.minX + 60, y: frame.minY + 20))
                print("WINDOW \(s.windowNumber)")
                fflush(stdout)
            }
            return
        default: break
        }
        print("WINDOW \(w.window!.windowNumber)")
        fflush(stdout)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}
let delegate = AppDelegate()
NSApp.mainMenu = MainMenu.build(recentDelegate: delegate)

/// An editor in an offscreen window.
final class Harness {
    let window: NSWindow
    let editor = EditorViewController()
    var tv: EditorTextView { editor.textView }

    init(_ text: String, name: String = "test.ts", language: String? = nil) {
        window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.load(text: text, name: name, format: TextFormat(), language: language)
        editor.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(tv)
    }

    var text: String { tv.string }
    var sel: NSRange { tv.selectedRange() }

    /// Places the caret at "|" (and a selection between two "|") in `marked`.
    func set(_ marked: String) {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        editor.load(text: text, name: editor.fileName, format: TextFormat(), language: editor.language.id)
        let a = (parts[0] as NSString).length
        let b = parts.count > 2 ? a + (parts[1] as NSString).length : a
        tv.setSelectedRange(NSRange(location: a, length: b - a))
    }

    /// The text with "|" at the selection ends.
    var marked: String {
        let s = NSMutableString(string: tv.string)
        let r = sel
        if r.length > 0 { s.insert("|", at: NSMaxRange(r)) }
        s.insert("|", at: r.location)
        return s as String
    }

    func type(_ s: String) {
        for ch in s {
            if ch == "\n" { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            else if ch == "\t" { tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
            else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    func command(_ selector: Selector) { tv.doCommand(by: selector) }

    /// Finds the menu item for a shortcut like "cmd+shift+k" and sends its action up the responder chain.
    @discardableResult
    func shortcut(_ spec: String) -> Bool {
        guard let item = MenuTools.item(for: spec) else { check(false, "no menu item for \(spec)"); return false }
        guard let action = item.action else { return false }
        let responder = window.firstResponder ?? tv
        let ok = responder.tryToPerform(action, with: item)
        check(ok, "\(spec) (\(item.title)) found no responder")
        return ok
    }

    /// Colour of every character, for comparing highlighting results.
    func colors() -> [String] {
        guard let storage = tv.textStorage else { return [] }
        var out: [String] = []
        out.reserveCapacity(storage.length)
        let lm = tv.layoutManager!
        for i in 0..<storage.length {
            let c = (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) ?? storage.attribute(.foregroundColor, at: i, effectiveRange: nil)) as? NSColor
            let f = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            out.append("\(c?.description ?? "nil")|\(f?.fontName ?? "")")
        }
        return out
    }
}

enum MenuTools {
    static func parse(_ spec: String) -> (String, NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.split(separator: "+").map(String.init) {
            switch part {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt": mods.insert(.option)
            case "ctrl": mods.insert(.control)
            case "up": key = MainMenu.up
            case "down": key = MainMenu.down
            case "enter": key = "\r"
            case "plus": key = "+"
            default: key = part
            }
        }
        return (key, mods)
    }

    static func allItems(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + allItems($0.submenu) }
    }

    static func item(for spec: String) -> NSMenuItem? {
        let (key, mods) = parse(spec)
        return allItems().first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == mods }
    }
}

// MARK: - Line index

test("line index stays equal to a rebuilt one under random edits") {
    var rng = SystemRandomNumberGenerator()
    let storage = NSTextStorage(string: "one\ntwo\n\nthree\nfour")
    var index = LineIndex(storage.string as NSString)
    let pieces = ["", "a", "\n", "xy\nz", "\n\n", "long line here", "\nq\n"]
    for _ in 0..<3000 {
        let len = storage.length
        let loc = Int.random(in: 0...len, using: &rng)
        let del = Int.random(in: 0...min(6, len - loc), using: &rng)
        let ins = pieces.randomElement(using: &rng)!
        storage.replaceCharacters(in: NSRange(location: loc, length: del), with: ins)
        let edited = NSRange(location: loc, length: (ins as NSString).length)
        let change = index.update(edited: edited, delta: (ins as NSString).length - del, text: storage.string as NSString)
        let fresh = LineIndex(storage.string as NSString)
        if index.starts != fresh.starts { check(false, "diverged after edit at \(loc)"); break }
        check(change.start <= index.count, "change start in range")
    }
    equal(LineIndex("" as NSString).count, 1)
    equal(LineIndex("a\n" as NSString).count, 2)
    equal(LineIndex("a\nb" as NSString).line(at: 2), 1)
}

// MARK: - Highlighting

let samples: [(String, String)] = [
    ("sample.ts", try! String(contentsOf: repo.appendingPathComponent("test/sample.ts"), encoding: .utf8)),
    ("a.py", try! String(contentsOf: repo.appendingPathComponent("test/a.py"), encoding: .utf8)),
    ("a.c", try! String(contentsOf: repo.appendingPathComponent("test/a.c"), encoding: .utf8)),
    ("a.swift", try! String(contentsOf: repo.appendingPathComponent("test/a.swift"), encoding: .utf8)),
    ("page.html", "<!doctype html>\n<html>\n<head>\n<style>\nbody { color: red; }\n</style>\n<script>\nconst x = `a ${1 + 2}`; // hi\n</script>\n</head>\n<body class=\"x\">\n<!-- comment -->\n<p>Hello</p>\n</body>\n</html>\n"),
    ("notes.md", "# Title\n\nSome *emphasis* and `code`.\n\n```js\nconst a = 1 /* c */\n```\n\n- item\n"),
]

test("detects languages from names and contents") {
    let h = EditorEngine.highlighter
    let o = Highlighter.Options()
    equal(h.detectLanguage(name: "x.ts", code: "", options: o), "typescript")
    equal(h.detectLanguage(name: "Dockerfile", code: "", options: o), "docker")
    equal(h.detectLanguage(name: ".env", code: "", options: o), "dotenv")
    equal(h.detectLanguage(name: "run", code: "#!/bin/bash\necho", options: o), "shellscript")
    equal(h.detectLanguage(name: "notes.txt", code: "hello", options: o), "")
}

test("editor colours match Quick Look's for whole files") {
    for (name, code) in samples {
        let h = Harness(code, name: name)
        h.editor.finishHighlighting()
        let editorColors = h.colors()
        // Quick Look's path (shikiTokens) on the same text, applied the same way.
        var options = Settings().options(dark: h.editor.isDark)
        options.transparent = false
        guard let result = EditorEngine.highlighter.highlight(code: code, name: name, options: options) else { check(false, "no QL result for \(name)"); continue }
        let palette = Palette(ui: result.ui, isDark: result.dark)
        var ql = [NSColor?](repeating: palette.fg, count: (code as NSString).length)
        var i = 0
        while i + 3 < result.spans.count {
            let s = result.spans[i], l = result.spans[i + 1], ci = result.spans[i + 2]
            if ci >= 0 { for k in s..<min(s + l, ql.count) { ql[k] = NSColor(cssHex: result.colors[ci]) } }
            i += 4
        }
        var mismatches = 0
        var firstMismatch = -1
        let ns = code as NSString
        for k in 0..<ql.count {
            let qc = ql[k]?.usingColorSpace(.sRGB)
            let ec = ((h.tv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: k, effectiveRange: nil) ?? h.tv.textStorage?.attribute(.foregroundColor, at: k, effectiveRange: nil)) as? NSColor)?.usingColorSpace(.sRGB)
            let ch = ns.character(at: k)
            if ch == 0x20 || ch == 0x0A || ch == 0x09 { continue }   // whitespace colour is invisible
            if let qc, let ec, abs(qc.redComponent - ec.redComponent) + abs(qc.greenComponent - ec.greenComponent) + abs(qc.blueComponent - ec.blueComponent) > 0.02 {
                mismatches += 1
                if firstMismatch < 0 { firstMismatch = k }
            }
        }
        check(mismatches == 0, "\(name): \(mismatches) characters coloured differently, first at \(firstMismatch): \(firstMismatch >= 0 ? ns.substring(with: NSRange(location: max(0, firstMismatch - 10), length: min(30, ns.length - max(0, firstMismatch - 10)))) : "")")
        check(Set(editorColors).count > 2, "\(name) has several colours")
    }
}

test("incremental re-highlighting equals highlighting from scratch") {
    var rng = SystemRandomNumberGenerator()
    let inserts = ["/*", "*/", "\"", "'", "`", "{", "}", "\n", "// x", "#", "<!--", "-->", "\"\"\"", "abc", " ", "\n\n", "${", "<div>"]
    for (name, code) in samples {
        let h = Harness(code, name: name)
        h.editor.finishHighlighting()
        for round in 0..<60 {
            let len = h.tv.nsString.length
            let loc = Int.random(in: 0...len, using: &rng)
            let del = Int.random(in: 0...min(5, len - loc), using: &rng)
            h.tv.replace(NSRange(location: loc, length: del), with: inserts.randomElement(using: &rng)!)
            if round % 7 == 0 || round == 59 {
                h.editor.finishHighlighting()
                let fresh = Harness(h.text, name: name)
                fresh.editor.finishHighlighting()
                if h.colors() != fresh.colors() {
                    let a = h.colors(), b = fresh.colors()
                    let k = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                    check(false, "\(name) round \(round): colours differ at \(k) of \(a.count)")
                    break
                }
            }
        }
    }
}

test("typing keeps highlighting current without a full pass") {
    let h = Harness("const a = 1\nconst b = 2\n", name: "x.ts")
    h.editor.finishHighlighting()
    let before = h.colors()
    h.tv.setSelectedRange(NSRange(location: 0, length: 0))
    h.type("/*")
    // Everything after the opened comment changes colour within the synchronous budget for a small file.
    let after = h.colors()
    check(after[10] != before[10], "text after /* is recoloured")
    h.command(#selector(NSResponder.deleteBackward(_:)))
    h.command(#selector(NSResponder.deleteBackward(_:)))
    h.editor.finishHighlighting()
    equal(h.colors(), before, "back to the original colours")
}

// MARK: - Typing behaviour

test("auto-closing brackets and quotes, overtyping, pair delete") {
    let h = Harness("", name: "x.ts")
    h.type("f(")
    equal(h.marked, "f(|)")
    h.type("a")
    equal(h.marked, "f(a|)")
    h.type(")")
    equal(h.marked, "f(a)|", "overtypes the closer")
    h.set("x|")
    h.type("[")
    h.command(#selector(NSResponder.deleteBackward(_:)))
    equal(h.marked, "x|", "backspace removes the empty pair")
    h.set("it|")
    h.type("'")
    equal(h.marked, "it'|", "no pair after a word character")
    h.set("a = |")
    h.type("\"")
    equal(h.marked, "a = \"|\"")
    h.set("|word")
    h.type("(")
    equal(h.marked, "(|word", "no pair before a word")
    h.set("x = |value|;")
    h.type("[")
    equal(h.marked, "x = [|value|];", "wraps the selection")
    let plain = Harness("", name: "notes.txt")
    plain.type("(")
    equal(plain.marked, "(|", "plain text doesn't auto-close")
    // One undo removes an auto-closed pair.
    h.set("|")
    h.type("{")
    h.tv.undoManager?.undo()
    equal(h.text, "", "undo removes the pair")
}

test("auto-indent on Enter") {
    let h = Harness("", name: "x.ts")
    h.set("function f() {|}")
    h.type("\n")
    equal(h.marked, "function f() {\n    |\n}")
    h.set("    if (x) {|")
    h.type("\n")
    equal(h.marked, "    if (x) {\n        |")
    h.set("    foo();|")
    h.type("\n")
    equal(h.marked, "    foo();\n    |")
    let py = Harness("", name: "a.py")
    py.set("def f():|")
    py.type("\n")
    equal(py.marked, "def f():\n    |")
    // Typing a closing bracket on a blank line outdents it to its opener.
    h.set("if (x) {\n        |")
    h.type("}")
    equal(h.marked, "if (x) {\n}|")
}

test("tab, shift-tab and backspace use tab stops") {
    let h = Harness("", name: "x.ts")
    h.set("ab|")
    h.type("\t")
    equal(h.marked, "ab  |", "tab inserts to the next tab stop")
    h.set("        |x")
    h.command(#selector(NSResponder.deleteBackward(_:)))
    equal(h.marked, "    |x", "backspace in indentation deletes to the previous stop")
    h.set("|a\nb|\nc")
    h.type("\t")
    equal(h.text, "    a\n    b\nc", "tab indents selected lines")
    h.command(#selector(NSResponder.insertBacktab(_:)))
    equal(h.text, "a\nb\nc", "shift-tab outdents")
    let tabs = Harness("\tfoo()\n\tbar()\n", name: "x.go")
    equal(tabs.tv.indentUnit, "\t", "detects tab indentation")
    let two = Harness("a:\n  b:\n    c: 1\n  d: 2\n", name: "x.yaml")
    equal(two.tv.indentUnit, "  ", "detects two-space indentation")
}

test("smart home and line end") {
    let h = Harness("", name: "x.ts")
    h.set("    let x = 1|")
    h.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
    equal(h.marked, "    |let x = 1")
    h.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
    equal(h.marked, "|    let x = 1")
    h.command(#selector(NSResponder.moveToEndOfLine(_:)))
    equal(h.marked, "    let x = 1|")
    h.set("    let |x = 1")
    h.command(#selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)))
    equal(h.marked, "    |let |x = 1")
}

test("clicking or dragging below the last line starts at the end of the text") {
    let h = Harness("let a = 1\nlet bb = 2\nfoo()", name: "x.ts")
    let clip = h.editor.scrollView.contentView
    check(clip is TextClipView, "the editor's clip view is a TextClipView")
    check(h.tv.frame.height >= clip.bounds.height, "the text view fills the visible area")
    /// Mouse down in `view` at `p` (its coordinates), optionally dragged to `q`; the drag and mouse up are queued first,
    /// so the text view's tracking loop picks them up.
    func mouse(_ view: NSView, at p: NSPoint, dragTo q: NSPoint? = nil) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        if let q { NSApp.postEvent(event(.leftMouseDragged, q), atStart: false) }
        NSApp.postEvent(event(.leftMouseUp, q ?? p), atStart: false)
        view.mouseDown(with: event(.leftMouseDown, p))
    }
    let below = NSPoint(x: 20, y: clip.bounds.maxY - 20)
    h.set("|let a = 1\nlet bb = 2\nfoo()")
    mouse(h.tv, at: below)
    equal(h.marked, "let a = 1\nlet bb = 2\nfoo()|", "click below the text")
    // A strip of the clip view the text view doesn't cover acts as text too.
    h.set("|let a = 1\nlet bb = 2\nfoo()")
    h.window.makeFirstResponder(nil)
    mouse(clip, at: below)
    equal(h.marked, "let a = 1\nlet bb = 2\nfoo()|", "click on the clip view")
    check(h.window.firstResponder === h.tv, "a click on the clip view focuses the text")
    let line2 = h.tv.layoutManager!.lineFragmentRect(forGlyphAt: 12, effectiveRange: nil).offsetBy(dx: h.tv.textContainerOrigin.x, dy: h.tv.textContainerOrigin.y)
    mouse(clip, at: below, dragTo: NSPoint(x: line2.minX + 1, y: line2.midY))
    equal(h.marked, "let a = 1\n|let bb = 2\nfoo()|", "drag from below the text to the start of line 2")
}

test("copy and cut without a selection take the whole line") {
    let h = Harness("", name: "x.ts")
    h.set("one\ntw|o\nthree")
    h.tv.copy(nil)
    equal(NSPasteboard.general.string(forType: .string), "two\n")
    h.set("one\nthree|")
    h.tv.paste(nil)
    equal(h.text, "one\ntwo\nthree", "full-line paste goes above the current line")
    h.set("a\nb|b\nc")
    h.tv.cut(nil)
    equal(h.text, "a\nc")
    h.set("x\r\ny|")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("p\r\nq", forType: .string)
    h.tv.paste(nil)
    equal(h.text, "x\r\nyp\nq", "pasted CRLF becomes LF")
}

// MARK: - Line commands

test("toggle line comment") {
    let h = Harness("", name: "x.ts")
    h.set("    |a();\n\n    b();|")
    h.shortcut("cmd+/")
    equal(h.text, "    // a();\n\n    // b();")
    h.shortcut("cmd+/")
    equal(h.text, "    a();\n\n    b();")
    h.set("x|")
    h.shortcut("cmd+/")
    equal(h.marked, "// x|")
    let py = Harness("", name: "a.py")
    py.set("|print(1)")
    py.shortcut("cmd+/")
    equal(py.text, "# print(1)")
    let html = Harness("", name: "a.html")
    html.set("|<p>x</p>|")
    html.shortcut("cmd+/")
    equal(html.text, "<!-- <p>x</p> -->", "markup falls back to block comments")
    html.tv.setSelectedRange(NSRange(location: 0, length: (html.text as NSString).length))
    html.shortcut("cmd+/")
    equal(html.text, "<p>x</p>")
}

test("toggle block comment") {
    let h = Harness("", name: "x.ts")
    h.set("a |b| c")
    h.shortcut("shift+opt+a")
    equal(h.text, "a /* b */ c")
    h.tv.setSelectedRange(NSRange(location: 2, length: 7))
    h.shortcut("shift+opt+a")
    equal(h.text, "a b c")
    h.set("|")
    h.shortcut("shift+opt+a")
    equal(h.marked, "/* | */")
}

test("move, copy and delete lines") {
    let h = Harness("", name: "x.ts")
    h.set("a\nb|\nc")
    h.shortcut("opt+up")
    equal(h.marked, "b|\na\nc")
    h.shortcut("opt+down")
    h.shortcut("opt+down")
    equal(h.marked, "a\nc\nb|")
    h.shortcut("opt+up")
    equal(h.marked, "a\nb|\nc")
    h.shortcut("shift+opt+down")
    equal(h.marked, "a\nb\nb|\nc")
    h.shortcut("shift+opt+up")
    equal(h.marked, "a\nb\nb|\nb\nc")
    h.shortcut("cmd+shift+k")
    equal(h.text, "a\nb\nb\nc")
    h.set("a\nb\nc|")
    h.shortcut("cmd+shift+k")
    equal(h.marked, "a\nb|")
    h.set("|x\ny|\nz")
    h.shortcut("opt+down")
    equal(h.text, "z\nx\ny", "moves a multi-line block")
    h.tv.undoManager?.undo()
    equal(h.text, "x\ny\nz", "undo restores")
}

test("insert line above/below, expand line selection, join lines") {
    let h = Harness("", name: "x.ts")
    h.set("    a|bc\nd")
    h.shortcut("cmd+enter")
    equal(h.marked, "    abc\n    |\nd")
    h.set("    a|bc")
    h.shortcut("cmd+shift+enter")
    equal(h.marked, "    |\n    abc")
    h.set("a\nb|b\nc")
    h.shortcut("cmd+l")
    equal(h.marked, "a\n|bb\n|c")
    h.shortcut("cmd+l")
    equal(h.marked, "a\n|bb\nc|")
    h.set("a|\n    b\nc")
    h.shortcut("ctrl+j")
    equal(h.marked, "a b|\nc")
}

test("indent, outdent, sort, trim, convert indentation") {
    let h = Harness("", name: "x.ts")
    h.set("|a\nb|")
    h.shortcut("cmd+]")
    equal(h.text, "    a\n    b")
    h.shortcut("cmd+[")
    equal(h.text, "a\nb")
    h.set("c\na\nb")
    h.tv.sortLinesAscending(nil)
    equal(h.text, "a\nb\nc")
    h.set("a  \nb\t\nc|")
    h.tv.trimTrailingWhitespace(nil)
    equal(h.text, "a\nb\nc")
    h.set("        x\n    y|")
    h.tv.convertIndentation(toTabs: true)
    equal(h.text, "\t\tx\n\ty")
}

test("brackets: match and jump") {
    let h = Harness("", name: "x.ts")
    h.set("f(a, [b]|)")
    let m = h.tv.bracketMatch(at: h.sel.location)
    check(m?.0 == 5 && m?.1 == 7, "matches [ ] before the caret, got \(String(describing: m))")
    h.set("f(|a, b)")
    h.shortcut("cmd+shift+\\")
    equal(h.marked, "f(a, b|)")
    h.shortcut("cmd+shift+\\")
    equal(h.marked, "f|(a, b)")
    h.set("{ x(|) }")
    check(h.tv.enclosingBrackets(at: 4)?.0 == 3, "innermost enclosing pair")
}

// MARK: - Multiple cursors

test("cmd+d adds occurrences; typing edits every cursor; undo") {
    let h = Harness("", name: "x.ts")
    h.set("let fo|o = foo + foo;")
    h.shortcut("cmd+d")
    equal(h.marked, "let |foo| = foo + foo;", "first cmd+d selects the word")
    h.shortcut("cmd+d")
    h.shortcut("cmd+d")
    equal(h.tv.carets.count, 3)
    h.type("bar")
    equal(h.text, "let bar = bar + bar;")
    h.command(#selector(NSResponder.deleteBackward(_:)))
    equal(h.text, "let ba = ba + ba;")
    h.tv.undoManager?.undo()
    h.tv.undoManager?.undo()
    h.tv.undoManager?.undo()
    h.tv.undoManager?.undo()
    equal(h.text, "let foo = foo + foo;", "undo restores the original")
}

test("select all occurrences, cursors above/below, moving and escaping") {
    let h = Harness("", name: "x.ts")
    h.set("a|x|a ax ax")
    h.shortcut("cmd+shift+l")
    equal(h.tv.carets.count, 3)
    h.type("y")
    equal(h.text, "aya ay ay")
    h.set("ab|c\ndef\nghi")
    h.shortcut("cmd+opt+down")
    h.shortcut("cmd+opt+down")
    equal(h.tv.carets.count, 3)
    h.type("-")
    equal(h.text, "ab-c\nde-f\ngh-i")
    h.command(#selector(NSResponder.moveRight(_:)))
    h.type("+")
    equal(h.text, "ab-c+\nde-f+\ngh-i+")
    h.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
    h.type("#")
    equal(h.text, "#ab-c+\n#de-f+\n#gh-i+")
    h.command(#selector(NSResponder.cancelOperation(_:)))
    equal(h.tv.carets.count, 0, "escape collapses to one cursor")
    h.set("|a\nb\nc|")
    h.tv.addCursorsToLineEnds(nil)
    h.type(";")
    equal(h.text, "a;\nb;\nc;")
    // Paste distributes lines over cursors.
    h.set("|x\ny")
    h.shortcut("cmd+opt+down")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("1\n2", forType: .string)
    h.tv.paste(nil)
    equal(h.text, "1x\n2y")
    // Clicking (a plain selection change) leaves multi-cursor mode.
    h.tv.setSelectedRange(NSRange(location: 0, length: 0))
    equal(h.tv.carets.count, 0)
}

// MARK: - Find and replace

test("find model options") {
    let text = "Foo foo food FOO f.o" as NSString
    equal(FindModel.matches(of: FindQuery(text: "foo"), in: text).matches.count, 4)
    equal(FindModel.matches(of: FindQuery(text: "foo", caseSensitive: true), in: text).matches.count, 2)
    equal(FindModel.matches(of: FindQuery(text: "foo", wholeWord: true), in: text).matches.count, 3)
    equal(FindModel.matches(of: FindQuery(text: "f.o", regex: true), in: text).matches.count, 5)
    equal(FindModel.matches(of: FindQuery(text: "f.o"), in: text).matches.count, 1)
    equal(FindModel.matches(of: FindQuery(text: "^foo", regex: true), in: "foo\nfoo x foo" as NSString).matches.count, 2, "^ matches at line starts")
    check(FindModel.matches(of: FindQuery(text: "(", regex: true), in: text).error != nil, "invalid regex reported")
    equal(FindModel.matches(of: FindQuery(text: "foo"), in: text, range: NSRange(location: 4, length: 8)).matches.count, 2, "scoped")
    let r = NSRange(location: 0, length: 9)
    equal(FindModel.replacement(for: r, in: "John Smith" as NSString, query: FindQuery(text: "(\\w+) (\\w+)", regex: true), with: "$2, $1", preserveCase: false), "Smith, John")
    equal(FindModel.replacement(for: NSRange(location: 0, length: 1), in: "a" as NSString, query: FindQuery(text: "a", regex: true), with: "x\\ny", preserveCase: false), "x\ny")
    equal(FindModel.replacement(for: NSRange(location: 0, length: 3), in: "FOO" as NSString, query: FindQuery(text: "foo"), with: "bar", preserveCase: true), "BAR")
    equal(FindModel.replacement(for: NSRange(location: 0, length: 3), in: "Foo" as NSString, query: FindQuery(text: "foo"), with: "bar", preserveCase: true), "Bar")
    equal(FindModel.replacement(for: NSRange(location: 0, length: 3), in: "foo" as NSString, query: FindQuery(text: "foo"), with: "Bar", preserveCase: true), "bar")
    equal(FindModel.replacement(for: NSRange(location: 0, length: 1), in: "a" as NSString, query: FindQuery(text: "a"), with: "$1", preserveCase: false), "$1", "literal mode keeps $")
}

test("find widget: seed, navigate, replace, replace all, select all, in selection") {
    let h = Harness("alpha beta alpha gamma alpha\nbeta alpha", name: "x.txt")
    h.tv.setSelectedRange(NSRange(location: 1, length: 0))
    h.editor.showFind()
    check(h.editor.isFindVisible, "widget shown")
    equal(h.editor.findWidget?.query.text, "alpha", "seeded with the word at the cursor")
    equal(h.editor.findCounterText, "1 of 4")
    equal(h.sel, NSRange(location: 0, length: 5))
    h.editor.findNext()
    equal(h.sel, NSRange(location: 11, length: 5))
    equal(h.editor.findCounterText, "2 of 4")
    h.editor.findPrevious()
    h.editor.findPrevious()
    equal(h.editor.findCounterText, "4 of 4", "wraps around backwards")
    h.editor.findNext()
    equal(h.editor.findCounterText, "1 of 4")
    h.editor.findWidget?.replaceText = "omega"
    h.editor.replaceCurrent()
    equal(h.text, "omega beta alpha gamma alpha\nbeta alpha")
    equal(h.editor.findCounterText, "1 of 3")
    spin(0.01)   // closes the undo group, as the next event would
    equal(h.editor.replaceAll(), 3)
    equal(h.text, "omega beta omega gamma omega\nbeta omega")
    equal(h.editor.findCounterText, "No results")
    h.tv.undoManager?.undo()
    equal(h.text, "omega beta alpha gamma alpha\nbeta alpha", "replace all is one undo step")
    h.editor.findWidget?.query = FindQuery(text: "beta")
    h.editor.refreshFind(reveal: true)
    h.editor.selectAllMatches()
    equal(h.tv.carets.count, 2)
    h.type("B")
    equal(h.text, "omega B alpha gamma alpha\nB alpha")
    // Find in selection.
    h.tv.setSelectedRange(NSRange(location: 0, length: 20))
    h.editor.findWidget?.query = FindQuery(text: "a")
    h.editor.setFindInSelection(true)
    let inScope = h.tv.findMatches.allSatisfy { NSMaxRange($0) <= 20 }
    check(inScope && !h.tv.findMatches.isEmpty, "matches only inside the selection")
    h.editor.setFindInSelection(false)
    // Regex + whole word toggles through the menu shortcuts.
    h.editor.findWidget?.query = FindQuery(text: "alpha|gamma")
    h.editor.toggleFindOption(\.regexToggle)
    equal(h.editor.findWidget?.regexToggle.isOn, true)
    equal(h.editor.findCounterText.hasSuffix("of 4"), true, "regex alternation: \(h.editor.findCounterText)")
    h.editor.hideFind()
    check(!h.editor.isFindVisible && h.tv.findMatches.isEmpty, "closing clears highlights")
}

test("matches follow edits while the widget is open") {
    let h = Harness("x x x", name: "x.txt")
    h.editor.showFind()
    h.editor.findWidget?.query = FindQuery(text: "x")
    h.editor.refreshFind(reveal: false)
    equal(h.tv.findMatches.count, 3)
    h.tv.setSelectedRange(NSRange(location: 5, length: 0))
    h.type(" x")
    check(waitUntil { h.tv.findMatches.count == 4 }, "recounted after typing")
}

// MARK: - Files

test("load and save keep encoding, BOM, line endings, permissions and symlinks") {
    let dir = scratch.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let crlf = dir.appendingPathComponent("crlf.txt")
    try Data("a\r\nb\r\n".utf8).write(to: crlf)
    var loaded = try TextFile.load(crlf)
    equal(loaded.text, "a\nb\n")
    equal(loaded.format.lineEnding, .crlf)
    try TextFile.save(loaded.text + "c", format: loaded.format, to: crlf)
    equal(try Data(contentsOf: crlf), Data("a\r\nb\r\nc".utf8))

    let bom = dir.appendingPathComponent("bom.txt")
    try Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8)).write(to: bom)
    loaded = try TextFile.load(bom)
    equal(loaded.format.encoding, .utf8BOM)
    try TextFile.save(loaded.text, format: loaded.format, to: bom)
    equal(try Data(contentsOf: bom), Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8)))

    let cz = dir.appendingPathComponent("cz.txt")
    try "Příliš žluťoučký kůň".data(using: .windowsCP1250)!.write(to: cz)
    loaded = try TextFile.load(cz)
    equal(loaded.format.encoding, .windows1250)
    equal(loaded.text, "Příliš žluťoučký kůň")
    try TextFile.save(loaded.text, format: loaded.format, to: cz)
    equal(try Data(contentsOf: cz), "Příliš žluťoučký kůň".data(using: .windowsCP1250)!)
    check((try? TextFile.encode("emoji 😀", format: loaded.format)) == nil, "unencodable text is refused")

    let utf16 = dir.appendingPathComponent("u16.txt")
    try (Data([0xFF, 0xFE]) + "hi\n".data(using: .utf16LittleEndian)!).write(to: utf16)
    loaded = try TextFile.load(utf16)
    equal(loaded.format.encoding, .utf16LE)
    equal(loaded.text, "hi\n")

    let script = dir.appendingPathComponent("run.sh")
    try Data("#!/bin/sh\necho 1\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try TextFile.save("#!/bin/sh\necho 2\n", format: TextFormat(), to: script)
    equal((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755, "keeps the executable bit")

    let link = dir.appendingPathComponent("link.sh")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
    try TextFile.save("echo 3\n", format: TextFormat(), to: link)
    check((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "symlink is still a symlink")
    equal(try String(contentsOf: script, encoding: .utf8), "echo 3\n", "writes through the symlink")

    let bin = dir.appendingPathComponent("x.bin")
    try Data([0, 1, 2, 3, 0, 255]).write(to: bin)
    check((try? TextFile.load(bin)) == nil, "binary refused")
    equal(TextFile.detectLineEnding("a\nb\r\nc\n"), .lf)
    equal(TextFile.detectLineEnding("a\r\nb\r\nc\n"), .crlf)
}

// MARK: - Windows

func makeProject() throws -> URL {
    let root = scratch.appendingPathComponent("project-\(UUID().uuidString.prefix(6))")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("src/util"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("node_modules/lib"), withIntermediateDirectories: true)
    try Data("export const a = 1\n".utf8).write(to: root.appendingPathComponent("src/a.ts"))
    try Data("export const b = 2\n".utf8).write(to: root.appendingPathComponent("src/b.ts"))
    try Data("def f():\n    pass\n".utf8).write(to: root.appendingPathComponent("src/util/helpers.py"))
    try Data("# Readme\n".utf8).write(to: root.appendingPathComponent("README.md"))
    try Data("dist/\n*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    try Data("x".utf8).write(to: root.appendingPathComponent("debug.log"))
    try Data("module.exports = 1".utf8).write(to: root.appendingPathComponent("node_modules/lib/index.js"))
    try Data("".utf8).write(to: root.appendingPathComponent(".DS_Store"))
    return root
}

var promptAnswers: [EditorWindowController.SaveChoice] = []
var promptCount = 0
EditorWindowController.unsavedChangesPrompt = { _, _, done in
    promptCount += 1
    done(promptAnswers.isEmpty ? .cancel : promptAnswers.removeFirst())
}

test("explorer lists the folder like VS Code") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    let names = w.explorer.root!.loadedChildren().map(\.name)
    equal(names, ["node_modules", "src", ".gitignore", "debug.log", "README.md"], "folders first, .git and .DS_Store hidden")
    w.open(root.appendingPathComponent("src/util/helpers.py"))
    let outline = w.explorer.outlineView
    let selected = outline.item(atRow: outline.selectedRow) as? FileNode
    equal(selected?.name, "helpers.py", "the open file is revealed and selected")
    equal(w.window?.title, "helpers.py")
    equal(w.window?.subtitle, "", "just the file name, no subtitle")
    equal(w.editor.language.id, "python")
    w.window?.close()
}

test("switching files asks about unsaved changes") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    let a = root.appendingPathComponent("src/a.ts"), b = root.appendingPathComponent("src/b.ts")
    w.open(a)
    w.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    w.editor.textView.insertText("// edited\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    check(w.editor.isDirty, "dirty after typing")
    check(w.window?.isDocumentEdited == true, "window shows edited")
    equal(w.window?.title, "a.ts")
    check(w.showsUnsavedDot, "unsaved dot shown")
    equal(w.window?.subtitle, "", "no subtitle")
    promptCount = 0
    promptAnswers = [.cancel]
    w.open(b)
    equal(promptCount, 1, "asked once")
    equal(w.fileURL?.lastPathComponent, "a.ts", "cancel stays on the file")
    check(w.editor.isDirty, "still dirty")
    promptAnswers = [.discard]
    w.open(b)
    equal(w.fileURL?.lastPathComponent, "b.ts", "don't save switches")
    equal(try String(contentsOf: a, encoding: .utf8), "export const a = 1\n", "discarded changes not written")
    w.editor.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    promptAnswers = [.save]
    w.open(a)
    equal(w.fileURL?.lastPathComponent, "a.ts", "save switches")
    equal(try String(contentsOf: b, encoding: .utf8), "xexport const b = 2\n", "saved before switching")
    // Undoing back to the saved text clears the dirty state.
    w.editor.textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
    check(w.editor.isDirty, "dirty")
    w.editor.textView.undoManager?.undo()
    check(!w.editor.isDirty, "clean again after undo")
    promptCount = 0
    w.open(b)
    equal(promptCount, 0, "no prompt when clean")
    // Back / forward between files.
    w.goBack(nil)
    equal(w.fileURL?.lastPathComponent, "a.ts")
    w.goForward(nil)
    equal(w.fileURL?.lastPathComponent, "b.ts")
    w.previousFileInFolder(nil)
    equal(w.fileURL?.lastPathComponent, "a.ts")
    w.window?.close()
}

test("cmd+s writes the open file") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    let a = root.appendingPathComponent("src/a.ts")
    w.open(a)
    w.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    w.editor.textView.insertText("// saved\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    guard let item = MenuTools.item(for: "cmd+s"), let action = item.action else { check(false, "no cmd+s"); return }
    check(w.validateMenuItem(item), "save enabled")
    w.showWindow(nil)
    spin(0.2)
    let dot = w.unsavedDot
    check(w.showsUnsavedDot && dot.window === w.window, "dot in the titlebar")
    if let title = dot.superview?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "a.ts" }) {
        let t = title.convert(title.bounds, to: nil), d = dot.convert(dot.bounds, to: nil)
        check(d.minX > t.maxX && d.minX - t.maxX < 12, "dot right after the title: title \(t), dot \(d)")
        check(abs(d.midY - t.midY) < 2, "dot centred on the title line: title \(t), dot \(d)")
    } else { check(false, "dot sits beside the title field") }
    check(w.editor.textView.tryToPerform(action, with: item), "cmd+s handled")
    equal(try String(contentsOf: a, encoding: .utf8), "// saved\nexport const a = 1\n", "written to disk")
    check(!w.editor.isDirty, "clean after save")
    check(!w.showsUnsavedDot, "dot gone after save")
    w.window?.close()
}

test("closing a window with unsaved changes asks") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    w.showWindow(nil)
    w.open(root.appendingPathComponent("README.md"))
    w.editor.textView.insertText("more", replacementRange: NSRange(location: NSNotFound, length: 0))
    promptAnswers = [.cancel]
    w.window?.performClose(nil)
    check(w.window?.isVisible == true, "cancel keeps the window")
    promptAnswers = [.discard]
    w.window?.performClose(nil)
    check(w.window?.isVisible == false, "don't save closes it")
}

test("close file asks about unsaved changes and returns to the start page") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    w.showWindow(nil)
    let readme = root.appendingPathComponent("README.md")
    w.open(readme)
    w.editor.textView.insertText("more", replacementRange: NSRange(location: NSNotFound, length: 0))
    promptCount = 0
    promptAnswers = [.cancel]
    w.closeFile(nil)
    equal(promptCount, 1, "asked")
    check(w.showsFile && w.editor.isDirty, "cancel keeps the file and its changes")
    promptAnswers = [.discard]
    w.closeFile(nil)
    check(!w.showsFile && w.fileURL == nil, "don't save closes the file")
    check(!w.editor.emptyView.isHidden && w.editor.emptyView.hasFolder, "start page for the folder")
    check(w.window?.isVisible == true, "the window stays")
    check(w.window?.isDocumentEdited == false, "no longer shown as edited")
    check(w.window?.firstResponder !== w.editor.textView, "the hidden text view does not keep the focus")
    equal(w.window?.title, "Squint")
    equal(w.rootURL?.path, root.resolvingSymlinksInPath().path, "the folder stays")
    equal(try String(contentsOf: readme, encoding: .utf8), "# Readme\n", "discarded changes not written")
    w.goBack(nil)
    equal(w.fileURL?.lastPathComponent, "README.md", "back reopens the closed file")
    w.editor.textView.insertText("saved ", replacementRange: NSRange(location: NSNotFound, length: 0))
    promptAnswers = [.save]
    w.closeFile(nil)
    check(!w.showsFile, "save closes the file")
    let saved = try String(contentsOf: readme, encoding: .utf8)
    check(saved.contains("saved "), "saved before closing: \(saved)")
    // An untitled file closes the same way.
    w.newUntitled()
    w.editor.textView.insertText("draft", replacementRange: NSRange(location: NSNotFound, length: 0))
    promptCount = 0
    promptAnswers = [.discard]
    w.closeFile(nil)
    equal(promptCount, 1, "asked about the untitled file")
    check(!w.showsFile, "untitled file closed")
    // With nothing open, Close File closes the window.
    w.closeFile(nil)
    check(w.window?.isVisible == false, "closes the window")
}

test("new window, opening a folder and dock reopen show the start page; session records closed files") {
    let root = try makeProject()
    let d = AppDelegate()
    d.newWindow(nil)
    equal(d.editors.count, 1)
    let w = d.editors[0]
    check(!w.showsFile && !w.editor.emptyView.isHidden && !w.editor.emptyView.hasFolder, "new window: start page without a folder")
    d.openFolder(root)
    equal(d.editors.count, 1, "the empty window takes the folder")
    check(!w.showsFile && w.editor.emptyView.hasFolder, "opening a folder opens no file")
    d.openFile(root.appendingPathComponent("src/a.ts"))
    equal(w.fileURL?.lastPathComponent, "a.ts")
    // ⌘W from the editor closes the file, then the window.
    let item = MenuTools.item(for: "cmd+w")
    check(item?.action == #selector(EditorWindowController.closeFile(_:)), "cmd+w is Close File")
    check(w.editor.textView.tryToPerform(#selector(EditorWindowController.closeFile(_:)), with: item), "cmd+w handled from the editor")
    check(!w.showsFile && w.window?.isVisible == true, "cmd+w closed the file, not the window")
    // The session keeps the folder but no file.
    UserDefaults.standard.removeObject(forKey: "Session")
    equal(d.applicationShouldTerminate(NSApp), .terminateNow)
    let session = UserDefaults.standard.array(forKey: "Session") as? [[String: String]] ?? []
    equal(session.count, 1)
    equal(session.first?["root"], root.resolvingSymlinksInPath().path)
    check(session.first?["file"] == nil, "no file recorded: \(session)")
    UserDefaults.standard.removeObject(forKey: "Session")
    check(w.editor.textView.tryToPerform(#selector(EditorWindowController.closeFile(_:)), with: item), "cmd+w again")
    check(w.window?.isVisible == false, "then closes the window")
    check(waitUntil { d.editors.isEmpty }, "window forgotten")
    _ = d.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    equal(d.editors.count, 1, "dock reopen opens a window")
    check(d.editors.first.map { !$0.showsFile && $0.rootURL == nil } == true, "with the start page")
    d.editors.forEach { $0.window?.close() }
}

test("untitled files are saved through the save panel") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    w.newUntitled()
    equal(w.window?.title, "Untitled")
    w.editor.textView.insertText("print('hi')\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    let target = root.appendingPathComponent("new.py")
    EditorWindowController.savePanel = { _, dir, name, done in
        equal(name, "Untitled.txt")
        equal(dir?.path, root.resolvingSymlinksInPath().path)
        done(target)
    }
    w.saveDocument(nil)
    equal(try String(contentsOf: target, encoding: .utf8), "print('hi')\n")
    equal(w.fileURL?.lastPathComponent, "new.py")
    equal(w.editor.language.id, "python", "language re-detected from the new name")
    check(!w.editor.isDirty, "clean after save")
    w.window?.close()
}

test("external changes reload clean files and refresh the tree") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    let a = root.appendingPathComponent("src/a.ts")
    w.open(a)
    spin(0.3)
    try Data("export const a = 42\n".utf8).write(to: a)
    check(waitUntil(4) { w.editor.text == "export const a = 42\n" }, "reloaded after an external write")
    try Data("new".utf8).write(to: root.appendingPathComponent("src/c.ts"))
    check(waitUntil(4) { w.explorer.node(for: root.appendingPathComponent("src"))?.children?.contains { $0.name == "c.ts" } == true }, "new file appears in the tree")
    w.window?.close()
}

test("explorer: new file, rename, delete") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    w.showWindow(nil)
    w.open(root.appendingPathComponent("src/a.ts"))
    w.explorer.newFile(nil)
    w.explorer.commitEditing(name: "fresh.ts")
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("src/fresh.ts").path), "created next to the selected file")
    equal(w.fileURL?.lastPathComponent, "fresh.ts", "new file is opened")
    if let node = w.explorer.node(for: root.appendingPathComponent("src/fresh.ts")) {
        w.explorer.beginRename(node)
        w.explorer.commitEditing(name: "renamed.ts")
    }
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("src/renamed.ts").path), "renamed on disk")
    equal(w.fileURL?.lastPathComponent, "renamed.ts", "the open file follows the rename")
    ExplorerViewController.confirmDelete = { _, _, done in done(true) }
    if let node = w.explorer.node(for: root.appendingPathComponent("src/renamed.ts")) { w.explorer.delete(node) }
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("src/renamed.ts").path), "moved to the Trash")
    check(!w.editor.hasDocument, "editor closes the deleted file")
    w.window?.close()
}

test("explorer: refresh and file changes keep a pending new item; New File / New Folder switch its kind") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    w.showWindow(nil)
    let e = w.explorer
    let rootCount = e.root!.loadedChildren().count
    func fieldEditor() -> NSTextView? { w.window?.firstResponder as? NSTextView }
    func placeholderRow() -> Int { e.editingItem.map { e.outlineView.row(forItem: $0) } ?? -1 }
    e.newFolder(nil)
    check(fieldEditor() != nil, "typing in the new row")
    fieldEditor()?.insertText("stuff", replacementRange: NSRange(location: NSNotFound, length: 0))
    fieldEditor()?.setSelectedRange(NSRange(location: 2, length: 1))
    for _ in 0..<3 { e.refresh(nil) }
    equal(e.editingItem?.isPlaceholder, true, "still naming the new item after refresh")
    equal(e.editingText, "stuff", "typed name kept")
    equal(fieldEditor()?.selectedRange(), NSRange(location: 2, length: 1), "selection kept")
    check(placeholderRow() >= 0, "placeholder row shown")
    equal(e.outlineView.numberOfRows, rootCount + 1, "tree intact")
    e.newFile(nil)
    equal(e.editingItem?.isDirectory, false, "switched to a file")
    equal(e.editingText, "stuff", "name kept after switching")
    check(fieldEditor() != nil, "field keeps focus")
    let firstFile = e.root!.loadedChildren().firstIndex { !$0.isDirectory && !$0.isPlaceholder }!
    equal(placeholderRow(), firstFile - 1, "file placeholder sits above the first file")
    e.newFolder(nil)
    equal(e.editingItem?.isDirectory, true, "switched back to a folder")
    equal(placeholderRow(), 0, "folder placeholder at the top")
    try Data("x".utf8).write(to: root.appendingPathComponent("external.txt"))
    spin(0.5)
    equal(e.editingText, "stuff", "file system events don't disturb the edit")
    e.commitEditing(name: "made")
    var isDir: ObjCBool = false
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("made").path, isDirectory: &isDir) && isDir.boolValue, "folder created")
    check(e.editingItem == nil, "edit ended")
    check(waitUntil(3) { e.node(for: root.appendingPathComponent("external.txt")) != nil }, "deferred change applied after the edit")
    check(!e.root!.loadedChildren().contains { $0.isPlaceholder }, "no placeholder left behind")

    // Esc cancels cleanly; the tree stays.
    let rows = e.outlineView.numberOfRows
    e.newFile(nil)
    fieldEditor()?.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    e.refresh(nil)
    fieldEditor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    check(e.editingItem == nil, "cancelled")
    check(!e.root!.loadedChildren().contains { $0.isPlaceholder }, "placeholder removed")
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path), "nothing created")
    equal(e.outlineView.numberOfRows, rows, "tree intact after cancel")

    // Renaming survives a refresh too.
    if let node = e.node(for: root.appendingPathComponent("README.md")) {
        e.beginRename(node)
        e.refresh(nil)
        check(e.editingItem === node, "still renaming after refresh")
        equal(e.editingText, "README.md", "name kept")
        e.commitEditing(name: "READ.md")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("READ.md").path), "renamed")
    }
    w.window?.close()
}

test("go to file: index skips ignored files; fuzzy ranking") {
    let root = try makeProject()
    let files = FileIndex.scan(root.resolvingSymlinksInPath())
    check(files.contains("src/util/helpers.py"), "indexes nested files")
    check(!files.contains { $0.hasPrefix("node_modules") }, "skips node_modules")
    check(!files.contains("debug.log"), "honours .gitignore patterns")
    check(!files.contains { $0.hasPrefix(".git/") }, "skips .git")
    let candidates = ["App/Editor/EditorViewController.swift", "App/Editor/EditorTextView.swift", "Extension/PreviewViewController.swift", "App/AppDelegate.swift"]
    let ranked = candidates.compactMap { c in Fuzzy.matchPath("evc", path: c).map { (c, $0.score) } }.sorted { $0.1 > $1.1 }
    equal(ranked.first?.0, "App/Editor/EditorViewController.swift")
    check(Fuzzy.matchPath("zzz", path: "abc") == nil, "non-matches rejected")
    let w = EditorWindowController(root: root)
    w.showWindow(nil)
    w.open(root.appendingPathComponent("src/a.ts"))
    w.goToFile(nil)
    check(waitUntil { w.fileIndex?.isReady == true }, "index loads")
    w.quickOpen?.query = "help"
    equal(w.quickOpen?.visibleItems.first?.title, "helpers.py")
    w.quickOpen?.accept()
    equal(w.fileURL?.lastPathComponent, "helpers.py")
    w.goToLine(nil)
    w.quickOpen?.query = ":2"
    w.quickOpen?.accept()
    equal(w.editor.textView.lines.line(at: w.editor.textView.selectedRange().location), 1, "went to line 2")
    w.window?.close()
}

test("app routes files to the window whose folder contains them") {
    let root = try makeProject()
    let d = AppDelegate()
    d.openFolder(root)
    equal(d.editors.count, 1)
    check(d.editors[0].isSidebarVisible, "opening a folder shows the explorer")
    d.openFile(root.appendingPathComponent("src/util/helpers.py"))
    equal(d.editors.count, 1, "same window")
    equal(d.editors[0].fileURL?.lastPathComponent, "helpers.py")
    let other = try makeProject()
    d.openFile(other.appendingPathComponent("README.md"))
    equal(d.editors.count, 2, "a file elsewhere gets a new window")
    equal(d.editors[1].rootURL?.path, other.resolvingSymlinksInPath().path, "rooted at the file's folder")
    check(!d.editors[1].isSidebarVisible, "opening a file starts with the explorer hidden")
    d.editors.forEach { $0.window?.close() }
}

// MARK: - Menus

test("menu shortcuts are unique and every action has a handler") {
    var seen: [String: String] = [:]
    for item in MenuTools.allItems() where !item.keyEquivalent.isEmpty {
        let mods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        let key = "\(mods.rawValue)-\(item.keyEquivalent.lowercased())"
        if let other = seen[key] { check(false, "\(item.title) and \(other) share a shortcut") }
        seen[key] = item.title
    }
    let responders: [AnyClass] = [EditorTextView.self, EditorWindowController.self, AppDelegate.self, NSSplitViewController.self, NSWindow.self, NSApplication.self, NSTextView.self]
    for item in MenuTools.allItems() {
        guard let action = item.action, item.submenu == nil else { continue }
        let handled = item.target?.responds(to: action) == true || responders.contains { $0.instancesRespond(to: action) } || action == Selector(("undo:")) || action == Selector(("redo:"))
        check(handled, "nobody handles \(item.title) (\(action))")
    }
    for spec in ["cmd+s", "cmd+p", "cmd+f", "cmd+opt+f", "cmd+g", "cmd+shift+g", "cmd+/", "cmd+d", "cmd+shift+l", "cmd+l", "cmd+b",
                 "cmd+shift+e", "ctrl+g", "opt+up", "opt+down", "shift+opt+up", "shift+opt+down", "cmd+shift+k", "cmd+enter",
                 "cmd+shift+enter", "cmd+]", "cmd+[", "cmd+opt+up", "cmd+opt+down", "shift+opt+i", "shift+opt+a", "cmd+shift+\\",
                 "opt+z", "cmd+=", "cmd+-", "cmd+0", "ctrl+-", "ctrl+shift+-", "cmd+opt+c", "cmd+opt+w", "cmd+opt+r", "cmd+n", "cmd+w", "cmd+shift+w", "ctrl+j"] {
        check(MenuTools.item(for: spec) != nil, "missing shortcut \(spec)")
    }
}

test("window-level shortcuts work with focus in the editor") {
    let root = try makeProject()
    let w = EditorWindowController(root: root)
    w.showWindow(nil)
    w.open(root.appendingPathComponent("src/a.ts"))
    let h = w.editor.textView
    func send(_ spec: String) {
        guard let item = MenuTools.item(for: spec), let action = item.action else { check(false, "no \(spec)"); return }
        check((w.window?.firstResponder ?? h).tryToPerform(action, with: item), "\(spec) handled")
    }
    send("cmd+f")
    check(w.editor.isFindVisible, "cmd+f opens find")
    check(!w.isSidebarVisible, "the sidebar starts hidden")
    send("cmd+b")
    check(w.isSidebarVisible, "cmd+b shows the sidebar")
    send("cmd+b")
    check(!w.isSidebarVisible, "cmd+b hides it again")
    send("opt+z")
    check(w.editor.wraps, "opt+z wraps")
    let size = w.editor.font.pointSize
    send("cmd+=")
    equal(w.editor.font.pointSize, size + 1, "zoom in")
    send("cmd+0")
    equal(w.editor.font.pointSize, size, "reset zoom")
    w.window?.close()
}

// MARK: - Performance

test("large file: open, highlight, type") {
    var big = ""
    let unit = try String(contentsOf: repo.appendingPathComponent("test/sample.ts"), encoding: .utf8)
    while (big as NSString).length < 1_500_000 { big += unit }
    let lines = big.components(separatedBy: "\n").count
    var start = Date()
    let h = Harness(big, name: "big.ts")
    let openMs = Date().timeIntervalSince(start) * 1000
    start = Date()
    h.editor.finishHighlighting()
    let fullMs = Date().timeIntervalSince(start) * 1000
    h.tv.setSelectedRange(NSRange(location: 10, length: 0))
    start = Date()
    for _ in 0..<50 { h.type("x") }
    let typeMs = Date().timeIntervalSince(start) * 1000 / 50
    print("    \(lines) lines: open \(Int(openMs)) ms, full highlight \(Int(fullMs)) ms, \(String(format: "%.2f", typeMs)) ms per keystroke")
    check(openMs < 1500, "opens quickly")
    check(typeMs < 16, "typing stays under a frame")
}

if ProcessInfo.processInfo.environment["PROFILE"] != nil {
    test("profile tokenizer") {
        var big = ""
        let unit = try String(contentsOf: repo.appendingPathComponent("test/sample.ts"), encoding: .utf8)
        while (big as NSString).length < 1_500_000 { big += unit }
        let hl = EditorEngine.highlighter
        var o = Highlighter.Options(); o.transparent = false
        _ = hl.openDocument(id: 999, text: big, language: "typescript", options: o)
        var start = Date()
        var spans = 0
        var t: Highlighter.Tokens
        hl.findCalls = 0; hl.findTime = 0
        repeat { t = hl.tokenizeDocument(id: 999, budget: 100000); spans += t.spans.count } while t.more
        print("    JS tokenize: \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(spans / 5) spans, onig find calls \(hl.findCalls) in \(Int(hl.findTime * 1000)) ms")
        start = Date()
        _ = hl.highlight(code: big, name: "big.ts", options: { var x = o; x.highlightLines = 1_000_000; return x }())
        print("    QL full tokenize: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        func time(_ label: String, _ h: Harness, _ body: () -> Void) {
            h.tv.setSelectedRange(NSRange(location: 10, length: 0))
            let t = Date()
            for _ in 0..<50 { body() }
            print("    \(label): \(String(format: "%.2f", Date().timeIntervalSince(t) * 1000 / 50)) ms")
        }
        let plain = Harness(big, name: "big.txt")
        time("plain insertText", plain) { plain.type("x") }
        time("raw storage edit", plain) { plain.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x") }
        let ts = Harness(big, name: "big.ts")
        ts.editor.finishHighlighting()
        time("ts insertText (before full highlight)", ts) { ts.type("x") }
        ts.editor.finishHighlighting()
        time("ts insertText (after)", ts) { ts.type("x") }
        time("ts tokenize only", ts) { ts.editor.finishHighlighting() }
        let wrapped = Harness(big, name: "big.ts")
        wrapped.editor.finishHighlighting()
        wrapped.editor.setWrapping(true)
        time("ts insertText, wrapping", wrapped) { wrapped.type("x") }
        for size in [50_000, 200_000, 500_000] {
            var text = ""
            while (text as NSString).length < size { text += unit }
            let h = Harness(text, name: "mid.ts")
            h.editor.finishHighlighting()
            time("ts insertText \(text.components(separatedBy: "\n").count) lines", h) { h.type("x") }
            let lm = h.tv.layoutManager!
            print("      laid out up to \(lm.firstUnlaidCharacterIndex()) of \(h.tv.nsString.length), noncontiguous \(lm.hasNonContiguousLayout)")
            time("  raw edit", h) { h.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x") }
            time("  tokenize", h) { h.editor.finishHighlighting() }
            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: h.tv.nsString.length), actualCharacterRange: nil)
            time("  insertText after invalidating layout", h) { h.type("x") }
            print("      laid out up to \(lm.firstUnlaidCharacterIndex())")
        }
        ts.tv.onLinesChanged = nil
        time("ts raw storage edit, colorer detached", ts) { ts.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x") }
        ts.tv.textStorage?.delegate = nil
        time("ts raw storage edit, no delegate", ts) { ts.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x") }
        let lm = ts.tv.layoutManager!
        ts.tv.textStorage?.removeLayoutManager(lm)
        time("ts raw storage edit, no layout manager", ts) { ts.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x") }
        ts.tv.textStorage?.addLayoutManager(lm)
        ts.tv.textStorage?.delegate = ts.tv
        time("ts raw storage edit (edit forwarded)", ts) { ts.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x") }
        time("ts raw edit + tokenize", ts) { ts.tv.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x"); ts.editor.finishHighlighting() }
        time("ts replace() (shouldChange/didChange)", ts) { ts.tv.replace(NSRange(location: 10, length: 0), with: "x") }
        _ = hl.openDocument(id: 998, text: big, language: "typescript", options: o)
        repeat { t = hl.tokenizeDocument(id: 998, budget: 100000) } while t.more
        hl.editDocument(id: 998, start: 0, removed: 1, text: "import x")
        var tt = Date()
        t = hl.tokenizeDocument(id: 998, budget: 6)
        print("    after one-line edit: ranges \(t.ranges) more \(t.more) in \(String(format: "%.2f", Date().timeIntervalSince(tt) * 1000)) ms")
        hl.editDocument(id: 998, start: 5, removed: 1, text: "  const zz = 1")
        tt = Date()
        t = hl.tokenizeDocument(id: 998, budget: 6)
        print("    after line-5 edit: ranges \(t.ranges) more \(t.more) in \(String(format: "%.2f", Date().timeIntervalSince(tt) * 1000)) ms")
        tt = Date()
        for _ in 0..<50 { hl.editDocument(id: 998, start: 0, removed: 1, text: "import x") }
        print("    editDocument x50: \(String(format: "%.3f", Date().timeIntervalSince(tt) * 1000 / 50)) ms each")
        tt = Date()
        for _ in 0..<50 { _ = hl.tokenizeDocument(id: 998, budget: 6) }
        print("    tokenizeDocument x50 (nothing dirty): \(String(format: "%.3f", Date().timeIntervalSince(tt) * 1000 / 50)) ms each")
        tt = Date()
        for _ in 0..<50 { hl.ctx.evaluateScript("1+1") }
        print("    evaluateScript x50: \(String(format: "%.3f", Date().timeIntervalSince(tt) * 1000 / 50)) ms each")
    }
}

print("\n\(checks) checks, \(failures) failures")
try? FileManager.default.removeItem(at: scratch)
exit(failures == 0 ? 0 : 1)
