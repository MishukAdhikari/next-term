import AppKit
import NextTermCore

/// The reopen question at a quit (QuitPolicy): "Reopen these projects next time?" on its own, when no other quit
/// alert shows, or the checkbox on the save-changes or "Quitting stops…" alert. The answer sets Settings › General's
/// "When Next Term opens" once the quit goes ahead. And why the quit happens, read from its Apple event.
final class QuitReopenPrompt {
    let alert = NSAlert()
    /// The buttons in the order they were added: the choice that matches the setting first, so it is the default.
    let buttons: [QuitPromptButton]

    /// For the windows' projects, each once, in order.
    init(projects: [String], returnKeyReopens: Bool) {
        buttons = QuitPolicy.promptButtons(returnKeyReopens: returnKeyReopens)
        let one = QuitPolicy.projectNames(projects).count == 1
        alert.messageText = one ? "Reopen this project next time?" : "Reopen these projects next time?"
        alert.informativeText = "Next time Next Term opens, it can reopen \(QuitPolicy.projectList(projects)), or show the "
            + "Welcome window. You can change this in Settings › General."
        // NSAlert gives the button titled "Cancel" the ⎋ key, and ⌘. presses it too: no keys of its own.
        for button in buttons { alert.addButton(withTitle: button.title) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
    }

    /// Shows it and waits: the answer, or nil when the quit is cancelled.
    func run() -> QuitAnswer? { answer(for: alert.runModal()) }

    /// The answer of the button pressed, read from the button and never from its place, which follows the setting.
    /// Nil for "Cancel" (⎋, ⌘.), with "Don’t ask again" checked or not.
    func answer(for response: NSApplication.ModalResponse) -> QuitAnswer? {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return nil }
        let dontAskAgain = alert.suppressionButton?.state == .on
        return buttons[index].answer(dontAskAgain: dontAskAgain)
    }

    /// "Reopen the open projects next time", on the save-changes or "Quitting stops…" alert, starting at the current
    /// setting. Its tooltip names the projects. The alert has no "Don’t ask again": its checkbox sets only "When Next
    /// Term opens". Read once the alert returns.
    @discardableResult
    static func addCheckbox(to alert: NSAlert, checked: Bool, projects: [String]) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "Reopen the open projects next time", target: nil, action: nil)
        checkbox.state = checked ? .on : .off
        checkbox.toolTip = "On, Next Term reopens \(QuitPolicy.projectList(projects)) next time it opens. Off, it shows "
            + "the Welcome window. You can change this in Settings › General."
        checkbox.sizeToFit()
        alert.accessoryView = checkbox
        alert.showsSuppressionButton = false
        return checkbox
    }

    /// A logout, restart or shutdown, from the `kAEQuitReason` attribute loginwindow puts in its quit event (a type
    /// code, or else an enumerated one), or the user's own quit: ⌘Q and the Dock's Quit come with no event, and a
    /// scripted quit with no such reason.
    static func reason(of event: NSAppleEventDescriptor?) -> QuitReason {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let why = event.attributeDescriptor(forKeyword: kAEQuitReason) else { return .user }
        let code = why.typeCodeValue != 0 ? why.typeCodeValue : why.enumCodeValue
        return QuitReason(appleEventReason: code)
    }
}
