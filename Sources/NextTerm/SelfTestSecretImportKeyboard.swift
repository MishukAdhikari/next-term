import AppKit
import NextTermCore

#if DEBUG
/// An agent's import_secrets never takes the keyboard. With a window of the self-test's own in front and key, the
/// sheet for a file and the sheet for a password manager each come forward on the Secrets window while the cover keeps
/// the keyboard. A Return then, as the keyboard sends it, presses nothing on the sheet, and the sheet's action has no
/// Return default for when the user clicks onto it. The file and its value are made up at run time; no password
/// manager's CLI runs, and each sheet is cancelled.
extension SelfTest {
    static func secretImportKeyboardChecks(_ view: SecretsView, env: URL) async {
        let line: String = "KEYBOARD_ASKED_API_KEY=\(secretsValue("sk-" + "proj-"))\n"
        try? line.write(to: env, atomically: true, encoding: .utf8)
        await secretImportKeyboardFileCheck(view, env: env)
        await secretImportKeyboardSourceCheck(view)
    }

    /// Return, as the keyboard sends it, to the window that has the keyboard.
    static func secretImportReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let key = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }

    /// A file: its sheet comes forward over the cover, which keeps the keyboard. Import… is on, as its row is ticked,
    /// yet Return presses nothing: no confirm, the sheet and the request stay.
    static func secretImportKeyboardFileCheck(_ view: SecretsView, env: URL) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        let cover: NSWindow = await secretsMenuCover()
        defer {
            cover.close()
            requests.resetForSelfTest()
        }
        let call = secretsStart("import_secrets", ["path": env.path, "reason": "the keyboard checks"])
        guard await wait(15, { view.fileImportSheet?.asked != nil }), let sheet = view.fileImportSheet else {
            return check(false, "import_secrets: a file's sheet opens while another window has the keyboard")
        }
        let becameKey: Bool = await wait(1) { sheet.window?.isKeyWindow == true }
        let inFront: Bool = secretsMenuInFront(view.window, over: cover)
        let armed: Bool = sheet.importButton.isEnabled && !sheet.importButton.isHidden
        secretImportReturn()
        let pressed: Bool = await wait(2) { () -> Bool in
            let asked: Bool = sheet.confirmAlert != nil
            let gone: Bool = view.fileImportSheet !== sheet || requests.showing?.importAsk == nil
            return asked || gone
        }
        let coverKept: Bool = NSApp.keyWindow === cover
        let unkeyed: Bool = sheet.importButton.keyEquivalent.isEmpty && sheet.cancelButton.keyEquivalent == "\u{1b}"
        let said: String = "in front \(inFront), sheet key \(becameKey), cover key \(coverKept), Import… on \(armed), "
            + "pressed \(pressed), no Return default \(unkeyed)"
        check(inFront && !becameKey && coverKept && armed && !pressed && unkeyed,
              "import_secrets: a file's sheet comes forward without the keyboard, and Return presses nothing on it", said)
        sheet.cancelButton.performClick(nil)
        _ = await call.value
    }
}

extension SelfTest {
    /// A password manager: its sheet comes forward over the cover, which keeps the keyboard. Return opens no tab and
    /// cancels nothing: the sheet and the request stay.
    static func secretImportKeyboardSourceCheck(_ view: SecretsView) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        let cover: NSWindow = await secretsMenuCover()
        defer {
            cover.close()
            requests.resetForSelfTest()
        }
        let call = secretsStart("import_secrets", ["source": "bws", "reason": "the keyboard checks"])
        guard await wait(15, { view.managerSheet != nil }), let sheet = view.managerSheet else {
            return check(false, "import_secrets: a password manager's sheet opens while another window has the keyboard")
        }
        let becameKey: Bool = await wait(1) { sheet.window?.isKeyWindow == true }
        let inFront: Bool = secretsMenuInFront(view.window, over: cover)
        let tabs: Int = SecretManagerImportSheet.tabs.count
        secretImportReturn()
        let pressed: Bool = await wait(2) { () -> Bool in
            let opened: Bool = SecretManagerImportSheet.tabs.count != tabs
            let gone: Bool = view.managerSheet !== sheet || requests.showing?.importAsk == nil
            return opened || gone
        }
        let coverKept: Bool = NSApp.keyWindow === cover
        let unkeyed: Bool = sheet.openButton.keyEquivalent.isEmpty && sheet.cancelButton.keyEquivalent == "\u{1b}"
        let said: String = "in front \(inFront), sheet key \(becameKey), cover key \(coverKept), pressed \(pressed), "
            + "no Return default \(unkeyed)"
        check(inFront && !becameKey && coverKept && !pressed && unkeyed,
              "import_secrets: a password manager's sheet comes forward without the keyboard, and Return presses nothing "
                + "on it", said)
        sheet.cancelButton.performClick(nil)
        _ = await call.value
    }
}
#endif
