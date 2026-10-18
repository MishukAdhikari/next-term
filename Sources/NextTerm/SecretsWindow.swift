import AppKit
import NextTermCore

/// The Secrets window (Secrets › Show Secrets; no default key): the same list as Settings › Secrets, in a window of its
/// own. Settings › Keyboard Shortcuts can give Show Secrets a key. The open window is listed in Window's window list.
@MainActor
final class SecretsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SecretsWindowController?

    private(set) var secretsView = SecretsView()

    static func show() {
        if shared == nil { shared = SecretsWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        SecretsStore.shared.reloadIfChanged()
    }

    /// In front without taking the keyboard, for an agent's request: a key the user meant for a terminal never reaches
    /// a sheet on it. A minimised window comes out of the Dock first. The user's own ways in, the menu and a reminder,
    /// use `show()`, which makes it key.
    static func bringForward() {
        if shared == nil { shared = SecretsWindowController() }
        if let window = shared?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
        SecretsStore.shared.reloadIfChanged()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Secrets"
        window.minSize = NSSize(width: 540, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = secretsView
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A revealed key goes when the window closes.
    func windowWillClose(_ notification: Notification) { secretsView.closeReveal() }
}

extension AppDelegate {
    @objc func showSecrets(_ sender: Any?) {
        MainActor.assumeIsolated { SecretsWindowController.show() }
    }
}
