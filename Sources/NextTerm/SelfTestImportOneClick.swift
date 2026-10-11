import AppKit
import NextTermCore

/// One click: each app on the import window's chooser has an Import button, which brings over exactly what its preview
/// ticks at first (the rows MCPImport.defaultTicks names, as an agent's preview starts), then says what came over, with
/// Undo Import, which puts it all back. An app with nothing new says so and changes nothing. The app is made up (the
/// detectors and planner are swapped, so nothing on this Mac is read) and the clicks are the buttons' own, so these run
/// whether or not the app is in front. Every setting, the shortcut set and the last import are put back.
extension SelfTest {
    static func importOneClickChecks() async {
        guard let app = AppDelegate.shared else { return note("one-click import: skipped, no app") }
        let window = ImportWindowController.shared
        let coordinator = ImportCoordinator.shared
        let defaults = UserDefaults.standard
        let saved = (detectors: ImportSources.detectors, planner: ImportSources.planner, last: coordinator.last,
                     size: app.fontSize, wrap: app.softWrap, blink: defaults.object(forKey: "terminalCursorBlink"),
                     preset: KeyboardShortcuts.shared.preset, bindings: defaults.data(forKey: "keyBindings"))
        defer {
            window.window?.close()
            ImportSources.detectors = saved.detectors
            ImportSources.planner = saved.planner
            app.setFontSize(saved.size)
            app.applyImported(.softWrap(saved.wrap))
            if let blink = saved.blink as? Bool { app.setTerminalCursor(blinks: blink) } else {
                defaults.removeObject(forKey: "terminalCursorBlink")
                app.setTerminalCursor()
            }
            if let bindings = saved.bindings { defaults.set(bindings, forKey: "keyBindings") } else { defaults.removeObject(forKey: "keyBindings") }
            KeyboardShortcuts.shared.preset = saved.preset
            coordinator.last = saved.last
        }
        KeyboardShortcuts.shared.preset = .nextTerm
        coordinator.last = nil

        // A made-up editor: two settings that differ from Next Term's now (one ticked, one not), and the VS Code set.
        let editor = DetectedApp(kind: .vsCodeFork, name: "NT One-Click Editor", configPath: "/nonexistent/nt-one-click/User",
                                 lastUsed: Date().addingTimeInterval(-3600), appPath: "/nonexistent/NT One-Click Editor.app", version: "2.0.1")
        let size = Double((saved.size >= 30 ? saved.size - 2 : saved.size + 2).rounded())
        let blinks = Preferences.terminalCursorBlinks
        let plan = ImportPlan(preset: .vsCode, settings: [
            PlannedSetting(.fontSize(size), source: "editor.fontSize \(Int(size))"),
            PlannedSetting(.terminalCursorBlink(!blinks), source: "terminal.integrated.cursorBlinking", ticked: false),
        ], skipped: [SkippedItem("terminal.integrated.env.osx", "never imported: can hold secrets")])
        ImportSources.detectors = [{ [editor] }]
        ImportSources.planner = { _, _ in plan }

        // The preview starts from the same rows one click applies.
        window.showPreview(for: editor)
        await pause(0.2)
        let previewTicks = window.tickedIDs
        let (recommendedPlan, choice) = ImportWindowController.recommended(plan)
        let defaultTicks = MCPImport.defaultTicks(recommendedPlan, currentPreset: .nextTerm, newRecents: [])
        check(previewTicks == defaultTicks && choice.usePreset && choice.settings.count == 1 && choice.settings.first?.ticked == true,
              "one-click import: Import brings over exactly what the preview ticks at first",
              "preview \(previewTicks.sorted()) against \(defaultTicks.sorted()), preset \(choice.usePreset), settings \(choice.settings.count)")
        window.window?.close()

        // The chooser: an Import button at the end of the app's row.
        window.showChooser(firstRun: true, completion: nil)
        await pause(0.2)
        let buttons = window.importButtons
        check(buttons.count == 1 && buttons.first?.accessibilityLabel() == "Import from NT One-Click Editor",
              "one-click import: each app on the chooser has an Import button, named for the app", "\(buttons.map { $0.accessibilityLabel() ?? "" })")
        guard let button = buttons.first else { return }

        // One click: the ticked setting and the shortcut set change, the unticked one doesn't, and the window says so.
        button.performClick(nil)
        await pause(0.2)
        let texts = importWindowTexts(window)
        check(app.fontSize == CGFloat(size) && KeyboardShortcuts.shared.preset == .vsCode && Preferences.terminalCursorBlinks == blinks
              && coordinator.last?.source == "NT One-Click Editor",
              "one-click import: one click on Import applies the recommended rows, and only those",
              "size \(app.fontSize), preset \(KeyboardShortcuts.shared.preset.name), blink \(Preferences.terminalCursorBlinks)")
        check(texts.first == "Brought over from NT One-Click Editor" && texts.contains { $0.hasPrefix("VS Code shortcuts, 1 setting") }
              && texts.contains { $0.hasPrefix("1 thing wasn’t brought over") } && window.undoImportedButton?.isHidden == false,
              "one-click import: the window says what came over and what didn't, with Undo Import", texts.joined(separator: " | "))

        // Undo Import there puts it all back and closes the window.
        window.undoImportedButton?.performClick(nil)
        await pause(0.2)
        check(app.fontSize == saved.size && KeyboardShortcuts.shared.preset == .nextTerm && window.window?.isVisible != true,
              "one-click import: Undo Import puts it all back", "size \(app.fontSize), preset \(KeyboardShortcuts.shared.preset.name)")

        // Nothing new: the window says so, and nothing changes, not even the last import's Undo.
        app.setFontSize(CGFloat(size))
        KeyboardShortcuts.shared.preset = .vsCode
        coordinator.last = nil
        window.showChooser(firstRun: false, completion: nil)
        await pause(0.2)
        window.importButtons.first?.performClick(nil)
        await pause(0.2)
        let nothing = importWindowTexts(window)
        check(nothing.first == "Nothing to bring over from NT One-Click Editor" && coordinator.last == nil
              && window.undoImportedButton?.isHidden == true,
              "one-click import: with nothing new, it says so and changes nothing", nothing.joined(separator: " | "))
    }
}
