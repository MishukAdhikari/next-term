import AppKit
import NextTermCore

#if DEBUG
/// "How do you like to work?": the sheet over the Welcome window, its words and its default button, Escape skipping with
/// nothing changed, and each card's layout applied by its own action, a project window screenshot after each, with a second
/// window open so the window column shows. The layout settings, hints and offers are put back after.
/// NEXTTERM_SELFTEST_ONLY=layoutPicker runs it alone.
extension SelfTest {
    static func layoutPickerChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let defaults = UserDefaults.standard
        let saved = (position: app.terminalPosition, side: app.sidebarSide, tabs: app.terminalTabs,
                     column: defaults.object(forKey: WindowColumnSettings.shownKey), columnSide: defaults.object(forKey: "windowColumnSide"),
                     expanded: defaults.object(forKey: WindowColumnSettings.expandedKey),
                     offers: WindowColumnOffer.keys.map { defaults.object(forKey: $0) }, hints: HintRules.keys.map { defaults.object(forKey: $0) })
        let file = proj.appendingPathComponent("layout.txt")
        try? "layout\n".write(to: file, atomically: true, encoding: .utf8)
        var second: TerminalWindowController?
        WindowColumns.suppressed = false
        defer {
            LayoutPickerSheet.current?.skip()
            app.welcomeController?.close()
            if let second, !second.hasClosed { second.window?.close() }
            try? FileManager.default.removeItem(at: file)
            if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
            app.moveTerminal(to: saved.position)
            app.moveTerminalTabs(to: saved.tabs)
            restoreDefault(saved.column, WindowColumnSettings.shownKey)
            restoreDefault(saved.columnSide, "windowColumnSide")
            restoreDefault(saved.expanded, WindowColumnSettings.expandedKey)
            for (key, value) in zip(WindowColumnOffer.keys, saved.offers) { restoreDefault(value, key) }
            for (key, value) in zip(HintRules.keys, saved.hints) { restoreDefault(value, key) }
            WindowColumns.suppressed = true
            app.windowColumns.rebuild()
            app.controllers.forEach { $0.applyLayout() }
        }

        // The sheet over the Welcome window, as a new install's first launch shows it.
        app.showWelcome(nil)
        guard let welcome = app.welcomeController?.window, let sheet = LayoutPickerSheet.present(over: welcome),
              let panel = sheet.window else { return check(false, "layout picker: the sheet opens over the Welcome window") }
        _ = await wait(3) { welcome.attachedSheet === panel }
        panel.layoutIfNeeded()
        await screenshot(panel, suffix: "-layout-picker")
        let names: [String] = sheet.cards.map(\.nameLabel.stringValue)
        let lines: [String] = sheet.cards.map(\.lineLabel.stringValue)
        check(sheet.titleLabel.stringValue == "How do you like to work?"
              && names == ["IDE", "Terminal", "Agents"]
              && lines == ["Project folder on the left, terminal in the middle, windows on the right.",
                           "Windows and project folder on the left, terminal on the right.",
                           "Project folder on the left, the terminal’s tabs listed down the side, windows on the right."]
              && sheet.footerLabel.stringValue == "After you start a coding agent, ask it to set Next Term up your way, or change it anytime in Settings.",
              "layout picker: the title, three cards with their names and lines, and the footer", "\(names) \(lines)")
        check(sheet.cards.map { $0.accessibilityLabel() ?? "" } == LayoutPreset.allCases.map(\.accessibilityLabel)
              && sheet.cards.first?.accessibilityLabel()?.hasPrefix("IDE layout: ") == true,
              "layout picker: VoiceOver reads each card as “IDE layout: …”", sheet.cards.first?.accessibilityLabel() ?? "")
        check(sheet.skipButton.title == "Skip" && sheet.skipButton.keyEquivalent == "\r" && panel.defaultButtonCell === sheet.skipButton.cell,
              "layout picker: Skip is the default button, Return's", "“\(sheet.skipButton.title)”, key \(sheet.skipButton.keyEquivalent.debugDescription)")
        let previews: [NSSize] = sheet.cards.map(\.preview.frame.size)
        check(previews.allSatisfy { $0 == LayoutPreview.size }, "layout picker: each preview is 180 × 112 points", "\(previews)")

        // Escape skips: nothing changes.
        let before = (app.terminalPosition, app.sidebarSide, app.terminalTabs, app.showsWindowColumn, app.windowColumnOnRight)
        panel.cancelOperation(nil)
        let closed: Bool = await wait(3) { welcome.attachedSheet == nil && !panel.isVisible }
        let after = (app.terminalPosition, app.sidebarSide, app.terminalTabs, app.showsWindowColumn, app.windowColumnOnRight)
        check(closed && sheet.chosen == nil && before == after, "layout picker: Escape skips, changing nothing", "closed \(closed)")
        app.welcomeController?.close()

        // Each card's own action, over a project window with a file open and a second window, so the column shows.
        c.openFile(file)
        second = app.openWindow(directory: NSTemporaryDirectory(), project: nil)
        if let tab = second?.activeTab { _ = await wait(20) { tab.status.integrated } }
        app.windowColumns.rebuild()
        guard let window = c.window, await bringToFront(window) else { return check(false, "layout picker: a project window in front") }
        for preset in LayoutPreset.allCases {
            guard let sheet = LayoutPickerSheet.present(over: window), let card = sheet.cards.first(where: { $0.preset == preset }),
                  let action = card.action else { return check(false, "layout picker: the sheet opens over a project window") }
            _ = await wait(3) { window.attachedSheet === sheet.window }
            NSApp.sendAction(action, to: card.target, from: card)
            let gone: Bool = await wait(3) { window.attachedSheet == nil }
            let want = preset.change
            let got = MCPLayoutChange(terminalPosition: app.terminalPosition.rawValue, sidebarSide: app.sidebarSide.rawValue,
                                      terminalTabs: app.terminalTabs.rawValue, windowColumnShown: app.showsWindowColumn,
                                      windowColumnSide: app.windowColumnOnRight ? "right" : "left")
            check(gone && sheet.chosen == preset && got == want, "layout picker: \(preset.name) sets its layout in every window and closes the sheet",
                  "closed \(gone), \(got)")
            window.layoutIfNeeded()
            c.refresh()
            await screenshot(c, suffix: "-layout-\(preset.rawValue)")
            note("layout picker, \(preset.name): the column \(c.columnHost.shown.form) in its window")
        }
    }
}
#endif
