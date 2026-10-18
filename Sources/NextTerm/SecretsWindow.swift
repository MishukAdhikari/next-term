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
    /// a sheet on it. A minimised window comes out of the Dock first; AppKit may make a window it restores key, so the
    /// window that had the keyboard gets it back once Secrets is out. The user's own ways in, the menu and a
    /// reminder, use `show()`, which makes it key.
    static func bringForward() {
        if shared == nil { shared = SecretsWindowController() }
        if let controller = shared, let window = controller.window {
            if window.isMiniaturized {
                controller.keyBeforeRestore = NSApp.keyWindow
                window.deminiaturize(nil)
            }
            window.orderFront(nil)
            controller.giveKeyBack()
        }
        SecretsStore.shared.reloadIfChanged()
    }

    /// Begins `sheet` on the Secrets window for an agent's request without taking the keyboard. AppKit makes a sheet
    /// key as it begins while Next Term is active, even on a window that isn't key, so the window that had the keyboard
    /// gets it back at once, and once more after AppKit's own turn. A user already in Secrets, or with no window of Next
    /// Term's key, is left as AppKit leaves it: the sheet is theirs to click.
    static func beginWithoutKeyboard(_ sheet: NSWindow, on parent: NSWindow) {
        let before: NSWindow? = NSApp.keyWindow
        parent.beginSheet(sheet, completionHandler: nil)
        guard let before, before !== parent, before !== sheet, before.sheetParent !== parent else { return }
        let giveBack = { [weak before, weak sheet, weak parent] () -> Void in
            // Only a window of Next Term's still on screen gets it, and only while Next Term is the active app: the
            // keyboard is never taken from another app.
            guard NSApp.isActive, let before, before.isVisible, let sheet, sheet.isVisible else { return }
            let key: NSWindow? = NSApp.keyWindow
            guard key === sheet || (parent != nil && key === parent) else { return }
            before.makeKey()
        }
        giveBack()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { giveBack() }
        }
    }

    /// The window that had the keyboard when an agent's request brought Secrets out of the Dock, until the restore
    /// ends.
    private weak var keyBeforeRestore: NSWindow?

    /// The keyboard back to the window that had it before the restore, when Secrets or the sheet on it took it.
    private func giveKeyBack() {
        guard let before = keyBeforeRestore, before.isVisible, let window else { return }
        let key: NSWindow? = NSApp.keyWindow
        guard key === window || key?.sheetParent === window else { return }
        before.makeKey()
    }

    /// The restore ended: the keyboard goes back now, and once more after AppKit's own turn, in case it makes the
    /// window key after it says the window is out.
    func windowDidDeminiaturize(_ notification: Notification) {
        guard keyBeforeRestore != nil else { return }
        giveKeyBack()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.giveKeyBack()
                self.keyBeforeRestore = nil
            }
        }
    }

    /// Minimised again: an earlier restore's window is forgotten, so a restore the user makes keeps the keyboard.
    func windowDidMiniaturize(_ notification: Notification) { keyBeforeRestore = nil }

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
    func windowWillClose(_ notification: Notification) {
        keyBeforeRestore = nil
        secretsView.closeReveal()
    }
}

extension AppDelegate {
    @objc func showSecrets(_ sender: Any?) {
        MainActor.assumeIsolated { SecretsWindowController.show() }
    }
}
