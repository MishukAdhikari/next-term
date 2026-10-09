import AppKit
import NextTermCore

/// The restore's two alerts (R21), each shown once, after the launch has shown its windows. Safe mode: the layout came
/// back with nothing typed or run, because the last two restores did not finish; "Keep As Is", the default, leaves the
/// tabs as they are, and "Try Again" applies what each held, once. Set aside: a third restore did not finish, so the
/// snapshot was moved out of the way, and the alert says where.
@MainActor
enum SessionRestoreAlerts {
    /// Safe mode's question, app-modal. Return presses Keep As Is. `text` says what Try Again does
    /// (`RestoreAlertText.safeModeText(for:)`): it promises a resume only when a pane would resume.
    static func askAfterSafeMode(text: String) {
        let sessions = SessionRestore.shared
        guard sessions.phase == .safeMode else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RestoreAlertText.safeModeTitle
        alert.informativeText = text
        alert.addButton(withTitle: RestoreAlertText.keepAsIs)
        alert.addButton(withTitle: RestoreAlertText.tryAgain)
        guard alert.runModal() == .alertSecondButtonReturn else { return sessions.keepAsIs() }
        if !sessions.tryAgain() { tellNotCounted() }
    }

    /// Try Again could not count its try, so it ran nothing, and the tabs stay as they are.
    static func tellNotCounted() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RestoreAlertText.notCountedTitle
        alert.informativeText = RestoreAlertText.notCountedText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The snapshot set aside, and where it went; or, when it could not be moved, the folder it stays in.
    static func tellSetAside(folder: String, name: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RestoreAlertText.setAsideTitle
        alert.informativeText = RestoreAlertText.setAsideText(folder: folder, name: name)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
