import AppKit
import NextTermCore

/// The question asked once where a plugin owns Tab (Auto): Next Term's list, or the plugin. Raised only by a
/// real Tab. No button answers Return, so a habitual Return chooses nothing; Esc is Not Now, which leaves
/// Tab to the plugin until Next Term starts again (the second time, for good).
enum CompletionPluginQuestion {
    enum Answer {
        case nextTerm
        case plugin
        case notNow
    }

    /// The question on screen, for the self-test.
    nonisolated(unsafe) private(set) static var current: NSAlert?

    static func alert(_ plugin: CompletionOwner.Plugin) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Use Next Term’s list for Tab?"
        alert.informativeText = text(plugin)
        alert.addButton(withTitle: "Use Next Term’s List").keyEquivalent = ""
        alert.addButton(withTitle: "Keep \(plugin.name)").keyEquivalent = ""
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        return alert
    }

    static func text(_ plugin: CompletionOwner.Plugin) -> String {
        let owner = plugin.id.hasPrefix("widget:")
            ? "Tab runs “\(plugin.name)” in this shell, not zsh’s own completion."
            : "\(plugin.name) answers Tab in this shell."
        let quiet = plugin.listsAsYouType
            ? " Next Term’s list also turns off zsh-autocomplete’s list as you type, in Next Term’s tabs only; your files stay as they are."
            : ""
        let offer = " Next Term can show zsh’s completions in its own list at the cursor instead, or leave Tab to \(plugin.name)."
        let remembered = " Next Term remembers your choice on this Mac; Settings › Terminal changes it."
        return owner + offer + quiet + remembered
    }

    /// Asks over `window`; `done` gets the answer.
    static func ask(_ plugin: CompletionOwner.Plugin, in window: NSWindow, done: @escaping (Answer) -> Void) {
        let alert = alert(plugin)
        current = alert
        alert.beginSheetModal(for: window) { response in
            current = nil
            switch response {
            case .alertFirstButtonReturn: done(.nextTerm)
            case .alertSecondButtonReturn: done(.plugin)
            default: done(.notNow)
            }
        }
    }
}
