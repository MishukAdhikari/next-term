import AppKit
import NextTermCore

/// The update sheet (plan 003's U11), in one process and with no update staged, so no press here can quit or install:
/// `Updater.quitForUpdate` goes ahead only for the staged version. Its title and line; its "Show Details" lines, which
/// are the planner's for the same panes; that it opens without taking the keyboard and that Return presses nothing; that
/// it never opens over a sheet; a running command in the system zsh made busy, listed first and waited for, then taken
/// out (AE16); the wait panel, its countdown, and the sheet again when another tab turns busy before the countdown's end;
/// and an open decision listed.
extension SelfTest {
    static func updateSheetChecks(_ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        let sessions = UpdateKeepSessions.shared
        let version = AppVersion("99.0.0")!
        let focus = c.activeTab?.view
        window.makeKeyAndOrderFront(nil)
        if let focus { window.makeFirstResponder(focus) }
        let defaults = AppDelegate.shared.launchDefaults
        let saved = defaults.object(forKey: UpdateFlow.rememberKey)
        defaults.removeObject(forKey: UpdateFlow.rememberKey)
        defer {
            if let saved { defaults.set(saved, forKey: UpdateFlow.rememberKey) } else { defaults.removeObject(forKey: UpdateFlow.rememberKey) }
            if sessions.flow != nil { sessions.pressed(sessions.isWaiting ? .stopWaiting : .cancel) }
        }

        // Nothing busy: the idle sheet, over the front window, without the keyboard.
        sessions.show(version: version, from: .updateButton)
        guard let sheet = sessions.sheet, let sheetWindow = sheet.window, let flow = sessions.flow else {
            return check(false, "the update sheet opens")
        }
        check(sheet.titleLabel.stringValue == "Update Next Term to 99.0.0?"
              && sheet.subtitleLabel.stringValue == "Next Term quits, installs the update and opens again.",
              "the update sheet asks to update to the version, and says Next Term quits, installs it and opens again",
              "\(sheet.titleLabel.stringValue) / \(sheet.subtitleLabel.stringValue)")
        check(sheetWindow.isVisible && !sheetWindow.isKeyWindow && (focus == nil || window.firstResponder === focus),
              "the update sheet opens without taking the keyboard")
        let keys: [String] = [UpdateButton.updateNow, .whenIQuit, .cancel].compactMap { sheet.button($0)?.keyEquivalent }
        check(keys.count == 3 && !keys.contains("\r") && sheetWindow.defaultButtonCell == nil,
              "no button on the update sheet takes Return", "\(keys.map { $0.unicodeScalars.map(\.value) })")
        // In the self-test nothing is saved, so the box is unchecked and dimmed with its reason.
        let refused = flow.plan.refusal != nil
        check(!refused || (!sheet.keepBox.isEnabled && sheet.keepBox.state == .off && !sheet.refusalLabel.isHidden),
              "with sessions that can't be kept, the box is unchecked and dimmed, and one line says why",
              "refusal \(String(describing: flow.plan.refusal)), enabled \(sheet.keepBox.isEnabled)")
        // Show Details: the planner's lines for the same panes, grouped by window.
        sheet.detailsToggle.performClick(nil)
        let planned: [String] = flow.details.map { (detail: UpdateDetail) -> String in (detail.changed ? "• " : "") + detail.text }
        let shown: [String] = sheet.detailLines
        let tabLine = c.tabs.first.map { (tab: TerminalTab) -> String in UpdatePlanning.name(of: tab) } ?? ""
        check(sheet.detailsShown && shown == planned && shown.contains { $0.hasPrefix(tabLine + ": ") },
              "Show Details lists each tab with the planner's words for it", "\(shown)")
        await screenshot(sheetWindow, suffix: "update-sheet")
        sessions.pressed(.cancel)
        check(sessions.sheet == nil && sessions.flow == nil && !sheetWindow.isVisible, "Cancel closes the sheet, and nothing quits")

        // Never over a sheet: a commit sheet, or any other, keeps it on the Update button.
        let blocker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(blocker, completionHandler: nil)
        _ = await wait(2) { window.attachedSheet != nil }
        sessions.show(version: version, from: .check)
        check(sessions.sheet == nil && sessions.flow == nil, "the update sheet does not open while a sheet is up")
        window.endSheet(blocker)
        _ = await wait(2) { window.attachedSheet == nil }

        // AE16: a long-running command in the system zsh, with the integration on, makes the sheet busy, listed first,
        // waited for.
        let busyTab = c.addTab(directory: NSTemporaryDirectory(), select: false)
        let other = c.addTab(directory: NSTemporaryDirectory(), select: false)
        defer {
            for tab in [busyTab, other] { c.remove(tab) }
        }
        guard await wait(20, { busyTab.status.integrated && other.status.integrated }) else {
            return check(false, "the update sheet's busy tabs start their shells")
        }
        busyTab.view.send(txt: "sleep 600\r")
        guard await wait(5, { busyTab.status.running }) else { return check(false, "a command runs for the update sheet") }
        sessions.show(version: version, from: .download)
        guard let busySheet = sessions.sheet, let busyFlow = sessions.flow else { return check(false, "the busy update sheet opens") }
        let buttons: [String] = busyFlow.buttons.map(\.title)
        let first = busyFlow.busyPanes.first
        check(busyFlow.state == .busy && buttons == ["Wait for Them", "Update Now", "Cancel"] && first?.id == busyTab.id
              && busyFlow.waitSet == [busyTab.id] && busySheet.waitBoxes[busyTab.id]?.state == .on,
              "a running command makes the sheet busy: listed first, in the wait set, with Wait for Them, Update Now and Cancel",
              "\(busyFlow.state), \(buttons)")
        let waitedLine = first.map(busyFlow.line) ?? ""
        check(waitedLine == "waited for", "its line says it is waited for", waitedLine)
        // Taken out: it stops at the update, then goes back on the line (R9) when the box is checked.
        busySheet.waitBoxes[busyTab.id]?.performClick(nil)
        let takenOut = sessions.flow.flatMap { (flow: UpdateFlow) -> String? in first.map(flow.line) } ?? ""
        let keeps = sessions.flow?.keep == true
        let expected = keeps ? "stops at the update, then goes back on the line" : "stops at the update, and closes"
        check(sessions.flow?.waitSet.isEmpty == true && takenOut == expected,
              "taken out of the wait, it is not waited for, and its line says it stops at the update", takenOut)
        // Wait for Them with nothing waited for: the countdown starts while it still runs.
        sessions.pressed(.waitForThem)
        check(sessions.flow?.state == .countdown && sessions.panel?.window?.isVisible == true && busyTab.status.running,
              "with every busy tab taken out, Wait for Them starts the countdown while the command still runs")
        let panelKey = sessions.panel?.window?.isKeyWindow == true
        check(!panelKey && sessions.panel?.titleLabel.stringValue.hasPrefix("Updating in") == true,
              "the countdown shows Updating in 10 s, without taking the keyboard")
        sessions.pressed(.cancel)
        check(sessions.flow == nil && sessions.panel == nil, "the countdown's Cancel ends the wait")

        // Waiting: the waited tab is listed as working, the countdown starts when it is done.
        busyTab.view.send(txt: "\u{03}")
        _ = await wait(5) { !busyTab.status.running }
        busyTab.view.send(txt: "sleep 3\r")
        guard await wait(5, { busyTab.status.running }) else { return check(false, "a short command runs for the wait") }
        sessions.show(version: version, from: .updateButton)
        sessions.pressed(.waitForThem)
        let listed = sessions.panel?.tabsStack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? NSTextField }
        let working = listed?.first?.stringValue.hasSuffix(": working") == true
        check(sessions.flow?.state == .waiting && working, "the wait panel lists the waited tab as working",
              listed?.map(\.stringValue).joined(separator: "; ") ?? "no panel")
        let counting = await wait(10) { sessions.flow?.state == .countdown }
        check(counting, "once the waited tab is done, the countdown starts")
        // A new command in another tab before the countdown's end: the sheet shows again, that line marked.
        other.view.send(txt: "sleep 600\r")
        _ = await wait(5) { other.status.running }
        let again = await wait(15) { sessions.sheet?.window?.isVisible == true && sessions.flow?.state == .busy }
        let marked = sessions.flow?.details.contains { $0.pane == other.id && $0.changed } == true
        check(again && marked && Updater.shared.validConsent == nil,
              "a new command elsewhere during the wait shows the sheet again at the countdown's end, with its line marked, and no consent")
        sessions.pressed(.cancel)
        other.view.send(txt: "\u{03}")

        // An open decision: listed on the sheet, and answered at the update quit.
        var answered = false
        let decision = UpdateHolds.shared.open(decision: "An agent asks to install a skill") { answered = true }
        sessions.show(version: version, from: .updateButton)
        let decisions: [String] = sessions.sheet?.decisionsStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        check(decisions.contains("• An agent asks to install a skill"), "an open decision the restart drops is listed on the sheet",
              "\(decisions)")
        sessions.pressed(.cancel)
        UpdateHolds.shared.cancelAll()
        check(answered, "the update quit answers each open decision")
        UpdateHolds.shared.close(decision)
        window.makeKeyAndOrderFront(nil)
        if let focus { window.makeFirstResponder(focus) }
    }
}
