import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var settingsWindow: NSWindow?
    private(set) var editors: [EditorWindowController] = []
    private var openedFilesAtLaunch = false

    /// The JS engine, grammars and themes live inside the Quick Look extension bundle.
    static var engineResources: URL { EditorEngine.resources }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(recentDelegate: self)
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
        if !openedFilesAtLaunch && isDefaultLaunch { restoreSession() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock click with no editor window on screen (Settings may be): a minimized one comes back, else a new window
    /// with the start page.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !editors.contains(where: { $0.window?.isVisible == true }) else { return true }
        if let w = editors.last { w.showWindow(nil) } else { makeWindow(root: nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSession()
        let dirty = editors.filter { $0.editor.hasDocument && $0.editor.isDirty }
        guard !dirty.isEmpty else { return .terminateNow }
        confirm(dirty) { ok in NSApp.reply(toApplicationShouldTerminate: ok) }
        return .terminateLater
    }

    private func confirm(_ windows: [EditorWindowController], done: @escaping (Bool) -> Void) {
        guard let first = windows.first else { done(true); return }
        first.showWindow(nil)
        first.confirmDiscard { [weak self] ok in
            guard ok else { done(false); return }
            self?.confirm(Array(windows.dropFirst()), done: done)
        }
    }

    private func saveSession() {
        let session = editors.compactMap { w -> [String: String]? in
            guard w.rootURL != nil || w.fileURL != nil else { return nil }
            var entry: [String: String] = [:]
            entry["root"] = w.rootURL?.path
            entry["file"] = w.fileURL?.path
            if let frame = w.window?.frame { entry["frame"] = NSStringFromRect(frame) }
            return entry
        }
        UserDefaults.standard.set(session, forKey: "Session")
    }

    private func restoreSession() {
        let session = UserDefaults.standard.array(forKey: "Session") as? [[String: String]] ?? []
        for entry in session {
            let root = entry["root"].map { URL(fileURLWithPath: $0) }
            if let root, !FileManager.default.fileExists(atPath: root.path) { continue }
            let w = makeWindow(root: root)
            if let frame = entry["frame"] { w.window?.setFrame(NSRectFromString(frame), display: false) }
            if let file = entry["file"], FileManager.default.fileExists(atPath: file) { w.open(URL(fileURLWithPath: file)) }
            else if root != nil { w.setSidebarVisible(true) }
        }
        if editors.isEmpty { makeWindow(root: nil) }
    }

    // MARK: - Opening

    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && url.pathExtension != "app" { openFolder(url) } else { openFile(url) }
        }
    }

    /// Opens a file in the window whose folder contains it (the innermost one), else in a new window showing the
    /// file's folder.
    func openFile(_ url: URL, line: Int? = nil) {
        if let w = editors.filter({ $0.contains(url) }).max(by: { ($0.rootURL?.path.count ?? 0) < ($1.rootURL?.path.count ?? 0) }) {
            w.showWindow(nil)
            w.open(url, line: line)
        } else if let w = editors.first(where: { $0.rootURL == nil && !$0.editor.hasDocument }) {
            w.setRoot(url.deletingLastPathComponent())
            w.showWindow(nil)
            w.open(url, line: line)
        } else {
            makeWindow(root: url.deletingLastPathComponent()).open(url, line: line)
        }
    }

    func openFolder(_ url: URL) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let w = editors.first(where: { $0.rootURL == canonical }) { w.setSidebarVisible(true); w.showWindow(nil); return }
        if let w = editors.first(where: { $0.rootURL == nil && !$0.editor.hasDocument }) {
            w.setRoot(canonical)
            w.setSidebarVisible(true)
            w.showWindow(nil)
            return
        }
        makeWindow(root: canonical).setSidebarVisible(true)
    }

    @discardableResult
    func makeWindow(root: URL?) -> EditorWindowController {
        let w = EditorWindowController(root: root)
        w.onClose = { [weak self] closed in
            DispatchQueue.main.async { self?.editors.removeAll { $0 === closed } }
        }
        if let window = w.window {
            if let last = editors.last?.window, last.isVisible {
                window.setFrame(last.frame, display: false)
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            } else if let saved = UserDefaults.standard.string(forKey: "EditorWindowFrame") {
                window.setFrame(NSRectFromString(saved), display: false)
            } else {
                window.center()
            }
        }
        editors.append(w)
        w.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return w
    }

    var keyEditor: EditorWindowController? {
        editors.first { $0.window === NSApp.keyWindow } ?? editors.first { $0.window === NSApp.mainWindow }
    }

    // MARK: - Actions

    @objc func newWindow(_ sender: Any?) { makeWindow(root: nil) }

    /// ⌘N with no editor window in front.
    @objc func newDocument(_ sender: Any?) { makeWindow(root: nil).newUntitled() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.directoryURL = keyEditor?.rootURL
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
    }

    @objc func openFolderPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let w = self?.keyEditor, w.rootURL == nil { w.setRoot(url); w.setSidebarVisible(true) } else { self?.openFolder(url) }
        }
    }

    /// Close File (⌘W) in a window without files (Settings, About): closes the window.
    @objc func closeFile(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(closeFile(_:)) ? NSApp.keyWindow != nil : true
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Squint Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let fm = FileManager.default
        for url in NSDocumentController.shared.recentDocumentURLs where fm.fileExists(atPath: url.path) {
            let item = NSMenuItem(title: (url.path as NSString).abbreviatingWithTildeInPath, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No Recent Items", action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "").target = self
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open([url]) }
    }

    @objc private func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }
}
