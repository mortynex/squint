import AppKit

/// A file or folder in the Explorer. Folder contents are read when first expanded.
final class FileNode: NSObject {
    let url: URL
    /// Only a placeholder changes kind (New File / New Folder while naming it).
    fileprivate(set) var isDirectory: Bool
    weak var parent: FileNode?
    var children: [FileNode]?
    /// A row being typed for a new file or folder.
    var isPlaceholder = false

    /// Hidden from the tree, like VS Code's default `files.exclude`.
    static let excluded: Set<String> = [".git", ".svn", ".hg", "CVS", ".DS_Store", "Thumbs.db"]

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.isDirectory = isDirectory
        self.parent = parent
    }

    var name: String { url.lastPathComponent }

    /// Reads the folder again, keeping the nodes (and so the expansion state) of entries that are still there.
    @discardableResult
    func reloadChildren() -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var old: [String: FileNode] = [:]
        for c in children ?? [] where !c.isPlaceholder { old[c.name] = c }
        var result: [FileNode] = []
        for u in urls where !Self.excluded.contains(u.lastPathComponent) {
            let values = try? u.resourceValues(forKeys: Set(keys))
            var isDir = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                var d: ObjCBool = false
                isDir = FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
            }
            if let existing = old[u.lastPathComponent], existing.isDirectory == isDir {
                result.append(existing)
            } else {
                result.append(FileNode(url: u, isDirectory: isDir, parent: self))
            }
        }
        result.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        // A row being named survives re-reading the folder; it goes away only when the edit ends.
        for p in children ?? [] where p.isPlaceholder {
            result.insert(p, at: Self.insertionIndex(directory: p.isDirectory, in: result))
        }
        children = result
        return result
    }

    func loadedChildren() -> [FileNode] { children ?? reloadChildren() }

    /// Where a new item is typed: a folder at the top, a file above the first file.
    static func insertionIndex(directory: Bool, in children: [FileNode]) -> Int {
        directory ? 0 : (children.firstIndex { !$0.isDirectory } ?? children.count)
    }
}

private final class ExplorerOutlineView: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

/// VS Code's Explorer: the folder tree with new file / new folder / refresh / collapse actions, inline rename and a
/// context menu. Single-clicking a file opens it in the editor.
final class ExplorerViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private(set) var root: FileNode?
    private let outline = ExplorerOutlineView()
    private let scroll = NSScrollView()
    private let header = FlippedView()
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let newFileButton = IconButton(symbol: "doc.badge.plus", tooltip: "New File…")
    private let newFolderButton = IconButton(symbol: "folder.badge.plus", tooltip: "New Folder…")
    private let refreshButton = IconButton(symbol: "arrow.clockwise", tooltip: "Refresh Explorer")
    private let collapseButton = IconButton(symbol: "rectangle.compress.vertical", tooltip: "Collapse Folders in Explorer")
    private var editingNode: FileNode?
    /// The field `editingNode` is being typed in.
    private var editField: NSTextField?
    /// FSEvents paths that arrived during an inline edit, applied once it ends.
    private var deferredChanges: [String] = []
    private var dirtyURL: URL?

    /// Asks the window to open a file (it may refuse, e.g. when the user cancels saving changes).
    var onOpen: ((URL) -> Void)?
    var onRootChange: ((URL) -> Void)?
    var onOpenFolder: (() -> Void)?
    /// A file or folder was renamed or moved to the Trash.
    var onMove: ((URL, URL?) -> Void)?
    var onNewFileCreated: ((URL) -> Void)?
    /// Confirms moving an item to the Trash; tests replace it.
    static var confirmDelete: (String, NSWindow?, @escaping (Bool) -> Void) -> Void = { name, window, done in
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to delete '\(name)'?"
        alert.informativeText = "You can restore this file from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if let window { alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) } }
        else { done(alert.runModal() == .alertFirstButtonReturn) }
    }

    var rootURL: URL? { root?.url }

    override func loadView() {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        view = v

        titleButton.isBordered = false
        titleButton.target = self
        titleButton.action = #selector(showRootMenu(_:))
        titleButton.imagePosition = .imageTrailing
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.toolTip = "Change the folder shown in the Explorer"
        header.addSubview(titleButton)
        for (b, action) in [(newFileButton, #selector(newFile(_:))), (newFolderButton, #selector(newFolder(_:))),
                            (refreshButton, #selector(refresh(_:))), (collapseButton, #selector(collapseAll(_:)))] {
            b.target = self
            b.action = action
            // Clicking them must not end an inline edit: New File / New Folder switch its kind, Refresh keeps it.
            b.refusesFirstResponder = true
            header.addSubview(b)
        }
        v.addSubview(header)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.allowsEmptySelection = true
        outline.onKey = { [weak self] in self?.handleKey($0) ?? false }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        v.addSubview(scroll)
        updateHeader()
    }

    /// Relayouts when the titlebar/toolbar area changes (toolbar shown or hidden, full screen).
    private var layoutRectObservation: NSKeyValueObservation?

    override func viewWillAppear() {
        super.viewWillAppear()
        layoutRectObservation = view.window?.observe(\.contentLayoutRect) { [weak self] _, _ in self?.view.needsLayout = true }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        layoutRectObservation = nil
    }

    /// How far the titlebar (traffic lights, sidebar toggle) reaches into this view. The sidebar's `safeAreaInsets`
    /// reads 0 under a full-size content view, so it's worked out from the window's content layout rect too.
    private var titlebarInset: CGFloat {
        guard let window = view.window else { return view.safeAreaInsets.top }
        let viewTop = view.convert(view.bounds, to: nil).maxY
        return max(view.safeAreaInsets.top, viewTop - window.contentLayoutRect.maxY, 0)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let top = titlebarInset + 4
        header.frame = NSRect(x: 0, y: top, width: b.width, height: 30)
        var x = b.width - 10
        for button in [collapseButton, refreshButton, newFolderButton, newFileButton] where !button.isHidden {
            x -= 24
            button.frame = NSRect(x: x, y: 3, width: 24, height: 24)
        }
        // As wide as the title needs, up to the visible buttons (hidden ones, with no folder, take no room).
        let titleX: CGFloat = 14
        titleButton.frame = NSRect(x: titleX, y: 5, width: min(max(0, x - 4 - titleX), ceil(titleButton.intrinsicContentSize.width)), height: 20)
        let listTop = top + 32
        scroll.frame = NSRect(x: 0, y: listTop, width: b.width, height: max(0, b.height - listTop))
    }

    // MARK: - Root

    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.url.standardizedFileURL || url == nil else { return }
        cancelEditing()
        deferredChanges = []
        if let url {
            let node = FileNode(url: url.standardizedFileURL, isDirectory: true, parent: nil)
            node.reloadChildren()
            root = node
        } else {
            root = nil
        }
        outline.reloadData()
        updateHeader()
    }

    private func updateHeader() {
        let hasRoot = root != nil
        scroll.isHidden = !hasRoot
        [newFileButton, newFolderButton, refreshButton, collapseButton].forEach { $0.isHidden = !hasRoot }
        let title = hasRoot ? (root!.name.isEmpty ? "/" : root!.name).uppercased() : "NO FOLDER OPENED"
        titleButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.4])
        titleButton.image = hasRoot ? NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) : nil
        titleButton.contentTintColor = .tertiaryLabelColor
        view.needsLayout = true
    }

    @objc private func showRootMenu(_ sender: NSButton) {
        guard let root else { return }
        let menu = NSMenu()
        var url = root.url
        var ancestors: [URL] = []
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            ancestors.append(url)
        }
        let header = NSMenuItem(title: "Show Folder in Explorer", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for a in ancestors {
            let item = NSMenuItem(title: a.path == "/" ? "/" : a.lastPathComponent, action: #selector(chooseRoot(_:)), keyEquivalent: "")
            item.representedObject = a
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: a.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.toolTip = a.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func chooseRoot(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onRootChange?(url)
    }

    @objc private func openFolder(_ sender: Any?) { onOpenFolder?() }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        return node.isDirectory && !node.isPlaceholder ? node.loadedChildren().count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FileNode) ?? root!
        return node.loadedChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory && !node.isPlaceholder
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        cell.imageView?.image = FileIcons.icon(for: node.url, isDirectory: node.isDirectory)
        let field = cell.textField!
        field.stringValue = node.isPlaceholder ? "" : node.name
        styleField(field, editing: node === editingNode)
        field.textColor = node.name.hasPrefix(".") ? .secondaryLabelColor : .labelColor
        // Not while renaming: the marker would become part of the name.
        if node !== editingNode, let dirty = dirtyURL, dirty.standardizedFileURL == node.url.standardizedFileURL {
            field.attributedStringValue = NSAttributedString(string: node.name + "  ●", attributes: [.font: field.font!, .foregroundColor: NSColor.labelColor])
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.cell?.isScrollable = true
        field.focusRingType = .none
        cell.addSubview(image)
        cell.addSubview(field)
        cell.imageView = image
        cell.textField = field
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool { false }

    // MARK: - Selection and opening

    var selectedNode: FileNode? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, !node.isPlaceholder, editingNode == nil else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
        } else {
            onOpen?(node.url)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let node = selectedNode, editingNode == nil else { return false }
        switch (event.keyCode, flags) {
        case (36, []), (76, []):   // Return: rename, as in VS Code on macOS
            beginRename(node)
            return true
        case (49, []), (125, .command):   // Space, ⌘↓: open
            if node.isDirectory { outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node) } else { onOpen?(node.url) }
            return true
        case (51, .command):   // ⌘⌫
            delete(node)
            return true
        default:
            return false
        }
    }

    /// Selects `url` in the tree, expanding its folders.
    func reveal(_ url: URL?) {
        guard let url, let root else { outline.deselectAll(nil); return }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.url.path + "/") else { outline.deselectAll(nil); return }
        var node = root
        let parts = path.dropFirst(root.url.path.count + 1).split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            guard let child = node.loadedChildren().first(where: { $0.name == part }) else { break }
            if i < parts.count - 1 { outline.expandItem(child) }
            node = child
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    /// Marks the open file as having unsaved changes.
    func setDirty(_ url: URL?) {
        let old = dirtyURL
        dirtyURL = url
        for u in [old, url].compactMap({ $0 }) {
            // The row being renamed gets its marker when the edit ends; reloading it now would tear down the field.
            if let node = node(for: u), node !== editingNode { outline.reloadItem(node) }
        }
    }

    func node(for url: URL) -> FileNode? {
        guard let root else { return nil }
        let path = url.standardizedFileURL.path
        if path == root.url.path { return root }
        guard path.hasPrefix(root.url.path + "/") else { return nil }
        var node = root
        for part in path.dropFirst(root.url.path.count + 1).split(separator: "/") {
            guard let children = node.children, let child = children.first(where: { $0.name == part && !$0.isPlaceholder }) else { return nil }
            node = child
        }
        return node
    }

    /// Files in the tree order (shown or not) next to `url`, for "next/previous file in folder".
    func sibling(of url: URL, offset: Int) -> URL? {
        let folder = url.deletingLastPathComponent()
        guard let parent = node(for: folder) ?? (folder.standardizedFileURL == root?.url ? root : nil) else { return nil }
        let files = parent.loadedChildren().filter { !$0.isDirectory && !$0.isPlaceholder }
        guard let i = files.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }), !files.isEmpty else { return nil }
        return files[(i + offset + files.count) % files.count].url
    }

    // MARK: - File system changes

    /// Re-reads the folders containing `paths` (FSEvents).
    func filesChanged(_ paths: [String]) {
        guard let root else { return }
        // Not under the field being typed in; `flushDeferredChanges` applies them when the edit ends.
        if editingNode != nil { deferredChanges += paths; return }
        var folders = Set<String>()
        for p in paths {
            let url = URL(fileURLWithPath: p)
            folders.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            folders.insert(url.standardizedFileURL.path)
        }
        var reloaded = false
        for path in folders {
            let node = path == root.url.path ? root : self.node(for: URL(fileURLWithPath: path))
            guard let node, node.isDirectory, node.children != nil else { continue }
            reload(node)
            reloaded = true
        }
        if reloaded, editingNode == nil { restoreSelection() }
    }

    private var selectionToRestore: URL?

    private func reload(_ node: FileNode) {
        preservingEdit {
            selectionToRestore = selectedNode.flatMap { $0.isPlaceholder ? nil : $0.url } ?? selectionToRestore
            node.reloadChildren()
            outline.reloadItem(node === root ? nil : node, reloadChildren: true)
        }
    }

    private func flushDeferredChanges() {
        guard !deferredChanges.isEmpty else { return }
        let paths = deferredChanges
        deferredChanges = []
        // Later, so it never runs inside whatever ended the edit.
        DispatchQueue.main.async { [weak self] in self?.filesChanged(paths) }
    }

    private func restoreSelection() {
        if let url = selectionToRestore, let node = node(for: url) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        selectionToRestore = nil
    }

    @objc func refresh(_ sender: Any?) {
        guard let root else { return }
        func walk(_ node: FileNode) {
            guard node.children != nil else { return }
            node.reloadChildren()
            node.children?.forEach(walk)
        }
        preservingEdit {
            let selected = selectedNode.flatMap { $0.isPlaceholder ? nil : $0.url }
            walk(root)
            outline.reloadData()
            expandLoaded(root)
            if let selected { reveal(selected) }
        }
    }

    private func expandLoaded(_ node: FileNode) {
        for c in node.children ?? [] where c.isDirectory && c.children != nil && wasExpanded.contains(c.url.path) {
            outline.expandItem(c)
            expandLoaded(c)
        }
    }

    private var wasExpanded: Set<String> = []
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode { wasExpanded.insert(node.url.path) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode { wasExpanded.remove(node.url.path) }
    }
    /// A folder holding the row being edited stays open: collapsing it would tear down the field mid-edit. (Clicking
    /// the outline ends the edit first, so this only holds against collapses that don't.)
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        var ancestor = editingNode?.parent
        while let a = ancestor {
            if a === item as AnyObject { return false }
            ancestor = a.parent
        }
        return true
    }

    @objc func collapseAll(_ sender: Any?) {
        endEditing()
        outline.collapseItem(nil, collapseChildren: true)
        wasExpanded.removeAll()
    }

    // MARK: - New, rename, delete

    private var targetFolder: FileNode? {
        guard let root else { return nil }
        guard let node = selectedNode else { return root }
        if node.isDirectory && outline.isItemExpanded(node) { return node }
        return node.parent ?? root
    }

    @objc func newFile(_ sender: Any?) { beginCreate(directory: false) }
    @objc func newFolder(_ sender: Any?) { beginCreate(directory: true) }

    private func beginCreate(directory: Bool) {
        if let node = editingNode {
            // While naming a new item, New File / New Folder switch its kind and keep what was typed.
            if node.isPlaceholder { switchKind(of: node, toDirectory: directory); return }
            endEditing()
            guard editingNode == nil else { return }
        }
        guard let folder = targetFolder else { return }
        let placeholder = FileNode(url: folder.url.appendingPathComponent(" "), isDirectory: directory, parent: folder)
        placeholder.isPlaceholder = true
        var children = folder.loadedChildren()
        children.insert(placeholder, at: FileNode.insertionIndex(directory: directory, in: children))
        folder.children = children
        if folder !== root { outline.expandItem(folder) }
        outline.reloadItem(folder === root ? nil : folder, reloadChildren: true)
        startEditing(placeholder, selectStem: false)
    }

    private func switchKind(of placeholder: FileNode, toDirectory directory: Bool) {
        guard placeholder.isDirectory != directory, let folder = placeholder.parent else { return }
        preservingEdit {
            var children = folder.children ?? []
            children.removeAll { $0 === placeholder }
            placeholder.isDirectory = directory
            children.insert(placeholder, at: FileNode.insertionIndex(directory: directory, in: children))
            folder.children = children
            outline.reloadItem(folder === root ? nil : folder, reloadChildren: true)
        }
    }

    func beginRename(_ node: FileNode) {
        guard node !== root, editingNode == nil else { return }
        startEditing(node, selectStem: !node.isDirectory)
    }

    /// Starts typing in `node`'s row: with `text` and `selection` when resuming an edit, else its name selected.
    private func startEditing(_ node: FileNode, selectStem: Bool, text: String? = nil, selection: NSRange? = nil) {
        editingNode = node
        let row = outline.row(forItem: node)
        guard row >= 0 else { editingNode = nil; return }
        outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, let field = cell.textField else {
            editingNode = nil
            return
        }
        editField = field
        styleField(field, editing: true)
        if let text { field.stringValue = text }
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = field.stringValue as NSString
            if let selection, NSMaxRange(selection) <= name.length {
                editor.selectedRange = selection
            } else {
                let stem = selectStem ? (name.deletingPathExtension as NSString).length : name.length
                editor.selectedRange = NSRange(location: 0, length: stem == 0 ? name.length : stem)
            }
        }
    }

    private func styleField(_ field: NSTextField, editing: Bool) {
        field.isEditable = editing
        field.isBordered = editing
        field.drawsBackground = editing
        if editing { field.backgroundColor = .textBackgroundColor }
    }

    /// Runs `body`, which may rebuild rows, without ending the inline edit. Reloading (or collapsing) a row tears down
    /// the cell hosting the field editor, and the edit then ended in the middle of the reload, committing or cancelling
    /// (and reloading again) inside it, which emptied the tree or crashed. So the edit is taken down first, keeping
    /// its text and selection, and started again on the same item afterwards.
    private func preservingEdit(_ body: () -> Void) {
        guard let node = editingNode else { body(); return }
        let field = editField
        let text = field?.stringValue ?? ""
        let selection = field?.currentEditor()?.selectedRange
        takeDownEdit()
        body()
        if outline.row(forItem: node) >= 0 { startEditing(node, selectStem: false, text: text, selection: selection) }
        guard editingNode == nil else { return }
        // Its row is gone (the folder was deleted, say): the edit is dropped.
        dropPlaceholder(node)
        flushDeferredChanges()
    }

    /// Ends the inline edit without committing or cancelling it.
    private func takeDownEdit() {
        guard editingNode != nil else { return }
        editingNode = nil   // so controlTextDidEndEditing ignores the field resigning
        guard let field = editField else { return }
        editField = nil
        if field.currentEditor() != nil, view.window?.makeFirstResponder(outline) != true { field.abortEditing() }
        styleField(field, editing: false)
    }

    private func dropPlaceholder(_ node: FileNode) {
        guard node.isPlaceholder, let folder = node.parent else { return }
        folder.children?.removeAll { $0 === node }
        if folder === root || outline.isItemExpanded(folder) { outline.reloadItem(folder === root ? nil : folder, reloadChildren: true) }
    }

    /// Ends the inline edit as clicking elsewhere does: a typed name is committed, an empty one cancelled.
    private func endEditing() {
        guard editingNode != nil, let field = editField else { return }
        if field.currentEditor() != nil { view.window?.makeFirstResponder(outline) }
        if editingNode != nil { controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field)) }
    }

    /// Drops the inline edit, e.g. when the tree is replaced.
    private func cancelEditing() {
        guard let node = editingNode else { return }
        takeDownEdit()
        dropPlaceholder(node)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSTextField)?.stringValue = editingNode?.isPlaceholder == true ? "" : (editingNode?.name ?? "")
            view.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let node = editingNode, field === editField else { return }
        editingNode = nil
        editField = nil
        defer { flushDeferredChanges() }
        styleField(field, editing: false)
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = node.parent ?? root else { return }
        if node.isPlaceholder {
            folder.children?.removeAll { $0 === node }
            guard !name.isEmpty else { reload(folder); return }
            let url = folder.url.appendingPathComponent(name)
            do {
                if node.isDirectory {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
                    try Data().write(to: url)
                }
            } catch {
                reload(folder)
                presentError(error)
                return
            }
            reload(folder)
            reveal(url)
            view.window?.makeFirstResponder(outline)
            if !node.isDirectory { onNewFileCreated?(url) }
        } else {
            guard !name.isEmpty, name != node.name else { outline.reloadItem(node); view.window?.makeFirstResponder(outline); return }
            let target = node.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: node.url, to: target)
            } catch {
                outline.reloadItem(node)
                presentError(error)
                return
            }
            let old = node.url
            reload(folder)
            reveal(target)
            view.window?.makeFirstResponder(outline)
            onMove?(old, target)
        }
    }

    func delete(_ node: FileNode) {
        guard node !== root else { return }
        Self.confirmDelete(node.name, view.window) { [weak self] ok in
            guard ok, let self else { return }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            } catch {
                self.presentError(error)
                return
            }
            if let parent = node.parent { self.reload(parent) }
            self.onMove?(node.url, nil)
        }
    }

    // MARK: - Context menu

    private var menuNode: FileNode? {
        let row = outline.clickedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil else { return }
        let node = menuNode
        if node != nil, outline.selectedRow != outline.clickedRow {
            outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false)
        }
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        add("New File…", #selector(newFile(_:)))
        add("New Folder…", #selector(newFolder(_:)))
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add("Open in Terminal", #selector(openInTerminal(_:)))
        menu.addItem(.separator())
        add("Copy Path", #selector(copyPath(_:)))
        add("Copy Relative Path", #selector(copyRelativePath(_:)))
        if node != nil {
            menu.addItem(.separator())
            add("Rename…", #selector(renameSelected(_:)), "\r")
            add("Delete", #selector(deleteSelected(_:)), "\u{8}", .command)
        }
    }

    private var actionURL: URL? { (menuNode ?? selectedNode)?.url ?? root?.url }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let url = actionURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openInTerminal(_ sender: Any?) {
        guard var url = actionURL else { return }
        if !((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) { url.deleteLastPathComponent() }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let url = actionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func copyRelativePath(_ sender: Any?) {
        guard let url = actionURL, let root else { return }
        let rel = url.path == root.url.path ? "." : String(url.path.dropFirst(root.url.path.count + 1))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rel, forType: .string)
    }

    @objc private func renameSelected(_ sender: Any?) { if let n = menuNode ?? selectedNode { beginRename(n) } }
    @objc private func deleteSelected(_ sender: Any?) { if let n = menuNode ?? selectedNode { delete(n) } }

    // Test access.
    var outlineView: NSOutlineView { outline }
    var editingItem: FileNode? { editingNode }
    var editingText: String? { editField?.stringValue }
    func commitEditing(name: String) {
        editField?.stringValue = name
        endEditing()
    }
}
