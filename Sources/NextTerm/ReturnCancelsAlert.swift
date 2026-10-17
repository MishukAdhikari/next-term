import AppKit

extension NSAlert {
    /// A confirm whose Cancel holds Return, so a stray Return keeps things as they are (Secrets › Pause Key Requests for
    /// 1 Hour… and Revoke All Approvals…), loses the Escape NSAlert gives a "Cancel" button by itself, and no other
    /// button has it. While the alert shows, Escape presses that Cancel too. Nil for any other alert. The caller removes
    /// the monitor when the alert ends.
    func escapePressesCancel() -> Any? {
        let choices: [NSButton] = buttons
        guard !choices.contains(where: { $0.keyEquivalent == "\u{1b}" }),
              let cancel = choices.first(where: { $0.keyEquivalent == "\r" && $0.title == "Cancel" }) else { return nil }
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak cancel] (event: NSEvent) -> NSEvent? in
            guard event.keyCode == 53, let self, let cancel else { return event } // ⎋
            let to: NSWindow? = event.window ?? NSApp.keyWindow
            guard to === self.window else { return event }
            cancel.performClick(nil)
            return nil
        }
    }
}
