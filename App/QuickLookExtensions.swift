import Foundation

/// The Quick Look preview extensions PlugInKit knows about: whether Squint's is registered and on, and which other
/// apps' extensions preview the same types (whichever macOS picks wins, so those should be off).
enum QuickLookExtensions {
    static let squintID = "com.martin.Squint.Extension"

    struct Info: Identifiable {
        let id: String
        let name: String
        let path: String
        /// Off only when the user (or `setEnabled`) turned it off; a new extension is on.
        let enabled: Bool
    }

    /// A previewer from another app that handles some of Squint's types.
    struct Competitor: Identifiable {
        let info: Info
        let sharedTypes: Int
        var id: String { info.id }
    }

    enum SquintState: Equatable {
        case on, off, missing
        /// Registered, but from another copy of Squint (e.g. a build folder or the disk image).
        case otherCopy(String)
    }

    struct Status {
        var squint = SquintState.missing
        var competitors: [Competitor] = []
    }

    static var squintAppex: URL { DefaultApps.appBundle.appendingPathComponent("Contents/PlugIns/SquintExtension.appex") }

    /// Parses `pluginkit -m -vv`: a "<flag>    <id>(<version>)" line per extension, then indented "Key = value" lines.
    static func list() -> [Info] {
        var infos: [Info] = []
        var current: (id: String, enabled: Bool, fields: [String: String])?
        func flush() {
            guard let c = current else { return }
            infos.append(Info(id: c.id, name: c.fields["Parent Name"] ?? c.fields["Display Name"] ?? c.id, path: c.fields["Path"] ?? "", enabled: c.enabled))
        }
        for line in run("/usr/bin/pluginkit", ["-m", "-vv", "-p", "com.apple.quicklook.preview"]).split(separator: "\n") {
            if line.first == "\t" {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    current?.fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if let open = line.lastIndex(of: "(") {
                flush()
                let id = line.dropFirst().prefix(upTo: open).trimmingCharacters(in: .whitespaces)
                current = (id, line.first != "-", [:])
            }
        }
        flush()
        return infos
    }

    /// Slow (runs pluginkit and reads other apps' Info.plists): call off the main thread.
    static func status() -> Status {
        var status = Status()
        let infos = list()
        if let mine = infos.first(where: { $0.id == squintID }) {
            if URL(fileURLWithPath: mine.path).resolvingSymlinksInPath() != squintAppex.resolvingSymlinksInPath() {
                status.squint = .otherCopy(mine.path)
            } else {
                status.squint = mine.enabled ? .on : .off
            }
        }
        let ours = Set(supportedTypes(squintAppex))
        status.competitors = infos.compactMap { info in
            guard info.id != squintID, info.enabled, !info.path.hasPrefix("/System/") else { return nil }
            let shared = supportedTypes(URL(fileURLWithPath: info.path)).filter { ours.contains($0) }.count
            return shared > 0 ? Competitor(info: info, sharedTypes: shared) : nil
        }.sorted { $0.sharedTypes > $1.sharedTypes }
        return status
    }

    static func supportedTypes(_ appex: URL) -> [String] {
        guard let data = try? Data(contentsOf: appex.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ext = plist["NSExtension"] as? [String: Any], let attrs = ext["NSExtensionAttributes"] as? [String: Any] else { return [] }
        return attrs["QLSupportedContentTypes"] as? [String] ?? []
    }

    /// Registers this copy's extension and turns it on, like install.sh.
    static func enableSquint() {
        _ = run("/usr/bin/pluginkit", ["-a", squintAppex.path])
        setEnabled(squintID, true)
        _ = run("/usr/bin/qlmanage", ["-r"])
    }

    static func setEnabled(_ id: String, _ on: Bool) {
        _ = run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", id])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
