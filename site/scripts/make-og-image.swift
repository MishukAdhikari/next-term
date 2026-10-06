// Renders the 1200×630 social card (public/og.jpg): the app icon, name and tagline, and a screenshot
// of the app window. macOS only (AppKit). Usage, from site/:
//
//   swift scripts/make-og-image.swift <window-screenshot.png> <app-icon.png> /tmp/og.png
//   sips -s format jpeg -s formatOptions 86 /tmp/og.png --out public/og.jpg
//
// The app icon PNG comes from the app: sips -s format png ../Resources/AppIcon.icns --out /tmp/icon.png
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-og-image.swift <screenshot.png> <icon.png> <out.png>\n".utf8))
    exit(2)
}
let (shotPath, iconPath, outPath) = (args[1], args[2], args[3])
let width = 1200, height = 630

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high

color(0x1E1F22).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// The app window, bottom right, running off the bottom edge.
if let shot = NSImage(contentsOfFile: shotPath) {
    let w: CGFloat = 750
    let frame = NSRect(x: 420, y: -40, width: w, height: w * shot.size.height / shot.size.width)
    let path = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x2B2D30).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    shot.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    color(0x393B40).setStroke()
    path.lineWidth = 1
    path.stroke()
}

if let icon = NSImage(contentsOfFile: iconPath) {
    icon.draw(in: NSRect(x: 56, y: height - 56 - 96, width: 96, height: 96))
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, x: CGFloat, top: CGFloat, maxWidth: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.08
    let attributed = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(hex),
        .paragraphStyle: style, .kern: size > 40 ? -0.6 : 0,
    ])
    let bounds = attributed.boundingRect(with: NSSize(width: maxWidth, height: 400), options: [.usesLineFragmentOrigin])
    attributed.draw(with: NSRect(x: x, y: CGFloat(height) - top - bounds.height, width: maxWidth, height: bounds.height),
                    options: [.usesLineFragmentOrigin])
}
text("Next Term", size: 58, weight: .bold, hex: 0xDFE1E5, x: 172, top: 66, maxWidth: 900)
text("The missing IDE for the terminal", size: 30, weight: .regular, hex: 0x9DA0A8, x: 174, top: 140, maxWidth: 900)
text("Run Claude Code, Codex and Gemini CLI side by side, and see which one needs you. Native macOS, open source.",
     size: 22, weight: .regular, hex: 0xBCBEC4, x: 58, top: 222, maxWidth: 330)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote", outPath)
