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
