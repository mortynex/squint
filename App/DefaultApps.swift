import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Which app opens the file types the Quick Look extension previews.
///
/// Squint's Info.plist claims all of them (rank Owner/Default), so it becomes the default for every type no other app
/// was chosen for, without asking. Taking a type away from another app makes macOS ask the user to confirm that one
/// type, so it is only done for an app the user picks in Settings, never in bulk.
enum DefaultApps {
    static let bundleID = "com.martin.Squint"
    static var backupURL: URL { Settings.fileURL.deletingLastPathComponent().appendingPathComponent("previous-default-apps.json") }

    /// Types the preview handles that are usually binary and have a better default (Finder runs executables, Script
    /// Editor opens compiled scripts, property lists are often binary, …), plus the catch-all public.item.
    /// public.data (extensionless files) can't be set: LaunchServices rejects it.
    static let excluded: Set<String> = ["public.item", "public.data", "public.unix-executable", "com.apple.applescript.script", "com.apple.property-list",
                                        "com.sun.java-class", "com.sun.java-web-start", "org.khronos.gltf"]

    static var appBundle = Bundle.main.bundleURL

    /// The types Squint wants to open: its document types except the Alternate ones (TeX, left to a TeX app) and
    /// `excluded`, limited to the types files actually resolve to (other declarations of the same extensions don't
    /// matter, and changing them would only mean more confirmations).
    static func contentTypes() -> [String] {
        let plist = appBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let docs = dict["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        let types = docs.filter { ($0["LSHandlerRank"] as? String) != "Alternate" }.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        return Array(NSOrderedSet(array: types)).compactMap { $0 as? String }.filter { !excluded.contains($0) && isReachable($0) }
    }

    /// Whether some file resolves to `id`: one of its extensions maps to it (types without extensions only count
    /// when they are system types such as public.plain-text).
    static func isReachable(_ id: String) -> Bool {
        guard !id.hasPrefix("dyn."), let type = UTType(id) else { return false }
        let extensions = type.tags[.filenameExtension] ?? []
        if extensions.isEmpty { return id.hasPrefix("public.") }
        return extensions.contains { UTType(filenameExtension: $0)?.identifier == id }
    }

    static func currentHandler(for type: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(type as CFString, .all)?.takeRetainedValue() as String?
    }

    static func isSquint(_ bundle: String?) -> Bool { bundle?.lowercased() == bundleID.lowercased() }

    /// Another app and the types it opens instead of Squint.
    struct OtherApp: Identifiable {
        let bundleID: String
        let name: String
        let types: [String]
        var id: String { bundleID }

        /// ".py, .tex, …" from the types' extensions (or descriptions).
        var summary: String {
            var seen = Set<String>()
            let names = types.compactMap { t -> String? in
                let name = UTType(t)?.preferredFilenameExtension.map { "." + $0 } ?? UTType(t)?.localizedDescription ?? t
                return seen.insert(name).inserted ? name : nil
            }
            return names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
        }
    }

    struct Status {
        var squint = 0
        var total = 0
        var others: [OtherApp] = []
    }

    static func status() -> Status {
        var status = Status()
        var byApp: [String: [String]] = [:]
        for type in contentTypes() {
            guard let handler = currentHandler(for: type) else { continue }
            status.total += 1
            if isSquint(handler) { status.squint += 1 } else { byApp[handler, default: []].append(type) }
        }
        status.others = byApp.map { id, types in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            return OtherApp(bundleID: id, name: name, types: types)
        }.sorted { $0.types.count > $1.types.count }
        return status
    }

    /// Makes Squint the default for `types` (macOS asks to confirm each one), remembering the previous apps.
    static func claim(_ types: [String]) {
        var backup = loadBackup()
        for type in types {
            let current = currentHandler(for: type)
            if !isSquint(current), backup[type] == nil, let current { backup[type] = current }
            LSSetDefaultRoleHandlerForContentType(type as CFString, .all, bundleID as CFString)
        }
        saveBackup(backup)
    }

    /// Gives the types Squint took back to their previous apps.
    static func restore() {
        var backup = loadBackup()
        for (type, handler) in backup where isSquint(currentHandler(for: type)) {
            LSSetDefaultRoleHandlerForContentType(type as CFString, .all, handler as CFString)
            backup[type] = nil
        }
        saveBackup(backup)
    }

    /// Types Squint took over from other apps that can be given back.
    static var restorable: Int { loadBackup().keys.filter { isSquint(currentHandler(for: $0)) }.count }

    private static func loadBackup() -> [String: String] {
        ((try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: backupURL))) ?? [:]).filter { !$0.value.isEmpty && !isSquint($0.value) }
    }

    private static func saveBackup(_ backup: [String: String]) {
        try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if backup.isEmpty { try? FileManager.default.removeItem(at: backupURL) } else { try? encoder.encode(backup).write(to: backupURL) }
    }
}
