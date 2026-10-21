import AppKit

/// View whose subviews are laid out from the top-left.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum Glass {
    /// A rounded glass panel (macOS 26+ Liquid Glass; a blurred material on older systems) hosting `content`.
    static func panel(content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }
}
