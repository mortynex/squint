import AppKit

/// Flat text button with a soft hover background (status bar items).
final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    var textColor = NSColor.secondaryLabelColor { didSet { refreshTitle() } }
    var labelFont = NSFont.systemFont(ofSize: 11.5)
    var hoverColor = NSColor.labelColor.withAlphaComponent(0.1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var label = "" { didSet { refreshTitle() } }

    private func refreshTitle() {
        attributedTitle = NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: textColor])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 14, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = hoverColor.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

/// The editor's status bar: cursor position, indentation, encoding, line endings and language. Each item opens a menu
/// or a picker, like VS Code's.
final class StatusBarView: NSView {
    enum Item: CaseIterable { case position, indentation, encoding, lineEnding, language }

    var onClick: ((Item, NSView) -> Void)?
    private var buttons: [Item: HoverButton] = [:]
    private let message = NSTextField(labelWithString: "")
    private let separator = NSView()
    static let height: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        for item in Item.allCases {
            let b = HoverButton()
            b.target = self
            b.action = #selector(clicked(_:))
            buttons[item] = b
            addSubview(b)
        }
        buttons[.position]?.toolTip = "Go to Line/Column (⌃G)"
        buttons[.indentation]?.toolTip = "Select Indentation"
        buttons[.encoding]?.toolTip = "Select Encoding"
        buttons[.lineEnding]?.toolTip = "Select End of Line Sequence"
        buttons[.language]?.toolTip = "Select Language Mode"
        message.font = .systemFont(ofSize: 11.5)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        addSubview(message)
        separator.wantsLayer = true
        addSubview(separator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func apply(textColor: NSColor, separatorColor: NSColor) {
        buttons.values.forEach { $0.textColor = textColor; $0.hoverColor = textColor.withAlphaComponent(0.12) }
        message.textColor = textColor
        separator.layer?.backgroundColor = separatorColor.cgColor
    }

    func set(_ item: Item, _ title: String) {
        guard let b = buttons[item], b.label != title else { return }
        b.label = title
        b.isHidden = title.isEmpty
        needsLayout = true
    }

    func title(of item: Item) -> String { buttons[item]?.label ?? "" }
    func button(_ item: Item) -> NSView? { buttons[item] }

    /// A transient message on the left ("Saved", errors…).
    func show(message text: String, seconds: Double = 3) {
        message.stringValue = text
        let current = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.message.stringValue == current { self?.message.stringValue = "" }
        }
    }

    var messageText: String { message.stringValue }

    @objc private func clicked(_ sender: HoverButton) {
        guard let item = buttons.first(where: { $0.value === sender })?.key else { return }
        onClick?(item, sender)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        var x = bounds.width - 8
        for item in Item.allCases.reversed() {
            guard let b = buttons[item], !b.isHidden else { continue }
            let w = b.intrinsicContentSize.width
            x -= w
            b.frame = NSRect(x: x, y: (bounds.height - 20) / 2 + 0.5, width: w, height: 20)
            x -= 2
        }
        message.frame = NSRect(x: 12, y: (bounds.height - 16) / 2 + 0.5, width: max(0, x - 20), height: 16)
    }
}
