import AppKit
import NextTermCore

/// Undo Import's guards in the app: a second Apply that changes nothing keeps the first import's Undo, and
/// the Undo alert names a value changed by hand since the import before it puts it back. No window is shown
/// and no key is typed, so these run whether or not the app is in front; the user's settings and their last
/// import are put back as they were.
extension SelfTest {
    static func importUndoGuardChecks() async {
        guard let app = AppDelegate.shared else { return note("import Undo guards: skipped, no app") }
        let coordinator = ImportCoordinator.shared
        let lastBefore = coordinator.last
        let sizeBefore = app.fontSize
        defer {
            app.setFontSize(sizeBefore)
            coordinator.last = lastBefore
        }
        let size = (sizeBefore >= 30 ? sizeBefore - 2 : sizeBefore + 2).rounded()
        let row = PlannedSetting(.fontSize(clamping: Double(size)), source: "editor.fontSize \(Int(size))")
        let plan = ImportPlan(preset: .nextTerm, settings: [row])
        let choice = ImportChoice(usePreset: false, settings: [row], recentProjects: [])
        let first = coordinator.apply(choice, plan: plan, from: "Self-test editor")
        check(first != nil && coordinator.last?.id == first?.id && coordinator.last?.touched == ["fontSize"]
              && coordinator.last?.after?["fontSize"] == .double(Double(size)),
              "an import that changes the font size is remembered for Undo, with the value it set",
              "\(String(describing: coordinator.last?.touched)) \(String(describing: coordinator.last?.after))")
        let again = coordinator.apply(choice, plan: plan, from: "Another self-test editor")
        check(again == nil && coordinator.last?.id == first?.id && coordinator.last?.source == "Self-test editor",
              "an Apply that changes nothing keeps the earlier import's Undo", coordinator.last?.source ?? "none")
        check(coordinator.changedSinceImport().isEmpty, "nothing is named as changed since the import while nothing was",
              coordinator.changedSinceImport().joined(separator: ", "))
        app.setFontSize(size + 1)
        let changed = coordinator.changedSinceImport()
        let message = ImportCoordinator.undoMessage(changedSince: changed)
        check(changed == ["Font size"] && message.contains("You changed this since the import") && message.hasSuffix("Font size."),
              "the Undo alert names the font size changed by hand since the import", message)
        coordinator.undo()
        check(app.fontSize == sizeBefore && coordinator.last == nil, "Undo Import puts it back all the same",
              "\(app.fontSize) vs \(sizeBefore)")
        importUndoRecentsChecks(app: app, coordinator: coordinator)
    }

    /// Recent projects: a project opened after the import is not "changed since", and Undo takes back only the
    /// folders the import added, keeping it.
    static func importUndoRecentsChecks(app: AppDelegate, coordinator: ImportCoordinator) {
        let saved = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        let base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-selftest-recents-" + String(UUID().uuidString.prefix(8))
        let imported = base + "/imported", opened = base + "/opened"
        for folder in [imported, opened] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        defer {
            app.setRecentProjects(saved)
            try? FileManager.default.removeItem(atPath: base)
        }
        app.setRecentProjects(Array(saved.prefix(3))) // room for the imported one
        let kept = Array(saved.prefix(3))
        let choice = ImportChoice(usePreset: false, settings: [], recentProjects: [imported])
        let snapshot = coordinator.apply(choice, plan: ImportPlan(preset: .nextTerm), from: "Self-test editor")
        // As opening a project does: it goes first.
        app.setRecentProjects([opened] + (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []))
        check(snapshot != nil && coordinator.changedSinceImport().isEmpty,
              "opening a project after an import is not named as a change since the import",
              coordinator.changedSinceImport().joined(separator: ", "))
        coordinator.undo()
        let now = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        check(now == [opened] + kept, "Undo Import takes back the imported project and keeps the one opened since",
              now.joined(separator: ", "))
    }
}
