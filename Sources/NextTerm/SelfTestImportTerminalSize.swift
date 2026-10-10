import AppKit
import NextTermCore

/// The terminal's own font size: none saved, terminals follow the editor's size as they always did; an import or
/// Settings › Terminal gives them one of their own, which the editor's size then leaves alone, and Undo Import
/// or "Same as the editor" makes them follow again. ⌘+ in a terminal with a size of its own changes that size
/// only, which needs the app in front (skipped with a note without it). The sizes, the last import and the
/// first responder are put back as they were.
extension SelfTest {
    static func importTerminalSizeChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared, let tab = c.tabs.first else { return note("terminal font size: skipped, no window") }
        let coordinator = ImportCoordinator.shared
        let lastBefore = coordinator.last
        let editorBefore = app.fontSize, ownBefore = app.terminalOwnFontSize
        defer {
            app.setFontSize(editorBefore)
            app.setTerminalFontSize(ownBefore)
            coordinator.last = lastBefore
        }
        func shown() -> CGFloat { tab.view.font.pointSize }

        // Nothing saved: terminals follow the editor's size, as before the setting existed.
        app.setTerminalFontSize(nil)
        app.setFontSize(14)
        check(app.terminalOwnFontSize == nil && app.terminalFontSize == 14 && shown() == 14
              && UserDefaults.standard.object(forKey: "terminalFontSize") == nil,
              "with no size of its own, the terminal follows the editor's and nothing is saved for it", "\(shown())")

        // An import with both sizes sets each.
        let rows = [PlannedSetting(.fontSize(clamping: 15), source: "editor.fontSize 15"),
                    PlannedSetting(.terminalFontSize(clamping: 12), source: "terminal.integrated.fontSize 12")]
        let plan = ImportPlan(preset: .nextTerm, settings: rows)
        let snapshot = coordinator.apply(ImportChoice(usePreset: false, settings: rows, recentProjects: []), plan: plan, from: "Self-test editor")
        check(app.fontSize == 15 && app.terminalOwnFontSize == 12 && shown() == 12 && snapshot?.touched == ["fontSize", "terminalFontSize"],
              "an import sets the editor's size and the terminal's own apart",
              "editor \(app.fontSize), terminal \(String(describing: app.terminalOwnFontSize)), shown \(shown())")
        app.setFontSize(16)
        check(shown() == 12, "the editor's size leaves a terminal with its own size alone", "\(shown())")
        coordinator.undo()
        check(app.terminalOwnFontSize == nil && app.fontSize == 14 && shown() == 14,
              "Undo Import takes the terminal's own size away, so it follows the editor's again",
              "editor \(app.fontSize), terminal \(String(describing: app.terminalOwnFontSize)), shown \(shown())")

        // Settings › Terminal: unticking Same as the editor keeps the size; stepping changes only the terminal's.
        let pane = TerminalSettingsView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        pane.refresh()
        check(pane.fontSizeTextForTest == "14 pt", "Settings › Terminal shows the editor's size while the terminal follows it", pane.fontSizeTextForTest)
        pane.setSameSizeForTest(false)
        check(app.terminalOwnFontSize == 14 && shown() == 14, "unticking Same as the editor keeps the size it had, as its own",
              String(describing: app.terminalOwnFontSize))
        pane.stepFontSizeForTest(to: 11)
        check(app.terminalOwnFontSize == 11 && app.fontSize == 14 && shown() == 11 && pane.fontSizeTextForTest == "11 pt",
              "the terminal's size step changes the terminal's only", "terminal \(shown()), editor \(app.fontSize)")

        // ⌘+ with a terminal's keyboard changes its own size; elsewhere, the editor's.
        if let window = c.window, await bringToFront(window) {
            let responder = window.firstResponder
            window.makeFirstResponder(tab.view)
            app.increaseFontSize(nil)
            check(app.terminalOwnFontSize == 12 && app.fontSize == 14, "⌘+ in a terminal with a size of its own changes that size",
                  "terminal \(String(describing: app.terminalOwnFontSize)), editor \(app.fontSize)")
            window.makeFirstResponder(nil)
            app.increaseFontSize(nil)
            check(app.terminalOwnFontSize == 12 && app.fontSize == 15, "⌘+ elsewhere changes the editor's size",
                  "terminal \(String(describing: app.terminalOwnFontSize)), editor \(app.fontSize)")
            window.makeFirstResponder(responder)
        } else {
            note("terminal font size: ⌘+ in a terminal skipped, the app is not in front")
        }
        pane.setSameSizeForTest(true)
        check(app.terminalOwnFontSize == nil && shown() == app.fontSize && UserDefaults.standard.object(forKey: "terminalFontSize") == nil,
              "ticking Same as the editor removes the terminal's own size", "\(shown()) vs \(app.fontSize)")
    }
}
