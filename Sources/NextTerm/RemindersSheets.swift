import AppKit
import NextTermCore

/// The sheets Reminders needs: Next Term's explanation before macOS asks, the line when Reminders can't be reached
/// (with Open Privacy & Security when that is where it is turned on), and the offer of the default list when the chosen
/// one couldn't be made. Each opens over `window`, or on its own when there is none. None quotes the task.
@MainActor
enum RemindersSheets {
    /// "Next Term adds your tasks to Reminders…" with Continue (then macOS asks) and Not Now (nothing changes).
    static func explain(in window: NSWindow?, answer: @escaping (Bool) -> Void) {
        #if DEBUG
        if let fakeAnswer {
            shown.append(RemindersAccess.explanation)
            return answer(fakeAnswer)
        }
        #endif
        let alert = NSAlert()
        alert.messageText = "Add tasks to Reminders?"
        alert.informativeText = RemindersAccess.explanation
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        present(alert, in: window) { answer($0 == .alertFirstButtonReturn) }
    }

    /// The line that says Reminders can't be reached, and Open Privacy & Security when `settings`.
    static func blocked(_ line: String, settings: Bool, in window: NSWindow?) {
        #if DEBUG
        if fakeAnswer != nil { return shown.append(line) }
        #endif
        let alert = NSAlert()
        alert.messageText = "Reminders can’t be used"
        alert.informativeText = line
        if settings {
            alert.addButton(withTitle: "Open Privacy & Security")
            alert.addButton(withTitle: "Cancel")
        }
        present(alert, in: window) { response in
            guard settings, response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(RemindersAccess.privacySettings)
        }
    }

    /// "Couldn’t make the list “…”." with "Add to “…” instead" and Cancel.
    static func offerDefault(_ line: String, button: String, in window: NSWindow?, answer: @escaping (Bool) -> Void) {
        #if DEBUG
        if let fakeAnswer {
            shown.append(line)
            return answer(fakeAnswer)
        }
        #endif
        let alert = NSAlert()
        alert.messageText = line
        alert.informativeText = "The task wasn’t added."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        present(alert, in: window) { answer($0 == .alertFirstButtonReturn) }
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?,
                                done: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { return done(alert.runModal()) }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { done(response) }
        }
    }

    #if DEBUG
    /// Set by the self-test: no sheet opens, each is answered with this (Continue or the offered list when true) and
    /// its line recorded in `shown`; a blocked line is recorded and nothing opens.
    nonisolated(unsafe) static var fakeAnswer: Bool?
    nonisolated(unsafe) static var shown: [String] = []
    #endif
}
