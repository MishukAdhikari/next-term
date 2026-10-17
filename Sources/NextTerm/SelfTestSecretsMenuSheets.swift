import AppKit
import NextTermCore

#if DEBUG
/// The Secrets menu against what is open: a sheet of the user's on the list, which nothing opens over; request_secret's
/// window and an agent's import, which Show Key Request brings forward (a minimised Secrets window restored first); and
/// an agent's import sheet, over which Pause asks, Escape cancelling. Keys, values and files are made up at run time.
extension SelfTest {
    /// Escape, as the keyboard sends it, to the window that has the keyboard.
    static func secretsMenuEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let key = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true),
              let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }

    /// A plain window of the self-test's own, in front and key, so a check sees what comes forward over it.
    static func secretsMenuCover() async -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let cover = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.title = "Self-Test Cover"
        cover.center()
        cover.makeKeyAndOrderFront(nil)
        _ = await wait(5) { NSApp.keyWindow === cover }
        return cover
    }

    /// `window` came forward over `cover`, which kept the keyboard.
    static func secretsMenuInFront(_ window: NSWindow?, over cover: NSWindow) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.orderedIndex < cover.orderedIndex && NSApp.keyWindow === cover && !window.isKeyWindow
    }

    /// With Add…'s sheet open on the list, Pause and every import open nothing over it, pause nothing, and the line says
    /// to finish first. A File…'s open panel is stood in, so a failure shows no panel.
    static func secretsMenuBusyChecks(_ secrets: NSMenu, _ view: SecretsView, base: URL) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        SecretsMenu.answerPause = nil
        SecretsView.pickedForSelfTest = base.appendingPathComponent("menu-busy-none.env")
        defer { SecretsView.pickedForSelfTest = nil }
        await secretsMenuFocus(view)
        view.add()
        guard await wait(5, { view.sheet != nil }), let open = view.sheet else {
            return check(false, "secrets menu: Add…'s sheet opens for the busy checks")
        }
        let preset: String = SecretImportPreset.allCases.first?.rawValue ?? ""
        let items: [NSMenuItem?] = [secretsMenuItem(secrets, #selector(SecretsMenu.toggleKeyRequestPause(_:))),
                                    secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromFile(_:))),
                                    secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromMCPConfigs(_:))),
                                    secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromManager(_:)), preset)]
        var refused: [String] = []
        for item in items {
            view.say("")
            secretsMenuChoose(item)
            let sheets: Bool = view.importSheet == nil && view.fileImportSheet == nil && view.managerSheet == nil
            let nothingNew: Bool = view.sheet === open && view.alert == nil && sheets && requests.pausedUntil == nil
            if nothingNew && view.actionLabel.stringValue == SecretsMenuModel.busyLine { refused.append(item?.title ?? "") }
        }
        check(items.allSatisfy { $0 != nil } && refused.count == items.count,
              "secrets menu: with Add…'s sheet open, Pause and the imports open nothing and say to finish first",
              refused.joined(separator: ", "))
        open.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
        view.say("")
    }
}

// MARK: Show Key Request: request_secret's window and an agent's import

extension SelfTest {
    /// request_secret's window, behind another: Show Key Request brings it forward, not key and unanswered.
    static func secretsMenuRequestWindowCheck(_ secrets: NSMenu) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        let item: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.showKeyRequest(_:)))
        let call = secretsStart("request_secret", ["name": "MENU_REQUEST_KEY", "reason": "the menu checks"])
        guard await wait(10, { requests.showing?.requestWindow != nil }), let window = requests.showing?.requestWindow?.window else {
            return check(false, "secrets menu: request_secret opens its window")
        }
        let cover: NSWindow = await secretsMenuCover()
        defer { cover.close() }
        let behind: Bool = window.orderedIndex > cover.orderedIndex
        secretsMenuChoose(item)
        let inFront: Bool = secretsMenuInFront(window, over: cover)
        let unanswered: Bool = requests.showing?.requestWindow?.window === window
        check(behind && inFront && unanswered,
              "secrets menu: Show Key Request brings request_secret's window forward, not key and unanswered",
              "behind \(behind), in front \(inFront)")
        requests.showing?.requestWindow?.declineButton.performClick(nil)
        _ = await call.value
    }

    /// An agent's import_secrets for a made-up file: its sheet on the Secrets window, the request showing, and the call
    /// that waits for its answer.
    static func secretsMenuAskedImport(_ view: SecretsView,
                                       base: URL) async -> (sheet: SecretFileImportSheet, call: Task<[String: Any], Never>)? {
        let env: URL = base.appendingPathComponent("menu-asked.env")
        try? "MENU_ASKED_TOKEN=\(secretsValue("asked-"))\n".write(to: env, atomically: true, encoding: .utf8)
        let call = secretsStart("import_secrets", ["path": env.path, "reason": "the menu checks"])
        guard await wait(15, { view.fileImportSheet?.asked != nil }), let sheet = view.fileImportSheet else {
            check(false, "secrets menu: an agent's import opens its sheet on the Secrets window")
            SecretRequests.shared.resetForSelfTest()
            return nil
        }
        return (sheet, call)
    }
}

extension SelfTest {
    /// An agent's import sheet up: Show Key Request brings the Secrets window forward from behind another, not key, and
    /// out of the Dock when it was minimised there. Pause asks over the sheet, which has no Pause of its own; Escape
    /// cancels and leaves the request; Pause for 1 Hour ends it, its sheet closing and the agent answered.
    static func secretsMenuImportRequestChecks(_ secrets: NSMenu, _ view: SecretsView, base: URL) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        SecretsMenu.answerPause = nil
        defer {
            requests.resetForSelfTest()
            try? FileManager.default.removeItem(at: base.appendingPathComponent("menu-asked.env"))
        }
        await secretsMenuFocus(view)
        guard let window = view.window, let opened = await secretsMenuAskedImport(view, base: base) else { return }
        let sheet: SecretFileImportSheet = opened.sheet
        let show: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.showKeyRequest(_:)))
        let cover: NSWindow = await secretsMenuCover()
        secretsMenuChoose(show)
        let inFront: Bool = secretsMenuInFront(window, over: cover)
        cover.close()
        window.miniaturize(nil)
        let minimised: Bool = await wait(5) { window.isMiniaturized }
        secretsMenuChoose(show)
        let restored: Bool = await wait(5) { !window.isMiniaturized && window.isVisible }
        check(inFront && minimised && restored && view.fileImportSheet === sheet,
              "secrets menu: Show Key Request brings an agent's import forward, not key, and restores a minimised Secrets window",
              "in front \(inFront), minimised \(minimised), restored \(restored)")

        let pause: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.toggleKeyRequestPause(_:)))
        window.makeKeyAndOrderFront(nil)
        _ = await wait(5) { NSApp.keyWindow === sheet.window }
        secretsMenuChoose(pause)
        let asked: Bool = await wait(5) { view.alert != nil }
        let over: Bool = view.alert?.window.sheetParent === sheet.window
        secretsMenuEscape()
        let escaped: Bool = await wait(5) { view.alert == nil }
        let kept: Bool = view.fileImportSheet === sheet && requests.showing != nil && requests.pausedUntil == nil
        check(asked && over && escaped && kept,
              "secrets menu: with an agent's import sheet up, Pause asks over it, and Escape cancels, leaving the request",
              "asked \(asked), over \(over), escaped \(escaped), kept \(kept)")

        secretsMenuChoose(pause)
        _ = await wait(5) { view.alert != nil }
        view.alert?.buttons.first?.performClick(nil)
        let closed: Bool = await wait(5) { view.fileImportSheet == nil }
        let paused: Bool = requests.pausedUntil != nil && requests.showing == nil
        var status: String?
        if closed { status = await opened.call.value["status"] as? String }
        check(closed && paused && status != nil && status != "imported",
              "secrets menu: Pause for 1 Hour over an agent's import ends it: its sheet closes and the agent hears no import",
              status ?? "no answer")
    }
}

// MARK: Revoke All Approvals…' sheet

extension SelfTest {
    /// With one approval in force: Add…'s sheet open, Revoke All opens nothing and says to finish first; its confirm
    /// cancels on Escape too; while it shows, a second approval allowed in the panel makes it say 2; Revoke ends both.
    static func secretsMenuRevokeSheetChecks(_ item: NSMenuItem?, _ view: SecretsView) async {
        let requests = SecretRequests.shared
        await secretsMenuFocus(view)
        view.add()
        _ = await wait(5) { view.sheet != nil }
        view.say("")
        secretsMenuChoose(item)
        let busy: Bool = view.sheet != nil && view.alert == nil && view.actionLabel.stringValue == SecretsMenuModel.busyLine
        view.sheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
        view.say("")
        check(busy && requests.grants.count == 1,
              "secrets menu: with Add…'s sheet open, Revoke All opens nothing and says to finish first")

        await secretsMenuFocus(view)
        secretsMenuChoose(item)
        _ = await wait(5) { view.alert != nil }
        secretsMenuEscape()
        let escaped: Bool = await wait(5) { view.alert == nil }
        check(escaped && requests.grants.count == 1,
              "secrets menu: Escape cancels Revoke All's confirm too, keeping the approval")

        await secretsMenuFocus(view)
        secretsMenuChoose(item)
        _ = await wait(5) { view.alert != nil }
        let second = secretsRequest(asker: "wrapper:selftest-menu-revoke-2", command: ["true"], names: ["MENU_KEY"])
        let answers = SecretsAnswers()
        requests.ask(second) { answers.take($0) }
        second.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        second.panel?.allowButton.performClick(nil)
        _ = await wait(10) { requests.grants.count == 2 }
        let recounted: Bool = await wait(5) { view.alert?.informativeText == SecretsMenuModel.revokeConfirmText(2) }
        view.alert?.buttons.first?.performClick(nil)
        let ended: Bool = await wait(5) { requests.grants.isEmpty }
        check(recounted && ended,
              "secrets menu: Revoke All's confirm counts an approval allowed while it shows, and Revoke ends them all",
              view.alert?.informativeText ?? "\(requests.grants.count) left")
    }
}
#endif
