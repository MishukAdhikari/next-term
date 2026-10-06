// Draws the Next Term app icon and writes an .icns. Usage: swift scripts/make-icon.swift <out.icns>
import AppKit

func draw(size px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    // macOS icon grid: 824pt body centred in 1024 with a soft shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    rgb(0x1E1F22).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0x2E3036), ending: rgb(0x17181B))!.draw(in: shape, angle: -90)

    // Tab strip with three status dots.
    let strip = NSRect(x: body.minX, y: body.maxY - 170 * s, width: body.width, height: 170 * s)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    rgb(0x2B2D30).setFill()
    strip.fill()
    rgb(0x3574F0).setFill()
    NSRect(x: body.minX + 60 * s, y: strip.minY, width: 230 * s, height: 10 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    let dotY = strip.midY
    let ring = NSBezierPath()
    ring.appendArc(withCenter: NSPoint(x: body.minX + 175 * s, y: dotY), radius: 34 * s, startAngle: 90, endAngle: -160, clockwise: true)
    ring.lineWidth = 16 * s
    ring.lineCapStyle = .round
    rgb(0x3574F0).setStroke()
    ring.stroke()
    for (x, color) in [(410.0, 0x5FB865), (600.0, 0xF2C55C)] as [(CGFloat, UInt32)] {
        rgb(color).setFill()
        NSBezierPath(ovalIn: NSRect(x: body.minX + x * s - 36 * s, y: dotY - 36 * s, width: 72 * s, height: 72 * s)).fill()
    }

    // Prompt: chevron and cursor.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 245 * s, y: 560 * s))
    chevron.line(to: NSPoint(x: 405 * s, y: 440 * s))
    chevron.line(to: NSPoint(x: 245 * s, y: 320 * s))
    chevron.lineWidth = 62 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    rgb(0xDFE1E5).setStroke()
    chevron.stroke()
    rgb(0x3574F0).setFill()
    NSBezierPath(roundedRect: NSRect(x: 470 * s, y: 290 * s, width: 250 * s, height: 62 * s), xRadius: 31 * s, yRadius: 31 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NextTerm-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
try? draw(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-preview.png"))
exit(task.terminationStatus)
