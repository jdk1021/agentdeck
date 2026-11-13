// Renders the AgentDeck app icon (a deck of cards with a usage gauge) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    // macOS icon grid: 824pt body centred in 1024 with a continuous-corner radius.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.12, green: 0.37, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.36, green: 0.62, blue: 1.0, alpha: 1)])!
        .draw(in: shape, angle: 90)
    // Three cards fanned like a deck.
    let colors = [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0.72), NSColor.white]
    for (i, color) in colors.enumerated() {
        let t = NSAffineTransform()
        t.translateX(by: 512 * s, yBy: 470 * s)
        t.rotate(byDegrees: CGFloat(14 - i * 14))
        let card = NSBezierPath(roundedRect: NSRect(x: -190 * s, y: -230 * s, width: 380 * s, height: 480 * s), xRadius: 48 * s, yRadius: 48 * s)
        card.transform(using: t as AffineTransform)
        NSColor(srgbRed: 0.05, green: 0.2, blue: 0.5, alpha: 0.22).setFill()
        let shadow = card.copy() as! NSBezierPath
        let offset = NSAffineTransform(); offset.translateX(by: 0, yBy: -10 * s); shadow.transform(using: offset as AffineTransform); shadow.fill()
        color.setFill(); card.fill()
    }
    // Gauge on the front card.
    let center = NSPoint(x: 512 * s, y: 470 * s)
    let track = NSBezierPath(); track.appendArc(withCenter: center, radius: 120 * s, startAngle: 200, endAngle: -20, clockwise: true)
    track.lineWidth = 40 * s; track.lineCapStyle = .round
    NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1).setStroke(); track.stroke()
    let used = NSBezierPath(); used.appendArc(withCenter: center, radius: 120 * s, startAngle: 200, endAngle: 60, clockwise: true)
    used.lineWidth = 40 * s; used.lineCapStyle = .round
    NSColor(srgbRed: 0.19, green: 0.51, blue: 0.96, alpha: 1).setStroke(); used.stroke()
    let needle = NSBezierPath(); needle.move(to: center)
    needle.line(to: NSPoint(x: center.x + cos(60 * .pi / 180) * 95 * s, y: center.y + sin(60 * .pi / 180) * 95 * s))
    needle.lineWidth = 22 * s; needle.lineCapStyle = .round
    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).setStroke(); needle.stroke()
    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 30 * s, y: center.y - 30 * s, width: 60 * s, height: 60 * s)).fill()
    // Three bars under the gauge.
    for (i, width) in [230.0, 170.0, 200.0].enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: 397 * s, y: (330 - CGFloat(i) * 52) * s, width: CGFloat(width) * s, height: 26 * s), xRadius: 13 * s, yRadius: 13 * s)
        NSColor(srgbRed: 0.82, green: 0.84, blue: 0.86, alpha: 1).setFill(); bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(output.path)")
