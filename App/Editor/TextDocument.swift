import Foundation

/// How a file's text is stored on disk; in memory the text always uses "\n".
struct TextFormat: Equatable {
    enum LineEnding: String, CaseIterable {
        case lf = "LF", crlf = "CRLF", cr = "CR"
        var string: String { self == .lf ? "\n" : self == .crlf ? "\r\n" : "\r" }
    }

    enum Encoding: String, CaseIterable {
        case utf8 = "UTF-8", utf8BOM = "UTF-8 with BOM", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE"
        case windows1250 = "Windows 1250", windows1252 = "Windows 1252", latin1 = "ISO 8859-1"

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8, .utf8BOM: return .utf8
            case .utf16LE: return .utf16LittleEndian
            case .utf16BE: return .utf16BigEndian
            case .windows1250: return .windowsCP1250
            case .windows1252: return .windowsCP1252
            case .latin1: return .isoLatin1
            }
        }

        var bom: [UInt8] {
            switch self {
            case .utf8BOM: return [0xEF, 0xBB, 0xBF]
            case .utf16LE: return [0xFF, 0xFE]
            case .utf16BE: return [0xFE, 0xFF]
            default: return []
            }
        }
    }

    var encoding = Encoding.utf8
    var lineEnding = LineEnding.lf
}

/// Reading and writing text files for the editor.
enum TextFile {
    static let maxBytes = TextLoader.editorMaxBytes

    enum LoadError: LocalizedError {
        case binary, tooLarge(Int)
        var errorDescription: String? {
            switch self {
            case .binary: return TextLoader.LoadError.binary.errorDescription
            case .tooLarge(let size): return "The file is too large to open (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            }
        }
    }

    struct Loaded {
        var text: String
        var format: TextFormat
        var modificationDate: Date?
    }

    static func load(_ url: URL) throws -> Loaded {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes { throw LoadError.tooLarge(size) }
        let data = try Data(contentsOf: url)
        var (text, format) = try decode(data)
        format.lineEnding = detectLineEnding(text)
        if text.utf16.contains(0x0D) { text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        return Loaded(text: text, format: format, modificationDate: attributes?[.modificationDate] as? Date)
    }

    static func decode(_ data: Data) throws -> (String, TextFormat) {
        var format = TextFormat()
        let bytes = [UInt8](data.prefix(3))
        func string(_ body: Data, _ encoding: String.Encoding) -> String? { String(data: body, encoding: encoding) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let s = string(data.dropFirst(3), .utf8) {
            format.encoding = .utf8BOM
            return (s, format)
        }
        if bytes.starts(with: [0xFF, 0xFE]), let s = string(data.dropFirst(2), .utf16LittleEndian) {
            format.encoding = .utf16LE
            return (s, format)
        }
        if bytes.starts(with: [0xFE, 0xFF]), let s = string(data.dropFirst(2), .utf16BigEndian) {
            format.encoding = .utf16BE
            return (s, format)
        }
        if data.prefix(8192).contains(0) { throw LoadError.binary }
        if let s = string(data, .utf8) { return (s, format) }
        for encoding in [TextFormat.Encoding.windows1250, .latin1] {
            if let s = string(data, encoding.stringEncoding) { format.encoding = encoding; return (s, format) }
        }
        throw LoadError.binary
    }

    /// The file's line ending: the most common one, LF when there are none.
    static func detectLineEnding(_ text: String) -> TextFormat.LineEnding {
        var lf = 0, crlf = 0, cr = 0
        var previousCR = false
        for unit in text.utf16.prefix(1_000_000) {
            if unit == 0x0A { if previousCR { crlf += 1; cr -= 1 } else { lf += 1 } }
            if unit == 0x0D { cr += 1 }
            previousCR = unit == 0x0D
        }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }

    enum SaveError: LocalizedError {
        case unencodable(TextFormat.Encoding)
        var errorDescription: String? {
            if case .unencodable(let e) = self { return "The text contains characters that can't be saved in \(e.rawValue)." }
            return nil
        }
    }

    static func encode(_ text: String, format: TextFormat) throws -> Data {
        let body = format.lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.string)
        guard let encoded = body.data(using: format.encoding.stringEncoding, allowLossyConversion: false) else {
            throw SaveError.unencodable(format.encoding)
        }
        return Data(format.encoding.bom) + encoded
    }

    /// Writes in place (not by replacing the file), so permissions, extended attributes, hard links and symlinks
    /// are kept, as VS Code and most editors do. Returns the new modification date.
    @discardableResult
    static func save(_ text: String, format: TextFormat, to url: URL) throws -> Date? {
        let data = try encode(text, format: format)
        let target = url.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: target.path) {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            try data.write(to: target)
        }
        return (try? FileManager.default.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
