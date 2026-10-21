import Foundation
import JavaScriptCore

/// Renders source code to a standalone HTML page with Shiki running inside JavaScriptCore.
/// Regex matching is done natively by Oniguruma (via onigshim) instead of in JS, for speed.
final class Highlighter {
    struct Options {
        var dark = false  // system appearance
        var light = "github-light-default"
        var darkTheme = "github-dark-default"
        var fontSize = 13
        var fontFamily = ""  // empty = system monospaced (SF Mono)
        var lineNumbers = true
        var transparent = true
        var wrap = false
        var maxLines = 20000
        var highlightLines = 1200

        var json: [String: Any] {
            ["appearance": dark ? "dark" : "light", "light": light, "dark": darkTheme, "fontSize": fontSize, "fontFamily": fontFamily,
             "lineNumbers": lineNumbers, "wrap": wrap, "maxLines": maxLines, "highlightLines": highlightLines]
        }
    }

    let resources: URL
    let ctx = JSContext()!
    private var scanners: [Int: UnsafeMutableRawPointer] = [:]
    var strings: [Int: [UInt16]] = [:]
    private var nextId = 1
    private var loaded = Set<String>()
    /// Serializes highlighting: the JS globals and the native scanner/string tables are shared state.
    let lock = NSLock()
    var findCalls = 0, findTime = 0.0

    /// Grammars loaded so far; each one stays in memory (a few MB) with its compiled regexes.
    var languageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loaded.filter { $0.hasPrefix("langs/") }.count
    }

    init(resources: URL) {
        self.resources = resources
        ctx.exceptionHandler = { _, e in NSLog("shiki js error: %@", e?.toString() ?? "?") }
        ctx.evaluateScript("var globalThis = this; var self = this; var console = {log:function(){},warn:function(){},error:function(){}};")
        installNative()
        load("core.js")
    }

    deinit { scanners.values.forEach(shim_scanner_free) }

    func load(_ path: String) {
        guard loaded.insert(path).inserted,
              let src = try? String(contentsOf: resources.appendingPathComponent(path), encoding: .utf8) else { return }
        ctx.evaluateScript(src, withSourceURL: URL(string: path))
    }

    private func installNative() {
        let makeScanner: @convention(block) ([String]) -> Int = { [unowned self] patterns in
            let allocs = patterns.map { pat -> (UnsafeMutablePointer<UInt16>, Int32) in
                let u = Array(pat.utf16)
                let p = UnsafeMutablePointer<UInt16>.allocate(capacity: max(u.count, 1))
                p.update(from: u, count: u.count)
                return (p, Int32(u.count))
            }
            let ptrs: [UnsafePointer<UInt16>?] = allocs.map { UnsafePointer($0.0) }
            let lens = allocs.map { $0.1 }
            let sc = ptrs.withUnsafeBufferPointer { shim_scanner_new($0.baseAddress, lens, Int32(ptrs.count)) }
            allocs.forEach { $0.0.deallocate() }
            let id = self.nextId; self.nextId += 1
            self.scanners[id] = sc
            return id
        }
        let makeString: @convention(block) (String) -> Int = { [unowned self] s in
            let id = self.nextId; self.nextId += 1
            self.strings[id] = Array(s.utf16)
            return id
        }
        let find: @convention(block) (Int, Int, Int) -> [Int32] = { [unowned self] sc, str, start in
            let t = Date(); defer { self.findCalls += 1; self.findTime += Date().timeIntervalSince(t) }
            guard let scanner = self.scanners[sc], let buf = self.strings[str] else { return [] }
            var out = [Int32](repeating: 0, count: 2 * 64)
            var n: Int32 = 0
            let idx = buf.withUnsafeBufferPointer { b in
                shim_scanner_find(scanner, Int32(str), b.baseAddress ?? UnsafePointer(bitPattern: 2), Int32(buf.count), Int32(start), &out, 64, &n)
            }
            if idx < 0 { return [] }
            return [idx] + out[0..<Int(2 * n)]
        }
        ctx.setObject(makeScanner, forKeyedSubscript: "__onigScanner" as NSString)
        ctx.setObject(makeString, forKeyedSubscript: "__onigString" as NSString)
        ctx.setObject(find, forKeyedSubscript: "__onigFind" as NSString)
    }

    struct Result: Decodable {
        let lang: String
        let dark: Bool
        let colors: [String]
        /// Flat [start, length, colourIndex, fontStyle, ...] in UTF-16 units; colourIndex -1 means default foreground.
        let spans: [Int]
        /// Theme colours for the UI (CSS hex strings).
        let ui: [String: String]
    }

    /// Tokenizes `code` with Shiki; the caller applies the spans to its own text.
    func highlight(code: String, name: String, options: Options) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        var opts = options.json
        opts["name"] = name
        ctx.setObject(code, forKeyedSubscript: "__code" as NSString)
        ctx.setObject(opts, forKeyedSubscript: "__opts" as NSString)
        if let plan = ctx.evaluateScript("shikiPlan(__code, __opts)")?.toString(),
           let p = try? JSONSerialization.jsonObject(with: Data(plan.utf8)) as? [String: String] {
            if let lang = p["lang"], !lang.isEmpty { load("langs/\(lang).js") }
            if let t = p["theme"] { load("themes/\(t).js") }
        }
        let json = ctx.evaluateScript("shikiTokens(__code, __opts)")?.toString()
        strings.removeAll()
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }
}
