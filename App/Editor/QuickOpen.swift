import AppKit

/// Fuzzy matching for Go to File: query characters must appear in order; matches at word starts, after separators
/// and in a row score higher, and a match inside the file name beats one spread over the folders.
enum Fuzzy {
    static func match(_ query: String, in candidate: String) -> (score: Int, positions: [Int])? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return (0, []) }
        let c = Array(candidate)
        let lower = c.map { Character($0.lowercased()) }
        var positions: [Int] = []
        var score = 0
        var qi = 0
        var last = -2
        // Prefer starting at a word boundary where the first character matches.
        var start = 0
        if let boundary = lower.indices.first(where: { lower[$0] == q[0] && isBoundary(c, $0) }) { start = boundary }
        else if let any = lower.firstIndex(of: q[0]) { start = any } else { return nil }
        var i = start
        while i < c.count, qi < q.count {
            if lower[i] == q[qi] {
                var s = 1
                if i == last + 1 { s += 6 }
                if isBoundary(c, i) { s += 8 }
                if c[i] == q[qi] { s += 1 }
                score += s
                positions.append(i)
                last = i
                qi += 1
            }
            i += 1
        }
        guard qi == q.count else { return nil }
        score -= (positions.last! - positions.first!) / 4
        return (score, positions)
    }

    private static func isBoundary(_ c: [Character], _ i: Int) -> Bool {
        if i == 0 { return true }
        let prev = c[i - 1]
        if "/_-. ".contains(prev) { return true }
        return c[i].isUppercase && prev.isLowercase
    }

    /// Scores a relative path, preferring matches within the last path component.
    static func matchPath(_ query: String, path: String) -> (score: Int, positions: [Int])? {
        let name = (path as NSString).lastPathComponent
        let offset = path.count - name.count
        if !query.contains("/"), let m = match(query, in: name) {
            return (m.score + 100 + (m.positions.first == 0 ? 20 : 0) - name.count / 8, m.positions.map { $0 + offset })
        }
        guard let m = match(query, in: path) else { return nil }
        return (m.score - path.count / 10, m.positions)
    }
}

/// The files under a folder for Go to File, read in the background. Skips VS Code's default excludes, dependency and
/// build folders, and names ignored by the folder's .gitignore.
final class FileIndex {
    let root: URL
    private(set) var files: [String] = []
    private(set) var isReady = false
    private var generation = 0
    private var waiting: [() -> Void] = []
    static let limit = 50_000
    static let skippedFolders: Set<String> = ["node_modules", "bower_components", ".build", "DerivedData", "__pycache__", ".venv", "venv",
                                              ".next", ".nuxt", ".gradle", ".idea", ".vscode-test", "Pods", ".terraform", ".cache"]

    init(root: URL) { self.root = root }

    func invalidate() { isReady = false; generation += 1 }

    /// Calls `done` once the list is ready (right away if it is).
    func load(_ done: @escaping () -> Void) {
        if isReady { done(); return }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        let gen = generation
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.scan(root)
            DispatchQueue.main.async {
                guard gen == self.generation else {
                    let w = self.waiting
                    self.waiting = []
                    w.forEach { self.load($0) }
                    return
                }
                self.files = list
                self.isReady = true
                let w = self.waiting
                self.waiting = []
                w.forEach { $0() }
            }
        }
    }

    static func scan(_ root: URL) -> [String] {
        let ignore = GitIgnore(root: root)
        var out: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: { _, _ in true }) else { return [] }
        for case let url as URL in e {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            if FileNode.excluded.contains(name) || (isDir && skippedFolders.contains(name)) || ignore.ignores(rel, isDirectory: isDir) {
                if isDir { e.skipDescendants() }
                continue
            }
            if isDir {
                if url.pathExtension == "app" || url.pathExtension == "xcassets" { e.skipDescendants() }
                continue
            }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out
    }
}

/// A small subset of .gitignore: patterns (with *, ?, [..]), folder-only patterns and anchored paths, read from the
/// root folder's .gitignore. Negations are skipped.
struct GitIgnore {
    private var names: [String] = []
    private var paths: [String] = []
    private var dirNames: [String] = []

    init(root: URL) {
        guard let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else { return }
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            let dirOnly = line.hasSuffix("/")
            if dirOnly { line.removeLast() }
            if line.hasPrefix("**/") { line.removeFirst(3) }
            if line.hasPrefix("/") || line.dropLast().contains("/") {
                paths.append(line.hasPrefix("/") ? String(line.dropFirst()) : line)
            } else if dirOnly {
                dirNames.append(line)
            } else {
                names.append(line)
            }
        }
    }

    func ignores(_ relativePath: String, isDirectory: Bool) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        if names.contains(where: { fnmatch($0, name, 0) == 0 }) { return true }
        if isDirectory, dirNames.contains(where: { fnmatch($0, name, 0) == 0 }) { return true }
        return paths.contains { fnmatch($0, relativePath, FNM_PATHNAME) == 0 }
    }
}

struct PaletteItem {
    var title: String
    var detail = ""
    var icon: NSImage?
    var highlights: [Int] = []
    var trailing = ""
    var action: () -> Void
}

private final class PaletteRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.85 : 0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

/// A VS Code-style quick pick on glass at the top of the window.
final class QuickOpenPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let content = FlippedView()
    private let glass: NSView
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let separator = NSView()
    private var items: [PaletteItem] = []
    private var monitor: Any?
    var provider: ((String) -> [PaletteItem]) = { _ in [] }
    var onDismiss: (() -> Void)?
    static let rowHeight: CGFloat = 30
    static let maxRows = 12

    init(placeholder: String) {
        glass = Glass.panel(content: content, cornerRadius: 16)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(glass)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.delegate = self
        content.addSubview(field)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(separator)

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        content.addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; refresh() }
    }

    var visibleItems: [PaletteItem] { items }
    var selectedIndex: Int { table.selectedRow }

    func present(in parent: NSView, text: String = "") {
        parent.addSubview(self)
        field.stringValue = text
        refresh()
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let p = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(p) { self.dismiss() }
            return event
        }
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard superview != nil else { return }
        removeFromSuperview()
        onDismiss?()
    }

    func refresh() {
        items = provider(field.stringValue)
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
        layoutInParent()
    }

    func layoutInParent() {
        guard let parent = superview else { return }
        let width = min(640, parent.bounds.width - 40)
        let rows = min(items.count, Self.maxRows)
        let height = 48 + (rows > 0 ? CGFloat(rows) * Self.rowHeight + 12 : 0)
        let top = parent.safeAreaInsets.top + 8
        frame = NSRect(x: (parent.bounds.width - width) / 2, y: parent.isFlipped ? top : parent.bounds.height - top - height, width: width, height: height)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        field.frame = NSRect(x: 16, y: 13, width: bounds.width - 32, height: 22)
        separator.frame = NSRect(x: 0, y: 47, width: bounds.width, height: 1)
        separator.isHidden = items.isEmpty
        scroll.frame = NSRect(x: 0, y: 54, width: bounds.width, height: max(0, bounds.height - 60))
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    func accept() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let action = items[row].action
        dismiss()
        action()
    }

    @objc private func clicked() {
        if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false); accept() }
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - Field

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): moveSelection(-Self.maxRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): moveSelection(Self.maxRows)
        case #selector(NSResponder.insertNewline(_:)): accept()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow() }

    private var lastSelected = -1
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Re-render the rows whose text colours depend on selection.
        let rows = IndexSet([lastSelected, table.selectedRow].filter { $0 >= 0 && $0 < items.count })
        lastSelected = table.selectedRow
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = item.icon
        let title = NSTextField(labelWithString: "")
        let attributed = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let chars = Array(item.title)
        var utf16Offsets: [Int] = []
        var o = 0
        for ch in chars { utf16Offsets.append(o); o += ch.utf16.count }
        let selected = tableView.selectedRow == row
        if selected { attributed.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: attributed.length)) }
        for p in item.highlights where p < chars.count {
            attributed.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: selected ? NSColor.white : NSColor.controlAccentColor],
                                     range: NSRange(location: utf16Offsets[p], length: chars[p].utf16.count))
        }
        title.attributedStringValue = attributed
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        let trailing = NSTextField(labelWithString: item.trailing)
        trailing.font = .systemFont(ofSize: 12)
        trailing.textColor = selected ? NSColor.white.withAlphaComponent(0.6) : .tertiaryLabelColor
        for v in [image, title, detail, trailing] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            trailing.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
