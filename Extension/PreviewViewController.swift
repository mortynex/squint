import Cocoa
import QuickLookUI
import os

/// Quick Look preview extension: shows any text/code file highlighted with Shiki (VS Code grammars and themes).
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        preferredContentSize = NSSize(width: 900, height: 700)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let options = Settings.load().options(dark: Self.isDarkAppearance())
        let root = Self.previewView(of: url, frame: view.bounds, options: options, highlighter: Self.highlighter(),
                                    onOpenInEditor: { Self.openInEditor(url) })
        root.autoresizingMask = [.width, .height]
        view.addSubview(root)
        handler(nil)
    }

    /// The preview of `url`. A file with no text to show gets a message saying why instead: for an error Quick Look
    /// would only show its generic icon.
    static func previewView(of url: URL, frame: NSRect, options: Highlighter.Options, highlighter: Highlighter,
                            onOpenInEditor: (() -> Void)?) -> PreviewRootView {
        do {
            let loaded = try TextLoader.read(url)
            let result = highlighter.highlight(code: loaded.text, name: url.lastPathComponent, options: options)
            let notice = loaded.truncated
                ? PreviewRootView.Notice.truncated(shownBytes: loaded.shownBytes, totalBytes: loaded.totalBytes,
                                                   editorOpensAll: loaded.totalBytes <= TextLoader.editorMaxBytes)
                : nil
            return PreviewRootView(frame: frame, text: loaded.text, result: result, options: options, mode: .quickLook,
                                   notice: notice, onOpenInEditor: onOpenInEditor)
        } catch {
            // Plain text, only for the theme's colours.
            let theme = highlighter.highlight(code: "", name: "", options: options)
            let title = error is TextLoader.LoadError ? "Can't preview this file" : "Can't read this file"
            return PreviewRootView(frame: frame, text: "", result: theme, options: options, mode: .quickLook,
                                   notice: .unavailable(title: title, detail: error.localizedDescription),
                                   onOpenInEditor: onOpenInEditor)
        }
    }

    private static let log = Logger(subsystem: "com.martin.Squint.Extension", category: "OpenInEditor")

    /// Opens `url` in the Squint app that contains this extension (Squint.app/Contents/PlugIns/SquintExtension.appex),
    /// else in whichever Squint LaunchServices knows. The app isn't sandboxed, so it can read the file itself.
    /// Quick Look's preview sandbox (quicklook-preview.sb), unlike the app sandbox, doesn't allow `lsopen`: without an
    /// entitlement exception for it, LaunchServices refuses ("Sandbox: deny(1) lsopen", NSCocoaErrorDomain 256).
    private static func openInEditor(_ url: URL) {
        let bundled = Bundle(for: PreviewViewController.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = bundled.pathExtension == "app" ? bundled
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.martin.Squint")
        guard let app else {
            log.error("Open in Squint: no Squint app found")
            return
        }
        log.notice("Open in Squint: \(url.path, privacy: .public) with \(app.path, privacy: .public)")
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("Open in Squint failed: \(error, privacy: .public)") }
        }
    }

    /// Quick Look keeps the extension process alive between previews, so one highlighter is shared: the next file
    /// skips starting the JS engine, and a language seen before skips loading its grammar and compiling its regexes.
    /// Every grammar stays in memory, so after a few languages the highlighter is replaced with a fresh one.
    private static var shared: Highlighter?
    private static let sharedLock = NSLock()
    private static let maxLanguages = 8

    private static func highlighter() -> Highlighter {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let h = shared, h.languageCount < maxLanguages { return h }
        let h = Highlighter(resources: Bundle(for: PreviewViewController.self).resourceURL!)
        shared = h
        return h
    }

    private static func isDarkAppearance() -> Bool {
        if let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) { return match == .darkAqua }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
