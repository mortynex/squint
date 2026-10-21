import AppKit

// Renders the Quick Look preview of a file offscreen: snap <file> <out.png> [dark] [opaque]
// A transparent preview is drawn over a flat grey standing in for Quick Look's glass.
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: snap <file> <out.png> [dark] [opaque]")
    exit(2)
}
let app = NSApplication.shared
let dark = args.contains("dark")
NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
var settings = Settings()
settings.transparentBackground = !args.contains("opaque")
let options = settings.options(dark: dark)
let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let highlighter = Highlighter(resources: repo.appendingPathComponent("Resources"))

let frame = NSRect(x: 0, y: 0, width: 760, height: 460)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSApp.appearance
let container = NSView(frame: frame)
container.wantsLayer = true
container.layer?.backgroundColor = NSColor(white: dark ? 0.17 : 0.93, alpha: 1).cgColor
let root = PreviewViewController.previewView(of: URL(fileURLWithPath: args[1]), frame: frame, options: options,
                                             highlighter: highlighter, onOpenInEditor: {})
root.autoresizingMask = [.width, .height]
container.addSubview(root)
window.contentView = container
container.layoutSubtreeIfNeeded()
root.layout()

guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { exit(1) }
container.cacheDisplay(in: container.bounds, to: rep)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
