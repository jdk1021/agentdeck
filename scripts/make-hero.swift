// Composes docs/images/hero.png from demo screenshots: a macOS-style desktop with the menu bar item,
// the dashboard window and the menu bar panel. Usage: swift scripts/make-hero.swift <docs/images>
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images")
func load(_ name: String) -> NSImage { NSImage(contentsOf: folder.appendingPathComponent(name))! }
let dashboard = load("dashboard-light.png"), panel = load("panel-light.png")
let W: CGFloat = 3200, H: CGFloat = 1900

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Wallpaper: soft gradient with blurred colour fields.
NSGradient(colors: [NSColor(srgbRed: 0.80, green: 0.87, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.93, green: 0.90, blue: 1.0, alpha: 1),
                    NSColor(srgbRed: 1.0, green: 0.92, blue: 0.90, alpha: 1)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)
for (x, y, r, color) in [(500.0, 1500.0, 900.0, NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.35)),
                         (2700.0, 300.0, 1000.0, NSColor(srgbRed: 0.65, green: 0.45, blue: 1.0, alpha: 0.28)),
                         (2400.0, 1600.0, 700.0, NSColor(srgbRed: 1.0, green: 0.60, blue: 0.55, alpha: 0.22))] {
    let g = NSGradient(colors: [color, color.withAlphaComponent(0)])!
    g.draw(fromCenter: NSPoint(x: x, y: y), radius: 0, toCenter: NSPoint(x: x, y: y), radius: r, options: [])
}

// Menu bar.
let barHeight: CGFloat = 64
NSColor.white.withAlphaComponent(0.55).setFill()
NSRect(x: 0, y: H - barHeight, width: W, height: barHeight).fill()
let menuFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
let textAttrs: [NSAttributedString.Key: Any] = [.font: menuFont, .foregroundColor: NSColor(white: 0.1, alpha: 1)]
("AgentDeck" as NSString).draw(at: NSPoint(x: 48, y: H - barHeight + 15), withAttributes: textAttrs)
let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
var x: CGFloat = 230
for item in ["File", "Edit", "View", "Window", "Help"] { (item as NSString).draw(at: NSPoint(x: x, y: H - barHeight + 15), withAttributes: regular); x += (item as NSString).size(withAttributes: regular).width + 44 }
("Fri 9:41 AM" as NSString).draw(at: NSPoint(x: W - 230, y: H - barHeight + 15), withAttributes: regular)
// The AgentDeck status item, highlighted as if its panel is open.
let itemRect = NSRect(x: W - 520, y: H - barHeight + 8, width: 64, height: barHeight - 16)
NSColor.black.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: itemRect, xRadius: 12, yRadius: 12).fill()
let glyph = NSImage(size: NSSize(width: 36, height: 32), flipped: false) { r in
    NSColor.systemOrange.setStroke(); NSColor.systemOrange.setFill()
    let back = NSBezierPath(roundedRect: NSRect(x: 11, y: 13, width: 22, height: 16), xRadius: 4, yRadius: 4); back.lineWidth = 2.8; back.stroke()
    NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 22, height: 18), xRadius: 4.4, yRadius: 4.4).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 7, y: 8, width: 12, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
    NSBezierPath(roundedRect: NSRect(x: 7, y: 13.6, width: 8, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
    return true
}
glyph.draw(in: NSRect(x: itemRect.minX + 14, y: itemRect.minY + 8, width: 36, height: 32))

func place(_ image: NSImage, _ rect: NSRect, radius: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 90, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.white.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius).fill()
    ctx.restoreGState()
    ctx.saveGState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()
    NSColor.black.withAlphaComponent(0.12).setStroke()
    let border = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius); border.lineWidth = 2; border.stroke()
}
let dashWidth: CGFloat = 2050
let dashRect = NSRect(x: 160, y: 110, width: dashWidth, height: dashWidth * dashboard.size.height / dashboard.size.width)
place(dashboard, dashRect, radius: 26)
let panelWidth: CGFloat = 640
let panelHeight = panelWidth * panel.size.height / panel.size.width
// Crop the preview window's title bar (32 pt) so it reads as the menu bar panel.
let bar = 32 * panel.size.width / 380
let cropped = NSImage(size: NSSize(width: panel.size.width, height: panel.size.height - bar))
cropped.lockFocus(); panel.draw(at: .zero, from: NSRect(x: 0, y: 0, width: panel.size.width, height: panel.size.height - bar), operation: .copy, fraction: 1); cropped.unlockFocus()
let croppedHeight = panelWidth * cropped.size.height / cropped.size.width
let panelRect = NSRect(x: itemRect.midX - panelWidth + 90, y: H - barHeight - 20 - croppedHeight, width: panelWidth, height: croppedHeight)
place(cropped, panelRect, radius: 30)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("hero.png"))
print("Wrote hero.png")
