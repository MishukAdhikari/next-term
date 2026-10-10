import AppKit
import NextTermCore

/// The resume question at a quit (QuitPolicy, R29): the plain "Quit Next Term?" dialog on its own, when no other quit
/// alert shows, or the checkbox "Reopen windows and resume sessions when Next Term opens" on the save-changes or
/// "Quitting stops…" alert. The box starts at the stored "At launch" choice, checked when none is stored. Its answer sets
/// Settings › General's "At launch" once the quit goes ahead, and Quit with it checked is the quit consent (R30). And why
/// the quit happens, read from its Apple event.
final class QuitReopenPrompt {
    let alert = NSAlert()
    /// The buttons in the order they were added: "Quit", then "Cancel".
    let buttons: [QuitPromptButton] = QuitPolicy.promptButtons
    let checkbox: NSButton

    /// For the windows' projects, each once, in order: the checkbox's tooltip names them.
    init(projects: [String], checked: Bool) {
        alert.messageText = QuitPolicy.promptTitle
        alert.informativeText = ""
        // NSAlert gives the first button Return, and the button titled "Cancel" the ⎋ key, which ⌘. presses too. Quit's
        // Return is cleared, so no button is the default and Return quits nothing.
        for button in buttons {
            let added = alert.addButton(withTitle: button.title)
            if button == .quit { added.keyEquivalent = "" }
        }
        checkbox = Self.addCheckbox(to: alert, checked: checked, projects: projects)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
    }

    /// The dialog as the quit asks it (`QuitAsking.ask`): Quit or Cancel, then the box and "Don’t ask again" as the user
    /// left them.
    var dialog: QuitAlertDialog {
        QuitAlertDialog(alert, presses: buttons.map(\.press), box: checkbox)
    }

    /// The answer of the button pressed, read from the button: Quit with the box's state and "Don’t ask again". Nil for
    /// "Cancel" (⎋, ⌘.), whatever is checked.
    func answer(for response: NSApplication.ModalResponse) -> QuitAnswer? {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return nil }
        let dontAskAgain = alert.suppressionButton?.state == .on
        return buttons[index].answer(resume: checkbox.state == .on, dontAskAgain: dontAskAgain)
    }

    /// "Reopen windows and resume sessions when Next Term opens", on the plain dialog or on the save-changes or "Quitting
    /// stops…" alert, starting as given. Its tooltip names the projects. The alerts have no "Don’t ask again": their
    /// checkbox sets only "At launch". Read once the alert returns.
    @discardableResult
    static func addCheckbox(to alert: NSAlert, checked: Bool, projects: [String]) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: QuitPolicy.checkboxTitle, target: nil, action: nil)
        checkbox.state = checked ? .on : .off
        checkbox.toolTip = QuitPolicy.checkboxToolTip(projects)
        checkbox.sizeToFit()
        alert.accessoryView = checkbox
        alert.showsSuppressionButton = false
        return checkbox
    }

    /// A logout, restart or shutdown, from the `kAEQuitReason` attribute loginwindow puts in its quit event, or the user's
    /// own quit: ⌘Q and the Dock's Quit come with no event, and a scripted quit with no such reason.
    static func reason(of event: NSAppleEventDescriptor?) -> QuitReason {
        QuitReason(appleEventReason: reasonCode(of: event))
    }

    /// The quit event's `kAEQuitReason` (a type code, or else an enumerated one); nil with no quit event or no reason.
    static func reasonCode(of event: NSAppleEventDescriptor?) -> UInt32? {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let why = event.attributeDescriptor(forKeyword: kAEQuitReason) else { return nil }
        return why.typeCodeValue != 0 ? why.typeCodeValue : why.enumCodeValue
    }
}

/// A quit question's alert as `QuitAsking.ask` asks it: each button, in the order it was added, a press; the resume box
/// on it, when it carries one, and "Don’t ask again" when it shows one. The boxes are read only once `runModal` has
/// returned, so the answer is the box as the user left it, never as it started.
final class QuitAlertDialog: QuitDialog {
    let alert: NSAlert
    private let presses: [QuitPress]
    private let box: NSButton?

    init(_ alert: NSAlert, presses: [QuitPress], box: NSButton?) {
        self.alert = alert
        self.presses = presses
        self.box = box
    }

    /// Shows the alert and waits: the press of the button that ended it, Cancel for any other way it ended.
    func run() -> QuitPress {
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return presses.indices.contains(index) ? presses[index] : .cancel
    }

    var resumeBox: Bool? { box.map { (box: NSButton) -> Bool in box.state == .on } }

    var dontAskAgain: Bool { alert.showsSuppressionButton && alert.suppressionButton?.state == .on }
}
