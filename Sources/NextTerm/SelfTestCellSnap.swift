import AppKit

/// A tab's font is set before the tab is in a window, so SwiftTerm snaps its cell width to the main screen's scale. On a
/// display of another scale, box-drawing lines then drift from the text a little more each column, and a table's lines
/// cut into its words. The cells must follow the window's own screen: a view whose font was set first, put in a window
/// on each screen, and a tab's window moved from one screen to the other. Needs two displays of different scales.
extension SelfTest {
    static func cellSnapChecks(_ c: TerminalWindowController) async {
        let screens = NSScreen.screens.sorted { $0.backingScaleFactor < $1.backingScaleFactor }
        guard let low = screens.first, let high = screens.last, low.backingScaleFactor != high.backingScaleFactor,
              let window = c.window else {
            return note("cell snap: not checked, as it needs two displays of different scales")
        }
        func snapped(_ font: NSFont, _ scale: CGFloat) -> CGFloat {
            let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
            return max(1, (advance * scale).rounded() / scale)
        }
        func scaleName(_ scale: CGFloat) -> String { "\(Int(scale))x" }

        // A half-point size, where the two scales snap to different widths (at 13 pt they happen to agree).
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        for screen in [low, high] {
            let view = NextTermView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            view.font = font
            let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 640, height: 400)
            let host = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
            host.isReleasedWhenClosed = false
            host.contentView = view
            host.orderFront(nil)
            let scale = screen.backingScaleFactor
            _ = await wait(3) { abs(view.cellSize.width - snapped(font, scale)) < 0.001 }
            check(abs(view.cellSize.width - snapped(font, scale)) < 0.001,
                  "cell snap: a terminal whose font was set first takes the cells of the \(scaleName(scale)) display it opens on",
                  "cell \(view.cellSize.width), snapped there \(snapped(font, scale))")
            host.orderOut(nil)
            host.contentView = nil
        }

        let tab = c.addTab(directory: NSTemporaryDirectory())
        defer { c.remove(tab) }
        let start = window.frame
        defer { window.setFrame(start, display: true) }
        for screen in [low, high] {
            let area = screen.visibleFrame
            let size = NSSize(width: min(start.width, area.width - 80), height: min(start.height, area.height - 80))
            window.setFrame(NSRect(origin: NSPoint(x: area.minX + 40, y: area.minY + 40), size: size), display: true)
            let scale = screen.backingScaleFactor
            _ = await wait(3) { window.backingScaleFactor == scale && abs(tab.view.cellSize.width - snapped(tab.view.font, scale)) < 0.001 }
            check(abs(tab.view.cellSize.width - snapped(tab.view.font, scale)) < 0.001,
                  "cell snap: a tab's window moved to the \(scaleName(scale)) display takes its cells",
                  "window \(window.backingScaleFactor)x, cell \(tab.view.cellSize.width), snapped there \(snapped(tab.view.font, scale))")
        }
    }
}
