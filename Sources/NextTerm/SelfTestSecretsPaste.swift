import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// A paste counts for a value field only when it reaches that field (review finding #24): with Add…'s value field
    /// holding its sheet's keyboard while another window is key, Edit › Paste is that window's, so Save would clear
    /// nothing; with the sheet key again, a paste is the field's.
    static func secretsPasteFieldChecks(view: SecretsView) async {
        view.add()
        guard let sheet = view.sheet, let sheetWindow = sheet.window else {
            return check(false, "secrets: Add… opens its sheet for the paste checks")
        }
        sheetWindow.makeFirstResponder(sheet.valueField)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered,
                             defer: false)
        other.isReleasedWhenClosed = false
        other.title = "Self-test: another window"
        other.makeKeyAndOrderFront(nil)
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        func sendPaste() {
            NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: NSMenu(), userInfo: ["MenuItem": paste])
        }

        sendPaste()
        let counted = await wait(1) { sheet.pastedAt != nil }
        let editing: Bool = (sheetWindow.firstResponder as? NSText)?.delegate === sheet.valueField
        check(editing && !sheetWindow.isKeyWindow && !counted,
              "secrets: a paste in another window, while Add…'s value field holds its sheet's keyboard, is not counted as the field's",
              "editing: \(editing), sheet key: \(sheetWindow.isKeyWindow)")

        other.close()
        sheetWindow.makeKey()
        sheetWindow.makeFirstResponder(sheet.valueField)
        // Only when this Mac lets the sheet be key (Next Term in front): then a paste is the field's. Otherwise the run
        // says the check was skipped, so a paste never counted doesn't pass unseen.
        if sheetWindow.isKeyWindow {
            sendPaste()
            let reached = await wait(2) { sheet.pastedAt != nil }
            check(reached, "secrets: a paste into Add…'s value field, its sheet key, is counted")
        } else {
            note("secrets: the check that a paste into Add…'s value field is counted is skipped, its sheet can't be key: "
                 + notFrontmost(sheetWindow))
        }
        sheet.cancel()
        _ = await wait(5) { view.sheet == nil }
    }
}
#endif
