import AppKit

/// The window's content: an optional glass background behind the split view's editor pane. The sidebar item brings its
/// own glass (a sidebar material before macOS 26); stacked over the window's glass it would blur twice and look far more
/// opaque than the editor, so the window's glass stops at the sidebar and the sidebar's glass is given the same look.
final class WindowContentController: NSViewController {
    let split: NSSplitViewController
    private var background: NSView?
    private var clouds: HalftoneCloudsView?

    init(split: NSSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        view = v
        addChild(split)
        split.view.frame = v.bounds
        split.view.autoresizingMask = [.width, .height]
        v.addSubview(split.view)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        matchSidebar()
        if let clouds, let bar = (split.splitViewItems.last?.viewController as? EditorViewController)?.statusBar {
            clouds.bottomInset = bar.isHidden ? 0 : clouds.bounds.maxY - bar.convert(bar.bounds, to: clouds).minY
        }
    }

    var isGlass: Bool { background != nil }

    /// A light wash of the theme's background over the glass, so code stays readable on busy backgrounds.
    var tint: NSColor? {
        didSet {
            if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView { glass.tintColor = tint }
            matchSidebar()
        }
    }

    /// Colour of the halftone clouds over the glass (the theme's text colour, faint).
    var cloudColor: NSColor = .labelColor {
        didSet { clouds?.color = cloudColor }
    }

    /// Halftone clouds over the glass (only while there is glass).
    var showsClouds = true {
        didSet { updateClouds() }
    }

    private func updateClouds() {
        let clip = background?.superview
        guard showsClouds, let clip else {
            clouds?.removeFromSuperview()
            clouds = nil
            return
        }
        guard clouds == nil else { return }
        let c = HalftoneCloudsView(frame: clip.bounds)
        c.autoresizingMask = [.width, .height]
        c.layerContentsRedrawPolicy = .duringViewResize
        c.color = cloudColor
        clip.addSubview(c)
        clouds = c
        view.needsLayout = true
    }

    func setGlass(_ on: Bool) {
        guard on != isGlass else { return }
        background?.superview?.removeFromSuperview()
        background = nil
        clouds = nil
        defer { matchSidebar() }
        guard on else { return }
        let bg: NSView
        let style = UserDefaults.standard.string(forKey: "GlassStyle") ?? "glass"
        if #available(macOS 26.0, *), style == "glass" || style == "clear" {
            let glass = NSGlassEffectView()
            glass.style = style == "clear" ? .clear : .regular
            glass.cornerRadius = 0
            glass.tintColor = tint
            bg = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = style == "hud" ? .hudWindow : style == "sidebar" ? .sidebar : .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            bg = effect
        }
        // The glass runs on under the sidebar inside a clipping view, so its lit rim doesn't draw a bright line at the
        // sidebar's edge.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clip, positioned: .below, relativeTo: split.view)
        let pane = split.splitViewItems.last { $0.behavior != .sidebar }?.viewController.view ?? split.view
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clip.topAnchor.constraint(equalTo: view.topAnchor),
            clip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bg.frame = NSRect(x: -40, y: 0, width: 40, height: 0)
        bg.autoresizingMask = [.width, .height]
        clip.addSubview(bg)
        background = bg
        updateClouds()
    }

    /// The glass or material the split view puts behind the sidebar item.
    private var sidebarBacking: NSView? {
        var v = split.splitViewItems.first { $0.behavior == .sidebar }?.viewController.view.superview
        while let s = v, s !== split.splitView {
            if s is NSVisualEffectView { return s }
            if #available(macOS 26.0, *), s is NSGlassEffectView { return s }
            v = s.superview
        }
        return nil
    }

    /// Gives the sidebar the window glass's style and tint (its stock look without a glass window). The tint goes on the
    /// sidebar's content rather than its glass: tinted glass lights its edge, a bright line next to the editor.
    private func matchSidebar() {
        if #available(macOS 26.0, *), let side = sidebarBacking as? NSGlassEffectView {
            let glass = background as? NSGlassEffectView
            let style = glass?.style ?? .regular
            if side.style != style { side.style = style }
            let content = split.splitViewItems.first { $0.behavior == .sidebar }?.viewController.view
            content?.wantsLayer = true
            content?.layer?.backgroundColor = glass?.tintColor?.cgColor
        } else if let side = sidebarBacking as? NSVisualEffectView {
            let material = (background as? NSVisualEffectView)?.material ?? .sidebar
            if side.material != material { side.material = material }
        }
    }
}

/// An editor window: Explorer sidebar + one editor (no tabs). Switching files with unsaved changes asks first.
/// VS Code's unsaved-changes dot, drawn right after the window title (the title itself is plain text).
final class UnsavedDotView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    enum SaveChoice { case save, discard, cancel }

    let split = NSSplitViewController()
    private lazy var content = WindowContentController(split: split)
    let explorer = ExplorerViewController()
    let editor = EditorViewController()
    private var sidebarItem: NSSplitViewItem!
    let unsavedDot = UnsavedDotView()
    private weak var unsavedDotAnchor: NSTextField?
    private(set) var rootURL: URL?
    private(set) var fileURL: URL?
    private var fileDate: Date?
    private var watcher: FileWatcher?
    private(set) var fileIndex: FileIndex?
    private(set) var quickOpen: QuickOpenPanel?
    private(set) var recent: [URL] = []
    private var backStack: [(URL, NSRange)] = []
    private var forwardStack: [(URL, NSRange)] = []
    var onClose: ((EditorWindowController) -> Void)?

    /// Asks whether to save changes before they would be lost. Tests replace it.
    static var unsavedChangesPrompt: (String, NSWindow, @escaping (SaveChoice) -> Void) -> Void = { name, window, done in
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            done(response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel)
        }
    }

    /// Picks where to save an untitled file. Tests replace it.
    static var savePanel: (NSWindow, URL?, String, @escaping (URL?) -> Void) -> Void = { window, directory, name, done in
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
    }

    // MARK: - Setup

    init(root: URL?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        super.init(window: window)
        window.delegate = self

        sidebarItem = NSSplitViewItem(sidebarWithViewController: explorer)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.22
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 300
        split.splitView.autosaveName = "SquintEditorSplit"
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        window.contentViewController = content
        // The explorer starts hidden (⌘B or the toolbar button shows it); opening a folder shows it.
        sidebarItem.isCollapsed = true
        window.setContentSize(NSSize(width: 1100, height: 720))

        let toolbar = NSToolbar(identifier: "SquintEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        explorer.onOpen = { [weak self] url in self?.open(url) }
        explorer.onNewFileCreated = { [weak self] url in self?.open(url) }
        explorer.onRootChange = { [weak self] url in self?.setRoot(url) }
        explorer.onOpenFolder = { NSApp.sendAction(#selector(AppDelegate.openFolderPanel(_:)), to: nil, from: nil) }
        explorer.onMove = { [weak self] old, new in self?.itemMoved(from: old, to: new) }
        editor.onDirtyChange = { [weak self] dirty in self?.dirtyChanged(dirty) }
        editor.onThemeChange = { [weak self] palette in self?.applyBackground(palette) }
        editor.onStatusItem = { [weak self] item, view in self?.statusItemClicked(item, view) }
        editor.textView.onOpenFiles = { urls in (NSApp.delegate as? AppDelegate)?.open(urls) }
        _ = editor.view
        applyBackground(editor.palette)
        setRoot(root)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { watcher?.stop() }

    /// Glass window (Settings) or the theme's editor colour.
    private func applyBackground(_ palette: Palette) {
        guard let window else { return }
        let glass = editor.settings.glassWindow
        let strength = UserDefaults.standard.object(forKey: "GlassTint") as? Double ?? 0.45
        content.tint = palette.bg.withAlphaComponent(strength)
        content.cloudColor = palette.fg.withAlphaComponent(UserDefaults.standard.object(forKey: "GlassCloudOpacity") as? Double ?? 0.12)
        content.setGlass(glass)
        content.showsClouds = editor.settings.glassClouds
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : palette.bg
    }

    @objc func toggleSidebar(_ sender: Any?) { split.toggleSidebar(sender) }

    // MARK: - Toolbar

    private static let goToFileItem = NSToolbarItem.Identifier("goToFile")
    private static let sidebarSeparator = NSToolbarItem.Identifier("sidebarSeparator")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.sidebarSeparator, .flexibleSpace, Self.goToFileItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.sidebarSeparator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0) }
        guard id == Self.goToFileItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Go to File")
        item.label = "Go to File"
        item.toolTip = "Go to File (⌘P)"
        item.target = self
        item.action = #selector(goToFile(_:))
        item.isBordered = true
        return item
    }

    // MARK: - Folder

    func setRoot(_ url: URL?) {
        let canonical = url.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        rootURL = canonical
        explorer.setRoot(canonical)
        editor.emptyView.hasFolder = canonical != nil
        watcher?.stop()
        watcher = nil
        fileIndex = canonical.map { FileIndex(root: $0) }
        if let canonical {
            watcher = FileWatcher(url: canonical) { [weak self] paths in self?.filesChanged(paths) }
            NSDocumentController.shared.noteNewRecentDocumentURL(canonical)
        }
        explorer.reveal(fileURL)
        updateTitle()
    }

    /// Whether `url` is inside this window's folder.
    func contains(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        let path = Self.canonical(url).path
        return path == rootURL.path || path.hasPrefix(rootURL.path + "/")
    }

    /// Resolves symlinks in the folder part only, so a symlinked file stays itself.
    static func canonical(_ url: URL) -> URL {
        let u = url.standardizedFileURL
        return u.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(u.lastPathComponent)
    }

    // MARK: - Opening files

    var displayName: String { fileURL?.lastPathComponent ?? (editor.hasDocument ? "Untitled" : "Squint") }

    /// Opens `url` in this window, asking first if the current file has unsaved changes.
    func open(_ url: URL, line: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        let target = Self.canonical(url)
        if target == fileURL, editor.hasDocument {
            if let line { editor.textView.goTo(line: line) }
            explorer.reveal(target)
            window?.makeFirstResponder(editor.textView)
            completion?(true)
            return
        }
        confirmDiscard { [weak self] ok in
            guard let self else { return }
            guard ok else { self.explorer.reveal(self.fileURL); completion?(false); return }
            self.recordHistory()
            self.load(target)
            if let line { self.editor.textView.goTo(line: line) }
            completion?(true)
        }
    }

    private func load(_ url: URL) {
        if rootURL == nil { setRoot(url.deletingLastPathComponent()) }
        fileURL = url
        do {
            let loaded = try TextFile.load(url)
            editor.load(text: loaded.text, name: url.lastPathComponent, format: loaded.format)
            fileDate = loaded.modificationDate
            window?.makeFirstResponder(editor.textView)
        } catch {
            fileDate = nil
            editor.showEmpty(message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
        }
        recent.removeAll { $0 == url }
        recent.insert(url, at: 0)
        if recent.count > 50 { recent.removeLast() }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        explorer.setDirty(nil)
        explorer.reveal(url)
        updateTitle()
    }

    /// A new, untitled file (⌘N).
    func newUntitled() {
        confirmDiscard { [weak self] ok in
            guard ok, let self else { return }
            self.recordHistory()
            self.fileURL = nil
            self.fileDate = nil
            self.editor.load(text: "", name: "Untitled", format: TextFormat())
            self.explorer.reveal(nil)
            self.window?.makeFirstResponder(self.editor.textView)
            self.updateTitle()
        }
    }

    /// Whether a file (or an untitled one, or a file that failed to open) is shown instead of the start page.
    var showsFile: Bool { editor.hasDocument || fileURL != nil }

    /// Close File (⌘W): back to the start page, asking first about unsaved changes. With no file open it closes the
    /// window, like VS Code.
    @objc func closeFile(_ sender: Any?) {
        guard showsFile else { window?.performClose(sender); return }
        confirmDiscard { [weak self] ok in
            guard ok, let self else { return }
            self.recordHistory()
            self.fileURL = nil
            self.fileDate = nil
            self.editor.showEmpty()
            self.explorer.setDirty(nil)
            self.explorer.reveal(nil)
            // Not the hidden text view: typing would go into it.
            self.window?.makeFirstResponder(self.isSidebarVisible ? self.explorer.outlineView : nil)
            self.updateTitle()
        }
    }

    private func recordHistory() {
        guard let url = fileURL, editor.hasDocument else { return }
        backStack.append((url, editor.textView.selectedRange()))
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    // MARK: - Unsaved changes

    /// Calls `then(true)` when the current file may be replaced: it has no unsaved changes, or the user saved or
    /// discarded them.
    func confirmDiscard(_ then: @escaping (Bool) -> Void) {
        guard editor.hasDocument, editor.isDirty, let window else { then(true); return }
        guard window.attachedSheet == nil else { then(false); return }
        Self.unsavedChangesPrompt(displayName, window) { [weak self] choice in
            switch choice {
            case .save: self?.save { then($0) } ?? then(false)
            case .discard: then(true)
            case .cancel: then(false)
            }
        }
    }

    private func dirtyChanged(_ dirty: Bool) {
        window?.isDocumentEdited = dirty
        explorer.setDirty(dirty ? fileURL : nil)
        updateTitle()
    }

    func updateTitle() {
        guard let window else { return }
        window.title = displayName
        unsavedDot.isHidden = !(editor.hasDocument && editor.isDirty)
        placeUnsavedDot()
        DispatchQueue.main.async { [weak self] in self?.placeUnsavedDot() }
        window.representedURL = fileURL
    }

    /// Pins the unsaved dot after the title's text field in the titlebar. AppKit may rebuild that field (or create it
    /// only once the window is shown), so this runs again whenever the window updates while the dot is detached.
    private func placeUnsavedDot() {
        guard !unsavedDot.isHidden, let window, unsavedDotAnchor?.window !== window || unsavedDot.superview == nil else { return }
        guard let frame = window.contentView?.superview else { return }
        func find(_ view: NSView) -> NSTextField? {
            if view === window.contentView { return nil }
            if let field = view as? NSTextField, field.stringValue == window.title { return field }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let field = find(frame), let host = field.superview else { return }
        unsavedDot.removeFromSuperview()
        unsavedDot.translatesAutoresizingMaskIntoConstraints = false
        unsavedDot.toolTip = "Unsaved changes"
        host.addSubview(unsavedDot)
        NSLayoutConstraint.activate([
            unsavedDot.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 5),
            unsavedDot.centerYAnchor.constraint(equalTo: field.centerYAnchor, constant: 0.5),
        ])
        unsavedDotAnchor = field
    }

    func windowDidUpdate(_ notification: Notification) { placeUnsavedDot() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        placeUnsavedDot()
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) { save(completion: nil) }
    @objc func saveDocumentAs(_ sender: Any?) { saveAs(completion: nil) }

    func save(completion: ((Bool) -> Void)?) {
        guard editor.hasDocument else { completion?(false); return }
        guard let url = fileURL else { saveAs(completion: completion); return }
        if let known = fileDate, let disk = TextFile.modificationDate(url), abs(disk.timeIntervalSince(known)) > 0.0005, let window {
            let alert = NSAlert()
            alert.messageText = "\(url.lastPathComponent) has been changed by another application."
            alert.informativeText = "Do you want to overwrite it with your version, or revert to the version on disk?"
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] r in
                guard let self else { return }
                if r == .alertFirstButtonReturn { let saved = self.write(to: url); completion?(saved) }
                else if r == .alertSecondButtonReturn { self.reloadFromDisk(); completion?(false) }
                else { completion?(false) }
            }
            return
        }
        // Not `completion?(write(to: url))`: with no completion (⌘S), optional chaining would skip the write too.
        let saved = write(to: url)
        completion?(saved)
    }

    func saveAs(completion: ((Bool) -> Void)?) {
        guard editor.hasDocument, let window else { completion?(false); return }
        let directory = fileURL?.deletingLastPathComponent() ?? rootURL
        Self.savePanel(window, directory, fileURL?.lastPathComponent ?? "Untitled.txt") { [weak self] url in
            guard let self, let url else { completion?(false); return }
            let target = Self.canonical(url)
            guard self.write(to: target) else { completion?(false); return }
            self.fileURL = target
            if !self.editor.fileName.isEmpty, self.editor.fileName != target.lastPathComponent, self.editor.languageOverride == nil {
                let id = EditorEngine.highlighter.detectLanguage(name: target.lastPathComponent, code: self.editor.text, options: Highlighter.Options())
                if id != self.editor.language.id { self.editor.setLanguage(id) }
            }
            if self.rootURL == nil { self.setRoot(target.deletingLastPathComponent()) }
            self.explorer.filesChanged([target.path])
            self.explorer.reveal(target)
            self.recent.insert(target, at: 0)
            self.updateTitle()
            completion?(true)
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        do {
            fileDate = try TextFile.save(editor.text, format: editor.format, to: url)
            editor.markSaved()
            editor.statusBar.show(message: "Saved")
            updateTitle()
            return true
        } catch TextFile.SaveError.unencodable(let encoding) {
            guard let window else { return false }
            let alert = NSAlert()
            alert.messageText = "The text can't be saved in \(encoding.rawValue)."
            alert.informativeText = "Some characters can't be represented in this encoding. Save the file as UTF-8 instead?"
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn, let self else { return }
                self.editor.format.encoding = .utf8
                self.write(to: url)
            }
            return false
        } catch {
            presentError(error)
            return false
        }
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard fileURL != nil, editor.isDirty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Revert \(displayName) to the saved version?"
        alert.informativeText = "Your unsaved changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.reloadFromDisk() }
        }
    }

    func reloadFromDisk(encoding: TextFormat.Encoding? = nil) {
        guard let url = fileURL else { return }
        do {
            var loaded = try TextFile.load(url)
            if let encoding, let data = try? Data(contentsOf: url) {
                var body = data
                if body.starts(with: encoding.bom) { body = body.dropFirst(encoding.bom.count) }
                if let s = String(data: body, encoding: encoding.stringEncoding) {
                    loaded.text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    loaded.format.encoding = encoding
                } else { NSSound.beep() }
            }
            editor.reload(text: loaded.text, format: loaded.format)
            fileDate = loaded.modificationDate
            updateTitle()
        } catch {
            presentError(error)
        }
    }

    // MARK: - File system events

    private func filesChanged(_ paths: [String]) {
        explorer.filesChanged(paths)
        fileIndex?.invalidate()
        guard let url = fileURL else { return }
        let path = url.resolvingSymlinksInPath().path
        guard paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == path || $0 == url.path }) else { return }
        guard let disk = TextFile.modificationDate(url), let known = fileDate, abs(disk.timeIntervalSince(known)) > 0.0005 else { return }
        // Changed by another app: reload unless there are unsaved changes (then saving asks).
        if !editor.isDirty { reloadFromDisk() }
    }

    private func itemMoved(from old: URL, to new: URL?) {
        guard let current = fileURL else { return }
        let oldPath = Self.canonical(old).path
        let path = current.path
        guard path == oldPath || path.hasPrefix(oldPath + "/") else { return }
        if let new {
            fileURL = Self.canonical(URL(fileURLWithPath: Self.canonical(new).path + path.dropFirst(oldPath.count)))
            fileDate = TextFile.modificationDate(fileURL!)
            explorer.reveal(fileURL)
        } else {
            if !editor.isDirty { fileURL = nil; editor.showEmpty() }
        }
        updateTitle()
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editor.hasDocument, editor.isDirty else { return true }
        confirmDiscard { [weak self] ok in
            guard ok, let self else { return }
            self.editor.markSaved()
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        quickOpen?.dismiss()
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "EditorWindowFrame") }
        onClose?(self)
    }

    // MARK: - Commands

    @objc func newDocument(_ sender: Any?) { newUntitled() }

    @objc func showExplorer(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        window?.makeFirstResponder(explorer.outlineView)
    }

    var showsUnsavedDot: Bool { !unsavedDot.isHidden }
    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }
    func setSidebarVisible(_ visible: Bool) { sidebarItem.isCollapsed = !visible }

    @objc func goToFile(_ sender: Any?) { showPalette(text: "") }
    @objc func goToLine(_ sender: Any?) { if editor.hasDocument { showPalette(text: ":") } }

    @objc func goBack(_ sender: Any?) {
        guard let (url, sel) = backStack.popLast() else { NSSound.beep(); return }
        if let current = fileURL { forwardStack.append((current, editor.textView.selectedRange())) }
        navigate(to: url, selection: sel)
    }

    @objc func goForward(_ sender: Any?) {
        guard let (url, sel) = forwardStack.popLast() else { NSSound.beep(); return }
        if let current = fileURL { backStack.append((current, editor.textView.selectedRange())) }
        navigate(to: url, selection: sel)
    }

    private func navigate(to url: URL, selection: NSRange) {
        confirmDiscard { [weak self] ok in
            guard ok, let self else { return }
            self.load(url)
            let length = self.editor.textView.nsString.length
            self.editor.textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            self.editor.textView.centerSelectionInVisibleArea(nil)
        }
    }

    @objc func nextFileInFolder(_ sender: Any?) { stepFile(1) }
    @objc func previousFileInFolder(_ sender: Any?) { stepFile(-1) }

    private func stepFile(_ offset: Int) {
        guard let url = fileURL, let next = explorer.sibling(of: url, offset: offset), next != url else { NSSound.beep(); return }
        open(next)
    }

    // Find (window-level so it works wherever the focus is).
    @objc func showFind(_ sender: Any?) { editor.showFind() }
    @objc func showReplace(_ sender: Any?) { editor.showFind(replace: true) }
    @objc func findNextMatch(_ sender: Any?) { editor.findNext() }
    @objc func findPreviousMatch(_ sender: Any?) { editor.findPrevious() }
    @objc func useSelectionForFind(_ sender: Any?) {
        let sel = editor.textView.selectedRange()
        guard sel.length > 0 else { return }
        editor.showFind()
        window?.makeFirstResponder(editor.textView)
    }
    @objc func toggleMatchCase(_ sender: Any?) { editor.toggleFindOption(\.caseToggle) }
    @objc func toggleWholeWord(_ sender: Any?) { editor.toggleFindOption(\.wordToggle) }
    @objc func toggleRegex(_ sender: Any?) { editor.toggleFindOption(\.regexToggle) }
    @objc func togglePreserveCase(_ sender: Any?) { editor.toggleFindOption(\.preserveCaseToggle) }
    @objc func toggleFindInSelection(_ sender: Any?) {
        if !editor.isFindVisible { editor.showFind() }
        editor.setFindInSelection(!(editor.findWidget?.inSelection ?? false))
    }

    @objc func toggleWordWrap(_ sender: Any?) { editor.setWrapping(!editor.wraps) }
    @objc func toggleLineNumbers(_ sender: Any?) { editor.setLineNumbersVisible(!editor.showsLineNumbers) }
    @objc func zoomIn(_ sender: Any?) { editor.fontZoom += 1 }
    @objc func zoomOut(_ sender: Any?) { editor.fontZoom -= 1 }
    @objc func resetZoom(_ sender: Any?) { editor.fontZoom = 0 }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = fileURL ?? rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyFilePath(_ sender: Any?) {
        guard let url = fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func changeLanguageMode(_ sender: Any?) { showLanguagePicker() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return editor.hasDocument
        case #selector(revertDocumentToSaved(_:)):
            return fileURL != nil && editor.isDirty
        case #selector(goToLine(_:)), #selector(showFind(_:)), #selector(showReplace(_:)), #selector(findNextMatch(_:)),
             #selector(findPreviousMatch(_:)), #selector(changeLanguageMode(_:)):
            return editor.hasDocument
        case #selector(useSelectionForFind(_:)):
            return editor.hasDocument && editor.textView.selectedRange().length > 0
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(nextFileInFolder(_:)), #selector(previousFileInFolder(_:)), #selector(copyFilePath(_:)):
            return fileURL != nil
        case #selector(revealInFinder(_:)): return fileURL != nil || rootURL != nil
        case #selector(toggleWordWrap(_:)):
            item.state = editor.wraps ? .on : .off
            return true
        case #selector(toggleLineNumbers(_:)):
            item.state = editor.showsLineNumbers ? .on : .off
            return true
        case #selector(toggleMatchCase(_:)): item.state = editor.findWidget?.caseToggle.isOn == true ? .on : .off; return editor.hasDocument
        case #selector(toggleWholeWord(_:)): item.state = editor.findWidget?.wordToggle.isOn == true ? .on : .off; return editor.hasDocument
        case #selector(toggleRegex(_:)): item.state = editor.findWidget?.regexToggle.isOn == true ? .on : .off; return editor.hasDocument
        case #selector(togglePreserveCase(_:)): item.state = editor.findWidget?.preserveCaseToggle.isOn == true ? .on : .off; return editor.hasDocument
        case #selector(toggleFindInSelection(_:)): item.state = editor.findWidget?.inSelection == true ? .on : .off; return editor.hasDocument
        default:
            return true
        }
    }

    // MARK: - Palette

    func showPalette(text: String) {
        quickOpen?.dismiss()
        let panel = QuickOpenPanel(placeholder: "Search files by name (append : to go to a line)")
        panel.provider = { [weak self] q in self?.paletteItems(q) ?? [] }
        panel.onDismiss = { [weak self] in
            guard let self else { return }
            self.quickOpen = nil
            if self.editor.hasDocument { self.window?.makeFirstResponder(self.editor.textView) }
        }
        quickOpen = panel
        panel.present(in: split.view, text: text)
        fileIndex?.load { [weak panel] in panel?.refresh() }
    }

    private func paletteItems(_ query: String) -> [PaletteItem] {
        if query.hasPrefix(":") { return lineItems(String(query.dropFirst())) }
        guard let root = rootURL else { return [] }
        let rootPath = root.path
        func item(_ rel: String, _ positions: [Int], recentlyOpened: Bool) -> PaletteItem {
            let url = root.appendingPathComponent(rel)
            let name = (rel as NSString).lastPathComponent
            let dir = (rel as NSString).deletingLastPathComponent
            let offset = (rel as NSString).length - (name as NSString).length
            return PaletteItem(title: name, detail: dir, icon: FileIcons.icon(for: url, isDirectory: false),
                               highlights: positions.filter { $0 >= offset }.map { $0 - offset },
                               trailing: recentlyOpened ? "recently opened" : "") { [weak self] in self?.open(url) }
        }
        let recentRel = recent.filter { $0 != fileURL && $0.path.hasPrefix(rootPath + "/") }.map { String($0.path.dropFirst(rootPath.count + 1)) }
        let files = fileIndex?.isReady == true ? fileIndex!.files : []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recentSet = Set(recentRel)
            return recentRel.map { item($0, [], recentlyOpened: true) } + files.prefix(300).filter { !recentSet.contains($0) }.map { item($0, [], recentlyOpened: false) }
        }
        var scored: [(Int, String, [Int], Bool)] = []
        let recentSet = Set(recentRel)
        for rel in Set(files).union(recentSet) {
            if let m = Fuzzy.matchPath(trimmed, path: rel) {
                scored.append((m.score + (recentSet.contains(rel) ? 15 : 0), rel, m.positions, recentSet.contains(rel)))
            }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.count < $1.1.count }
        return scored.prefix(200).map { item($0.1, $0.2, recentlyOpened: $0.3) }
    }

    private func lineItems(_ text: String) -> [PaletteItem] {
        guard editor.hasDocument else { return [] }
        let tv = editor.textView
        let count = tv.lines.count
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "," }).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first, let line = first else {
            let current = tv.lines.line(at: tv.selectedRange().location) + 1
            return [PaletteItem(title: "Current line: \(current). Type a line number between 1 and \(count) to navigate to.") {}]
        }
        let column = parts.count > 1 ? (parts[1] ?? 1) : 1
        let target = line < 0 ? max(1, count + line + 1) : min(line, count)
        let title = parts.count > 1 ? "Go to line \(target), character \(column)." : "Go to line \(target)."
        return [PaletteItem(title: title) { [weak self] in
            self?.editor.textView.goTo(line: target, column: column)
            if let tv = self?.editor.textView { self?.window?.makeFirstResponder(tv) }
        }]
    }

    func showLanguagePicker() {
        quickOpen?.dismiss()
        let panel = QuickOpenPanel(placeholder: "Select Language Mode")
        let current = editor.language.id
        let all = [Language.plainText] + Language.all
        panel.provider = { [weak self] q in
            var items: [PaletteItem] = []
            let auto = PaletteItem(title: "Auto Detect", detail: "", trailing: "") { [weak self] in
                guard let self else { return }
                let id = EditorEngine.highlighter.detectLanguage(name: self.editor.fileName, code: self.editor.text, options: Highlighter.Options())
                self.editor.setLanguage(id)
            }
            if q.isEmpty { items.append(auto) }
            for lang in all {
                var positions: [Int] = []
                if !q.isEmpty {
                    guard let m = Fuzzy.match(q, in: lang.name) else { continue }
                    positions = m.positions
                }
                items.append(PaletteItem(title: lang.name, detail: lang.id.isEmpty ? "" : "(\(lang.id))", highlights: positions,
                                         trailing: lang.id == current ? "current" : "") { [weak self] in self?.editor.setLanguage(lang.id) })
            }
            return items
        }
        panel.onDismiss = { [weak self] in
            self?.quickOpen = nil
            if let tv = self?.editor.textView { self?.window?.makeFirstResponder(tv) }
        }
        quickOpen = panel
        panel.present(in: split.view)
    }

    // MARK: - Status bar menus

    private func statusItemClicked(_ item: StatusBarView.Item, _ view: NSView) {
        switch item {
        case .position: goToLine(nil)
        case .language: showLanguagePicker()
        case .indentation: popUp(indentationMenu(), from: view)
        case .lineEnding: popUp(lineEndingMenu(), from: view)
        case .encoding: popUp(encodingMenu(), from: view)
        }
    }

    private func popUp(_ menu: NSMenu, from view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? -6 : view.bounds.height + 6), in: view)
    }

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func perform(_ sender: Any?) { run() }
    }

    private func menuItem(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.state = checked ? .on : .off
        return item
    }

    private func indentationMenu() -> NSMenu {
        let menu = NSMenu()
        let tv = editor.textView
        let spaces = tv.indentUnit != "\t"
        menu.addItem(menuItem("Indent Using Spaces", checked: spaces) { [weak self] in self?.editor.setIndentation(spaces: true, size: tv.tabWidth) })
        menu.addItem(menuItem("Indent Using Tabs", checked: !spaces) { [weak self] in self?.editor.setIndentation(spaces: false, size: tv.tabWidth) })
        menu.addItem(.separator())
        for size in [2, 3, 4, 8] {
            menu.addItem(menuItem("Tab Size: \(size)", checked: tv.tabWidth == size) { [weak self] in
                self?.editor.setIndentation(spaces: tv.indentUnit != "\t", size: size)
            })
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Detect Indentation from Content") { [weak self] in self?.editor.redetectIndentation() })
        menu.addItem(menuItem("Convert Indentation to Spaces") { [weak self] in
            tv.convertIndentation(toTabs: false); self?.editor.setIndentation(spaces: true, size: tv.tabWidth)
        })
        menu.addItem(menuItem("Convert Indentation to Tabs") { [weak self] in
            tv.convertIndentation(toTabs: true); self?.editor.setIndentation(spaces: false, size: tv.tabWidth)
        })
        return menu
    }

    private func lineEndingMenu() -> NSMenu {
        let menu = NSMenu()
        for ending in TextFormat.LineEnding.allCases {
            let label = ending == .lf ? "LF (macOS, Linux)" : ending == .crlf ? "CRLF (Windows)" : "CR (Classic Mac)"
            menu.addItem(menuItem(label, checked: editor.format.lineEnding == ending) { [weak self] in self?.editor.format.lineEnding = ending })
        }
        return menu
    }

    private func encodingMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Save with Encoding", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for encoding in TextFormat.Encoding.allCases {
            menu.addItem(menuItem(encoding.rawValue, checked: editor.format.encoding == encoding) { [weak self] in self?.editor.format.encoding = encoding })
        }
        if fileURL != nil {
            menu.addItem(.separator())
            let reopen = NSMenuItem(title: "Reopen with Encoding", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for encoding in TextFormat.Encoding.allCases {
                sub.addItem(menuItem(encoding.rawValue) { [weak self] in
                    guard let self else { return }
                    self.confirmDiscard { ok in if ok { self.reloadFromDisk(encoding: encoding) } }
                })
            }
            reopen.submenu = sub
            menu.addItem(reopen)
        }
        return menu
    }
}
