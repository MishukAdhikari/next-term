import AppKit

/// A window shown over a project window: placed under its top, it moves with it and stays above it until answered. It is
/// let go, and stays on screen on its own, when that window closes (it would take this one with it) or goes behind
/// another project's tab in the same window (it would go out of sight unanswered). The update prompt and the keep-sessions
/// sheet use it.
@MainActor
final class ProjectWindowAttachment: NSObject {
    private(set) weak var parent: NSWindow?
    private weak var child: NSWindow?

    /// Places `child` just under `parent`'s top, within its screen, and attaches it. False, with nothing changed, when
    /// there is no parent shown to attach to.
    func attach(_ child: NSWindow, over parent: NSWindow?) -> Bool {
        guard let parent, parent.isVisible, !parent.isMiniaturized else { return false }
        let size = child.frame.size
        var origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.contentTop - size.height - 64)
        if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        child.setFrameOrigin(origin)
        parent.addChildWindow(child, ordered: .above)
        self.parent = parent
        self.child = child
        NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose(_:)), name: NSWindow.willCloseNotification, object: parent)
        NotificationCenter.default.addObserver(self, selector: #selector(parentTabChanged(_:)), name: NSWindow.tabSelectionDidChange, object: parent)
        return true
    }

    /// Lets go of the parent: both observers go, so nothing brings the window back once it is answered or closed.
    func detach() {
        guard let parent else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent)
        NotificationCenter.default.removeObserver(self, name: NSWindow.tabSelectionDidChange, object: parent)
        if let child { parent.removeChildWindow(child) }
        self.parent = nil
    }

    @objc private func parentWillClose(_ note: Notification) { detach() }

    @objc private func parentTabChanged(_ note: Notification) {
        guard let parent, parent.isBackgroundTab else { return }
        let child = self.child
        detach()
        child?.orderFront(nil)
    }
}
