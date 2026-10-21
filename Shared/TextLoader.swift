import Foundation

/// Reads a file as text for previewing; throws for binary files.
enum TextLoader {
    static let maxBytes = 3 * 1024 * 1024
    /// The largest file the editor opens, so a preview cut short can say whether the editor shows all of it.
    static let editorMaxBytes = 64 * 1024 * 1024

    enum LoadError: LocalizedError {
        case binary
        /// The editor's load error uses the same wording.
        var errorDescription: String? { "The file is not displayed because it is either binary or uses an unsupported text encoding." }
    }

    /// The file's text, or only its first `maxBytes` when `truncated`.
    struct Loaded {
        var text: String
        /// Bytes read, and the file's size.
        var shownBytes: Int
        var totalBytes: Int
        var truncated: Bool { shownBytes < totalBytes }
    }

    static func read(_ url: URL) throws -> Loaded {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch CocoaError.fileWriteNoPermission {
            // FileHandle reports a file it may not read as one it may not save.
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
        }
        defer { try? handle.close() }
        var data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let truncated = data.count > maxBytes
        let totalBytes = truncated ? Int((try? handle.seekToEnd()) ?? UInt64(data.count)) : data.count
        if truncated { data = data.prefix(maxBytes) }
        if data.prefix(8192).contains(0) { throw LoadError.binary }

        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        var text: String?
        // A truncated read may cut a multi-byte character in half; back off a few bytes.
        for drop in 0...(truncated ? 3 : 0) {
            if let s = String(data: body.dropLast(drop), encoding: .utf8) { text = s; break }
        }
        if text == nil { text = String(data: body, encoding: .windowsCP1250) ?? String(data: body, encoding: .isoLatin1) }
        var result = text ?? ""
        if result.utf16.contains(0x0D) { result = result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        return Loaded(text: result, shownBytes: data.count, totalBytes: totalBytes)
    }
}
