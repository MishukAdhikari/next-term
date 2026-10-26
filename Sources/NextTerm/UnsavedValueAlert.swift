import AppKit
import NextTermCore

/// The warning before database tabs with a value not saved yet close with others, with their window, or at a quit
/// (UnsavedValueWarning, R22): Cancel, the default on Return and on ⎋, or Close Anyway (Quit Anyway). It has no Save,
/// and nothing is written either way. A text file's own question, when there is one, comes first.
enum UnsavedValueAlert {
    /// `note` comes first: what else going ahead does.
    static func make(_ databases: [DatabasePane], _ action: UnsavedValueWarning.Action, note: String = "") -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UnsavedValueWarning.title(databases.map(\.name))
        let info = UnsavedValueWarning.info(databases.count, action)
        alert.informativeText = note.isEmpty ? info : note + " " + info
        // Cancel holds Return, so NSAlert gives it no ⎋ (escapePressesCancel does); the go-ahead holds no key at all.
        let titles = UnsavedValueWarning.buttons(action)
        alert.addButton(withTitle: titles[0]).keyEquivalent = "\r"
        alert.addButton(withTitle: titles[1]).keyEquivalent = ""
        return alert
    }

    /// As a sheet on `window`, ⎋ pressing Cancel: `then` hears true for Close Anyway, false for Cancel.
    static func begin(_ alert: NSAlert, over window: NSWindow, then: @escaping (Bool) -> Void) {
        let escape: Any? = alert.escapePressesCancel()
        alert.beginSheetModal(for: window) { response in
            if let escape { NSEvent.removeMonitor(escape) }
            then(response == .alertSecondButtonReturn)
        }
    }
}
