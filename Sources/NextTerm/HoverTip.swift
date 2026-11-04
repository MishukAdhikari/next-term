import AppKit

/// A tab's whole name under it, after the pointer rests on it a moment, when the tab shows it cut short: AppKit shows no
/// tooltip for a view in the window's title-bar strip, where the tab bars sit. It looks like a macOS tooltip, takes no
/// clicks, and goes with the pointer, a click or the tab.
@MainActor
final class HoverTip {
    static let shared = HoverTip()
    /// How long the pointer rests before it shows: at once to the eye, while a quick pass over the tabs flashes nothing.
    static let delay: TimeInterval = 0.1
    /// How long it stays at most, as a macOS tooltip does: it never outlives the pointer's rest.
    static let shownFor: TimeInterval = 5

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private weak var owner: NSView?
    /// While it shows: the pointer's moves and clicks, in Next Term and outside it, so it goes as soon as the pointer is
    /// off its tab, however fast it left.
    private var monitors: [Any] = []
    /// The window told to send the pointer's moves while it shows, and what it sent before: the title strip sends no
    /// "pointer left" to the tab, so the moves are how it knows.
    private weak var movesWindow: NSWindow?
    private var movesBefore = false
    /// A tab whose name has had its showing (it ran its time, or a click, key or scroll put it away) while the pointer is
    /// still on it: it shows again only once the pointer has been off it, as a macOS tooltip does.
    /// The pointer leaving it (TabBarView follows it) frees it: `hide(from:)`.
    private weak var spent: NSView?

    /// The pointer is on `view`, come in or moving there: its name shows after `delay`, unless it shows or waits already,
    /// or has had its showing. The title strip tells a tab neither that the pointer left nor, after that, that it came
    /// back, so a tab calls this on every move, not only when the pointer comes in.
    func rest(_ text: String, on view: NSView) {
        guard owner !== view, spent !== view else { return }
        unspend()
        schedule(text, under: view)
    }

    /// Shows `text` under `view` once the pointer has rested there `delay` seconds.
    func schedule(_ text: String, under view: NSView) {
        hide()
        owner = view
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, view.window?.isVisible == true, self.owner === view else { return }
            self.show(text, under: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Puts it away, or only if `view` is what it shows under.
    func hide(from view: NSView? = nil) {
        if let view, view === spent { unspend() }
        if let view, view !== owner { return }
        pending?.cancel()
        pending = nil
        owner = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        movesWindow?.acceptsMouseMovedEvents = movesBefore
        movesWindow = nil
        if let panel, let parent = panel.parent { parent.removeChildWindow(panel) }
        panel?.orderOut(nil)
    }

    /// A click on `view`: its name goes, and stays away while the pointer stays there.
    func clicked(_ view: NSView) {
        hide()
        spend(view)
    }

    /// What it shows now, for the self-test; nil while hidden.
    var shownText: String? { panel?.isVisible == true ? label.stringValue : nil }

    private func show(_ text: String, under view: NSView) {
        guard let window = view.window else { return }
        let panel = self.panel ?? make()
        label.stringValue = text
        let size = label.fittingSize
        let pad = NSSize(width: 7, height: 3)
        let width = min(size.width + 2 * pad.width, 560)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var frame = NSRect(x: anchor.minX + 6, y: anchor.minY - size.height - 2 * pad.height - 4, width: width, height: size.height + 2 * pad.height)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame { frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width) }
        panel.setFrame(frame, display: false)
        label.frame = NSRect(x: pad.width, y: pad.height, width: width - 2 * pad.width, height: size.height)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        movesBefore = window.acceptsMouseMovedEvents
        movesWindow = window
        window.acceptsMouseMovedEvents = true
        let expiry = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.owner === view else { return }
            self.hide()
            self.spend(view)
        }
        pending = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownFor, execute: expiry)
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.check(event)
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            },
        ].compactMap { $0 }
    }

    /// A move that leaves the tab, or any click, scroll or key: it goes.
    private func check(_ event: NSEvent) {
        guard let view = owner else { return hide() }
        guard event.type == .mouseMoved else {
            hide()
            return spend(view)
        }
        if !Self.pointer(on: view) { hide() }
    }

    private static func pointer(on view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// `view`'s showing is over while the pointer stays on it: nothing more until the pointer has been off it.
    private func spend(_ view: NSView) {
        guard Self.pointer(on: view) else { return }
        spent = view
    }

    private func unspend() { spent = nil }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.tabHover.cgColor
        background.layer?.cornerRadius = 5
        background.layer?.borderWidth = 1
        background.layer?.borderColor = WorkSplitView.line.cgColor
        panel.contentView = background
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingMiddle
        background.addSubview(label)
        self.panel = panel
        return panel
    }
}
