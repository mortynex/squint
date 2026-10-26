// Renders the DMG window background (640×400 pt) into tools/dmg/background.png and background@2x.png.
// Usage: swift tools/make-dmg-background.swift
// The icon positions here must match tools/dmg/settings.py.
import AppKit

let size = CGSize(width: 640, height: 400)
let appIcon = CGPoint(x: 170, y: 200)   // icon centres, top-left origin like Finder
let appsIcon = CGPoint(x: 470, y: 200)

func render(scale: CGFloat) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  // Flip to a top-left origin so coordinates read like Finder's.
  ctx.translateBy(x: 0, y: size.height)
  ctx.scaleBy(x: 1, y: -1)

  // Soft cool gradient.
  let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1).cgColor,
                               NSColor(srgbRed: 0.88, green: 0.90, blue: 0.95, alpha: 1).cgColor] as CFArray,
                      locations: [0, 1])!
  ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

  // Two blurred colour glows for depth.
  func glow(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
  }
  glow(CGPoint(x: 60, y: 40), 320, NSColor(srgbRed: 0.55, green: 0.65, blue: 1.0, alpha: 0.28))
  glow(CGPoint(x: 600, y: 380), 340, NSColor(srgbRed: 0.85, green: 0.55, blue: 0.95, alpha: 0.22))

  // Faint syntax-highlighted code along the bottom, as a nod to what Squint does.
  let code: [[(String, NSColor)]] = {
    let kw = NSColor(srgbRed: 0.62, green: 0.30, blue: 0.85, alpha: 1)
    let fn = NSColor(srgbRed: 0.20, green: 0.45, blue: 0.85, alpha: 1)
    let str = NSColor(srgbRed: 0.85, green: 0.40, blue: 0.25, alpha: 1)
    let pl = NSColor(srgbRed: 0.35, green: 0.38, blue: 0.45, alpha: 1)
    let cm = NSColor(srgbRed: 0.45, green: 0.60, blue: 0.45, alpha: 1)
    return [
      [("// press space on any file", cm)],
      [("func ", kw), ("preview", fn), ("(_ file: URL) -> ", pl), ("HTML", fn), (" {", pl)],
      [("  return ", kw), ("shiki", fn), (".render(file, theme: ", pl), ("\"github-light\"", str), (") }", pl)],
    ]
  }()
  let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  for (i, line) in code.enumerated() {
    let s = NSMutableAttributedString()
    for (text, color) in line {
      s.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: color.withAlphaComponent(0.30)]))
    }
    drawFlipped(s, at: CGPoint(x: 36, y: 322 + CGFloat(i) * 15), in: ctx)
  }

  // Title and tagline.
  let title = NSAttributedString(string: "Squint", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .bold),
    .foregroundColor: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)])
  let tag = NSAttributedString(string: "Code previews for Quick Look", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.40, green: 0.42, blue: 0.50, alpha: 1)])
  drawFlipped(title, at: CGPoint(x: (size.width - title.size().width) / 2, y: 30), in: ctx)
  drawFlipped(tag, at: CGPoint(x: (size.width - tag.size().width) / 2, y: 70), in: ctx)

  // Three chevrons between the icons, brightening towards Applications.
  let mid = CGPoint(x: (appIcon.x + appsIcon.x) / 2, y: appIcon.y - 8)
  ctx.setLineWidth(3.5)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  for i in 0..<3 {
    let x = mid.x + CGFloat(i - 1) * 22
    ctx.setStrokeColor(NSColor(srgbRed: 0.30, green: 0.32, blue: 0.38, alpha: 0.25 + 0.3 * CGFloat(i)).cgColor)
    ctx.move(to: CGPoint(x: x - 6, y: mid.y - 11))
    ctx.addLine(to: CGPoint(x: x + 6, y: mid.y))
    ctx.addLine(to: CGPoint(x: x - 6, y: mid.y + 11))
    ctx.strokePath()
  }

  let hint = NSAttributedString(string: "Drag Squint into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.30, green: 0.32, blue: 0.38, alpha: 1)])
  drawFlipped(hint, at: CGPoint(x: (size.width - hint.size().width) / 2, y: appIcon.y + 22), in: ctx)

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

// Draws text in the flipped context with its top-left at `p`.
func drawFlipped(_ s: NSAttributedString, at p: CGPoint, in ctx: CGContext) {
  ctx.saveGState()
  ctx.translateBy(x: p.x, y: p.y + s.size().height)
  ctx.scaleBy(x: 1, y: -1)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  s.draw(at: .zero)
  NSGraphicsContext.restoreGraphicsState()
  ctx.restoreGState()
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("dmg")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try render(scale: 1).write(to: dir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: dir.appendingPathComponent("background@2x.png"))
