import Foundation

/// A find query with VS Code's options.
struct FindQuery: Equatable {
    var text = ""
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

enum FindModel {
    static let maxMatches = 20_000

    struct Result {
        var matches: [NSRange] = []
        var error: String?
        var truncated = false
    }

    /// The regex for a query: literal text is escaped, whole words are fenced by look-arounds (so they also work
    /// for text that starts or ends with punctuation), ^ and $ match at line boundaries.
    static func expression(for query: FindQuery) throws -> NSRegularExpression {
        var pattern = query.regex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        if query.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    static func matches(of query: FindQuery, in text: NSString, range: NSRange? = nil) -> Result {
        var result = Result()
        guard !query.text.isEmpty else { return result }
        let scope = range ?? NSRange(location: 0, length: text.length)
        if !query.regex && !query.wholeWord {
            // Plain substring search is much faster than a regex.
            var search = scope
            let options: NSString.CompareOptions = query.caseSensitive ? [.literal] : [.caseInsensitive]
            while search.length > 0 {
                let found = text.range(of: query.text, options: options, range: search)
                if found.location == NSNotFound { break }
                if result.matches.count == maxMatches { result.truncated = true; break }
                result.matches.append(found)
                search = NSRange(location: NSMaxRange(found), length: NSMaxRange(scope) - NSMaxRange(found))
            }
            return result
        }
        do {
            let regex = try expression(for: query)
            regex.enumerateMatches(in: text as String, options: [.withTransparentBounds, .withoutAnchoringBounds], range: scope) { match, _, stop in
                guard let match, match.range.length > 0 else { return }
                if result.matches.count == maxMatches { result.truncated = true; stop.pointee = true; return }
                result.matches.append(match.range)
            }
        } catch {
            result.error = "Invalid regular expression"
        }
        return result
    }

    /// The text that replaces `match`: regex templates support $0–$9, $& and \n, \t escapes like VS Code.
    static func replacement(for match: NSRange, in text: NSString, query: FindQuery, with replace: String, preserveCase: Bool) -> String {
        var out = replace
        if query.regex, let regex = try? expression(for: query),
           let result = regex.firstMatch(in: text as String, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds], range: NSRange(location: match.location, length: text.length - match.location)) {
            out = regex.replacementString(for: result, in: text as String, offset: 0, template: template(from: replace))
        }
        if preserveCase { out = applyCase(of: text.substring(with: match), to: out) }
        return out
    }

    /// Converts VS Code replacement syntax to an NSRegularExpression template.
    static func template(from replace: String) -> String {
        var out = ""
        let chars = Array(replace)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "n": out += "\n"
                case "t": out += "\t"
                case "\\": out += "\\\\"
                case "$": out += "\\$"
                default: out += "\\" + String(n)
                }
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count, chars[i + 1] == "&" { out += "$0"; i += 2; continue }
            if c == "$", i + 1 < chars.count, !chars[i + 1].isNumber { out += "\\$"; i += 1; continue }
            if c == "$", i + 1 == chars.count { out += "\\$"; i += 1; continue }
            out.append(c)
            i += 1
        }
        return out
    }

    /// VS Code's "preserve case": ALL CAPS, Capitalized and lowercase matches keep their case.
    static func applyCase(of matched: String, to replacement: String) -> String {
        let letters = matched.filter(\.isLetter)
        guard !letters.isEmpty else { return replacement }
        if letters.allSatisfy(\.isUppercase), letters.count > 1 { return replacement.uppercased() }
        if letters.allSatisfy(\.isLowercase) { return replacement.lowercased() }
        if let first = matched.first(where: \.isLetter), first.isUppercase, letters.dropFirst().allSatisfy(\.isLowercase) {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        if let first = matched.first(where: \.isLetter), first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
