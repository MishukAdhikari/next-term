import AppKit

/// The pastes into one value field, by ⌘V, Edit › Paste or the field's menu: the pasteboard's change count at the last
/// one, never its contents, so Save clears the clipboard only when nothing was copied since. A paste counts only when it
/// reaches this field: its window is the key window, where a paste goes, and the field is being edited there. A paste in
/// another window, while this field still holds its own window's keyboard, is not this field's: Save would clear a
/// clipboard that never held the key, and say it did (review finding #24).
@MainActor
final class SecretPasteWatch {
    private weak var field: NSTextField?
    private var observer: NSObjectProtocol?
    private(set) var pastedAt: Int?

    init(_ field: NSTextField) {
        self.field = field
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.userInfo?["MenuItem"] as? NSMenuItem
            MainActor.assumeIsolated {
                guard let self, item?.action == #selector(NSText.paste(_:)), let field = self.field, Self.reaches(field) else { return }
                self.record()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Whether a paste sent now reaches `field`: its window is key and its editor is that window's first responder.
    static func reaches(_ field: NSTextField) -> Bool {
        guard let window = field.window, window.isKeyWindow, let editor = window.firstResponder as? NSText else { return false }
        return editor.delegate === field
    }

    /// A paste into the field: the change count it is compared with on Save.
    func record() {
        pastedAt = SecretClipboard.shared.recordPaste()
    }
}
