import AppKit
import NextTermCore

/// "Never show this key" in the list: the lock on a key's row, and Never Show This Key…'s confirm.
extension SecretsView {
    /// The button's title, and so the right-click menu's.
    static let neverShowTitle = "Never Show This Key\u{2026}"
    static let neverShowButton = "Never Show"
    static let neverShowInfo = "You can\u{2019}t show or copy it after this. Commands you allow still get it. To change it, "
        + "replace it with a new value. This can\u{2019}t be undone."

    /// "Never show OPENAI_API_KEY again?", with Never Show and Cancel.
    static func neverShowAlert(_ name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Never show \(name) again?"
        alert.informativeText = neverShowInfo
        alert.addButton(withTitle: neverShowButton)
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// The lock column's cell: a lock, "Never shown", for a key Next Term never shows; nothing for the others.
    static func neverShownCell(_ entry: SecretVault.Entry) -> NSView {
        guard entry.writeOnly else { return NSView() }
        let help: String = SecretNewKeyDefaults.neverShownHelp
        let image: NSImage? = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: help)
        let view = NSImageView()
        view.image = image
        view.contentTintColor = .secondaryLabelColor
        view.imageScaling = .scaleProportionallyDown
        view.toolTip = help
        view.setAccessibilityLabel(help)
        return view
    }
}
