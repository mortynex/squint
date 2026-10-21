import Foundation
import JavaScriptCore

/// Editor documents: the JS side keeps every line with the grammar state at its end, so an edit is re-tokenized only
/// from the edited line until the state converges (see `shikiDocTokenize` in js/entry.js).
extension Highlighter {
    struct DocumentInfo: Decodable {
        /// Grammar id, empty for plain text.
        let lang: String
        let dark: Bool
        /// The theme's colour map: token colours index into it (index 1 is the default foreground).
        let colors: [String?]
        let ui: [String: String]
    }

    struct Tokens {
        /// Lines that were re-tokenized; the caller resets them to the default style before applying `spans`.
        var ranges: [Range<Int>] = []
        /// Flat (line, column, length, colour, fontStyle) quintuples for non-default tokens, in UTF-16 units.
        var spans: [Int32] = []
        /// Dirty lines remain: call again (later) to continue.
        var more = false
    }

    /// Grammar id detected from a file name and the start of its contents ("" for plain text).
    func detectLanguage(name: String, code: String, options: Options) -> String {
        lock.lock()
        defer { lock.unlock() }
        var opts = options.json
        opts["name"] = name
        ctx.setObject(String(code.prefix(4000)), forKeyedSubscript: "__code" as NSString)
        ctx.setObject(opts, forKeyedSubscript: "__opts" as NSString)
        guard let plan = ctx.evaluateScript("shikiPlan(__code, __opts)")?.toString(),
              let p = try? JSONSerialization.jsonObject(with: Data(plan.utf8)) as? [String: String] else { return "" }
        return p["lang"] ?? ""
    }

    /// Starts tokenizing `text` as document `id` (any previous document with that id is replaced).
    func openDocument(id: Int, text: String, language: String, options: Options) -> DocumentInfo? {
        lock.lock()
        defer { lock.unlock() }
        ctx.setObject("", forKeyedSubscript: "__code" as NSString)
        ctx.setObject(options.json, forKeyedSubscript: "__opts" as NSString)
        guard let plan = ctx.evaluateScript("shikiPlan(__code, __opts)")?.toString(),
              let p = try? JSONSerialization.jsonObject(with: Data(plan.utf8)) as? [String: String],
              let theme = p["theme"] else { return nil }
        load("themes/\(theme).js")
        if !language.isEmpty { load("langs/\(language).js") }
        let result = ctx.objectForKeyedSubscript("shikiDocOpen")?.call(withArguments: [id, language, theme, text])?.toString()
        strings.removeAll(keepingCapacity: true)
        guard let result, let data = result.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocumentInfo.self, from: data)
    }

    /// Lines `start ..< start + removed` were replaced by `text` (the new lines joined by "\n").
    func editDocument(id: Int, start: Int, removed: Int, text: String) {
        lock.lock()
        defer { lock.unlock() }
        ctx.objectForKeyedSubscript("shikiDocEdit")?.call(withArguments: [id, start, removed, text])
    }

    /// Tokenizes dirty lines for about `budget` milliseconds.
    func tokenizeDocument(id: Int, budget: Double) -> Tokens {
        lock.lock()
        defer { lock.unlock() }
        var tokens = Tokens()
        let context = ctx.jsGlobalContextRef
        guard let value = ctx.objectForKeyedSubscript("shikiDocTokenize")?.call(withArguments: [id, budget]),
              let object = JSValueToObject(context, value.jsValueRef, nil) else { return tokens }
        strings.removeAll(keepingCapacity: true)
        var exception: JSValueRef?
        let count = JSObjectGetTypedArrayLength(context, object, &exception)
        let offset = JSObjectGetTypedArrayByteOffset(context, object, &exception)
        guard count >= 2, let raw = JSObjectGetTypedArrayBytesPtr(context, object, &exception) else { return tokens }
        let values = UnsafeBufferPointer(start: (raw + offset).assumingMemoryBound(to: Int32.self), count: count)
        tokens.more = values[0] != 0
        let rangeCount = Int(values[1])
        guard 2 + 2 * rangeCount <= count else { return tokens }
        for r in 0..<rangeCount {
            let from = Int(values[2 + 2 * r]), to = Int(values[3 + 2 * r])
            if to > from { tokens.ranges.append(from..<to) }
        }
        tokens.spans = Array(values[(2 + 2 * rangeCount)...])
        return tokens
    }

    func closeDocument(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        ctx.objectForKeyedSubscript("shikiDocClose")?.call(withArguments: [id])
    }
}
