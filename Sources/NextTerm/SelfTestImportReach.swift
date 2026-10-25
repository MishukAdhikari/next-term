import AppKit
import NextTermCore

/// What wave 1 of the importer brings to the app: the settings no import reached before land the way Settings
/// sets them and Undo Import puts them back; under the JetBrains set ⌘K is Commit… outside a terminal and Clear
/// Buffer in one, and ⇧⌘K is Push…; and the import window lists IDEs not used lately last, under their own
/// heading. The apps come from a made-up home in a temp folder (the readers never look at yours). No key is typed
/// (a key press is only built, never sent), so these run whether or not the app is in front. The settings, the
/// last import, the shortcut set and the detectors are put back as they were.
extension SelfTest {
    static func importReachChecks() async {
        guard let app = AppDelegate.shared else { return note("import of the new settings: skipped, no app") }
        await importedWindowSettingsChecks(app)
        importJetBrainsKeysChecks()
        await importNotUsedLatelyChecks()
        importJetBrainsClickChecks(app)
    }

    /// An IDE that never changed how its Project view opens files opens them on a double-click: with single clicks
    /// on, its import turns them off, and Undo Import puts them back on. The setting and the last import are put
    /// back as they were.
    private static func importJetBrainsClickChecks(_ app: AppDelegate) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-import-click-\(getpid())")
        let home = (root as NSString).appendingPathComponent("home")
        let options = (home as NSString).appendingPathComponent("Library/Application Support/JetBrains/GoLand2026.1/options")
        let key = SidebarClick.settingKey
        let saved = UserDefaults.standard.object(forKey: key)
        let coordinator = ImportCoordinator.shared
        let lastBefore = coordinator.last
        defer {
            coordinator.last = lastBefore
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            try? FileManager.default.removeItem(atPath: root)
        }
        do {
            try FileManager.default.createDirectory(atPath: options, withIntermediateDirectories: true)
            try "<application />".write(toFile: (options as NSString).appendingPathComponent("ide.general.xml"), atomically: true, encoding: .utf8)
        } catch {
            return check(false, "import of an IDE's click: a made-up home to read", "\(error)")
        }
        guard let ide = ImportJetBrains.detect(home: home, applications: []).first else {
            return check(false, "import of an IDE's click: the made-up IDE is detected")
        }
        app.sidebarSingleClickOpens = true
        let plan = ImportJetBrains.plan(for: ide, home: home, applications: [])
        let rows = plan.settings.filter { if case .sidebarSingleClick = $0.setting { return true } else { return false } }
        check(rows.map(\.setting) == [.sidebarSingleClick(false)] && rows.first?.note == "JetBrains IDEs' default"
              && ImportWindowController.describe(.sidebarSingleClick(false)) == "Open files and folders with a double click",
              "a JetBrains IDE with no projectView.xml brings its own click: a double click", "\(plan.settings.map(\.setting))")
        coordinator.apply(ImportChoice(usePreset: false, settings: rows, recentProjects: []), plan: plan, from: ide.name)
        check(!app.sidebarSingleClickOpens, "Apply turns single clicks off")
        coordinator.undo()
        check(app.sidebarSingleClickOpens, "and Undo Import turns them back on")
    }

    /// Each new setting applied by an import, then Undo.
    private static func importedWindowSettingsChecks(_ app: AppDelegate) async {
        let coordinator = ImportCoordinator.shared
        let lastBefore = coordinator.last
        defer { coordinator.last = lastBefore }
        let keys = ["sidebarSingleClickOpens", "backgroundFetch", "diffLayout", "currentLineBlame", "openProjectsIn", LaunchSettings.Key.opens]
        let before = ImportSnapshot.values(of: keys, in: .standard)
        // Each the other way from what it is now, so every one is a change.
        let fetch = BackgroundFetcher.shared.frequency == .fiveMinutes ? FetchFrequency.thirtyMinutes : .fiveMinutes
        let layout = DiffLayout.current == .unified ? "sideBySide" : "unified"
        let target = app.projectTarget == .newWindow ? "thisWindow" : "newWindow"
        let opens = LaunchSettings(defaults: .standard).opens == .welcome ? LaunchOpens.lastProjects : .welcome
        let settings: [ImportedSetting] = [
            .sidebarSingleClick(!app.sidebarSingleClickOpens), .backgroundFetch(fetch.rawValue), .diffLayout(layout),
            .currentLineBlame(!app.currentLineBlame), .openProjectsIn(target), .launchOpens(opens.rawValue),
        ]
        let rows = settings.map { PlannedSetting($0, source: "self-test") }
        let described = settings.map { ImportWindowController.describe($0) }
        check(described.allSatisfy { !$0.isEmpty }, "the preview names each new setting", described.joined(separator: " | "))
        let plan = ImportPlan(preset: .nextTerm, settings: rows)
        let snapshot = coordinator.apply(ImportChoice(usePreset: false, settings: rows, recentProjects: []), plan: plan, from: "Self-test editor")
        let applied = BackgroundFetcher.shared.frequency == fetch && DiffLayout.current.rawValue == layout
            && app.projectTarget.rawValue == target && LaunchSettings(defaults: .standard).opens == opens
        check(applied && snapshot?.touched.count == keys.count,
              "an import sets how files and projects open, what reopens at launch, diffs and git",
              "\(BackgroundFetcher.shared.frequency) \(DiffLayout.current) \(app.projectTarget) \(String(describing: snapshot?.touched))")
        let changed = coordinator.changedSinceImport()
        check(changed.isEmpty, "nothing is named as changed since that import", changed.joined(separator: ", "))
        coordinator.undo()
        let after = ImportSnapshot.values(of: keys, in: .standard)
        check(keys.allSatisfy { ImportSnapshot.same($0, before[$0], after[$0]) }, "Undo Import puts each of them back exactly",
              keys.filter { !ImportSnapshot.same($0, before[$0], after[$0]) }.joined(separator: ", "))
    }

    /// The JetBrains set's ⌘K and ⇧⌘K: on the menus, and the terminal's own ⌘K.
    private static func importJetBrainsKeysChecks() {
        let shortcuts = KeyboardShortcuts.shared
        let presetBefore = shortcuts.preset
        defer { shortcuts.preset = presetBefore }
        func item(_ id: String) -> NSMenuItem? { shortcuts.commands.first { $0.id == id }?.item }
        shortcuts.preset = .jetBrains
        let commit = item("gitCommit:"), push = item("gitPush:"), clear = item("clearBuffer:")
        check(commit?.keyEquivalent == "k" && commit?.keyEquivalentModifierMask == .command
              && push?.keyEquivalent == "k" && push?.keyEquivalentModifierMask == [.command, .shift],
              "JetBrains keys: Commit… ⌘K and Push… ⇧⌘K", "\(commit?.keyEquivalent ?? "nil") \(push?.keyEquivalent ?? "nil")")
        check(clear?.keyEquivalent == "", "and Clear Buffer's ⌘K is kept off the menus, for the terminal to answer",
              clear?.keyEquivalent ?? "nil")
        let commandK = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                        context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
        check(commandK.flatMap(shortcuts.terminalItem(for:)) === clear && clear != nil, "a terminal with the keyboard clears on ⌘K")
        check(shortcuts.sharing("gitCommit:") == "⌘K is Clear Buffer while a terminal has the keyboard, Commit… everywhere else",
              "Settings says where ⌘K is which", shortcuts.sharing("gitCommit:") ?? "nil")
        // Commit… is back on its own key in Next Term's set (⇧⌘C), off ⌘K.
        shortcuts.preset = .nextTerm
        let commitKey = item("gitCommit:").flatMap(KeyboardShortcuts.chord(of:))
        check(item("clearBuffer:")?.keyEquivalent == "k" && commitKey == shortcuts.baseChord(for: "gitCommit:")
              && commandK.flatMap(shortcuts.terminalItem(for:)) == nil,
              "with Next Term's keys, ⌘K is Clear Buffer's everywhere again", "Commit… \(commitKey?.display ?? "none")")
    }

    /// An IDE unused for 180 days is listed, last, under "Not used lately".
    private static func importNotUsedLatelyChecks() async {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-import-stale-\(getpid())")
        let home = (root as NSString).appendingPathComponent("home")
        let support = (home as NSString).appendingPathComponent("Library/Application Support/JetBrains")
        let detectors = ImportSources.detectors
        let window = ImportWindowController.shared
        defer {
            window.window?.close()
            ImportSources.detectors = detectors
            try? FileManager.default.removeItem(atPath: root)
        }
        do {
            for (name, days) in [("GoLand2026.1", 1.0), ("WebStorm2024.2", 300.0)] {
                let options = (support as NSString).appendingPathComponent("\(name)/options")
                try FileManager.default.createDirectory(atPath: options, withIntermediateDirectories: true)
                let file = (options as NSString).appendingPathComponent("ide.general.xml")
                try "<application />".write(toFile: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: file)
            }
        } catch {
            return check(false, "import of IDEs not used lately: a made-up home to read", "\(error)")
        }
        ImportSources.detectors = [{ ImportJetBrains.detect(home: home, applications: []) }]
        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        let texts = importWindowTexts(window)
        let heading = texts.firstIndex { $0.hasPrefix("NOT USED LATELY") }, stale = texts.firstIndex { $0.hasPrefix("WebStorm 2024.2") }
        let fresh = texts.firstIndex { $0.hasPrefix("GoLand 2026.1") }
        check(heading != nil && stale != nil && fresh != nil && fresh! < heading! && heading! < stale!,
              "an IDE not used lately is listed last, folded under Not used lately, not left out", texts.joined(separator: " | "))
    }
}
