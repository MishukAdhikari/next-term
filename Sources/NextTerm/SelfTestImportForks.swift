import AppKit
import NextTermCore

/// Editors built on VS Code in the import window: one found only by its product.json is listed under its own
/// name, a keymap extension in it offers the JetBrains set and notes the Vim keys, other extensions are a
/// count, its settings.json saying nothing of the click brings the app's own (a single click, which Apply sets and
/// Undo takes back), and with nothing found the window names the editors it looks for. The apps come from a made-up home
/// in a temp folder (the readers never look at yours); no key is typed, so these run whether or not the app
/// is in front. The detectors, the planner and the shortcut set are put back as they were.
extension SelfTest {
    static func importForkChecks() async {
        guard AppDelegate.shared != nil else { return note("import of editors built on VS Code: skipped, no app") }
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-import-forks-\(getpid())")
        let home = (root as NSString).appendingPathComponent("home")
        guard makeForkHome(home) else {
            try? FileManager.default.removeItem(atPath: root)
            return check(false, "import of editors built on VS Code: a made-up home to read", home)
        }
        let applications = [(home as NSString).appendingPathComponent("Applications")]
        let detectors = ImportSources.detectors
        let planner = ImportSources.planner
        let shortcuts = KeyboardShortcuts.shared
        let presetBefore = shortcuts.preset
        let window = ImportWindowController.shared
        defer {
            window.window?.close()
            ImportSources.detectors = detectors
            ImportSources.planner = planner
            shortcuts.preset = presetBefore
            try? FileManager.default.removeItem(atPath: root)
        }
        shortcuts.preset = .nextTerm
        ImportSources.detectors = [{ ImportVSCode.detect(home: home, applications: applications) }]
        ImportSources.planner = { app, usKeyboard in
            ImportVSCode.plan(for: app, home: home, usKeyboard: usKeyboard, applications: applications)
        }

        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        let chooser = importWindowTexts(window)
        check(chooser.contains { $0.hasPrefix(forkName) }, "the import window lists an editor found only by its product.json, by its own name",
              chooser.joined(separator: " | "))
        guard let found = ImportSources.detect().first(where: { $0.name == forkName }) else {
            return check(false, "the made-up editor is detected", ImportSources.detect().map(\.name).joined(separator: ", "))
        }
        check(found.kind == .vsCodeFork && found.version == "1.2.3" && found.appPath != nil,
              "it is detected with its app and version", "\(found.kind) \(found.version ?? "none")")

        window.showPreview(for: found)
        await pause(0.3)
        let preview = importWindowTexts(window)
        let all = preview.joined(separator: "\n")
        check(preview.contains { $0.hasPrefix("Use \(KeymapPreset.jetBrains.name) shortcuts") },
              "its IntelliJ keymap extension offers the JetBrains shortcuts", preview.prefix(6).joined(separator: " | "))
        check(all.contains("IntelliJ IDEA Keybindings extension") && all.contains("Vim keys (Vim extension): Next Term has no Vim mode yet"),
              "the preview says why: the keymap extension, and the Vim keys it can't bring", all)
        check(all.contains("1 other extension: extensions aren't imported") && !all.contains("prettier"),
              "other extensions are a count, never named", all)
        window.window?.close()
        await importForkClickChecks(found, home: home, applications: applications)

        ImportSources.detectors = []
        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        let none = importWindowTexts(window).joined(separator: "\n")
        check(none.contains(ImportSources.noneFound) && none.contains("VSCodium") && none.contains("VS Code Insiders"),
              "with nothing found, the window names the editors it looks for", none)
    }

    private static let forkName = "NT Self-Test Fork"

    /// Its settings.json is `{}`: with single clicks off, the preview offers the app's own click, Apply turns single
    /// clicks on and Undo puts them back off. The setting and the last import are put back as they were.
    private static func importForkClickChecks(_ found: DetectedApp, home: String, applications: [String]) async {
        guard let app = AppDelegate.shared else { return }
        let key = SidebarClick.settingKey
        let saved = UserDefaults.standard.object(forKey: key)
        let coordinator = ImportCoordinator.shared
        let lastBefore = coordinator.last
        let window = ImportWindowController.shared
        defer {
            window.window?.close()
            coordinator.last = lastBefore
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        app.sidebarSingleClickOpens = false
        window.showPreview(for: found)
        await pause(0.3)
        let texts = importWindowTexts(window)
        let title = "Open files and folders with a single click, files in a preview tab"
        let detail = "workbench.list.openMode (not set: singleClick) — \(forkName)'s default"
        check(texts.contains(title) && texts.contains(detail), "an editor built on VS Code whose settings say nothing of the click brings its own: a single click",
              texts.joined(separator: " | "))
        window.window?.close()
        let plan = ImportVSCode.plan(for: found, home: home, usKeyboard: true, applications: applications)
        let rows = plan.settings.filter { if case .sidebarSingleClick = $0.setting { return true } else { return false } }
        guard rows.count == 1 else { return check(false, "the editor's plan has one click row", "\(plan.settings.map(\.setting))") }
        coordinator.apply(ImportChoice(usePreset: false, settings: rows, recentProjects: []), plan: plan, from: forkName)
        check(app.sidebarSingleClickOpens, "Apply turns single clicks on")
        coordinator.undo()
        check(!app.sidebarSingleClickOpens && UserDefaults.standard.object(forKey: key) as? Bool == false, "and Undo Import turns them back off",
              String(describing: UserDefaults.standard.object(forKey: key)))
    }

    /// A home with one made-up editor built on VS Code: its app (product.json only), its settings folder and
    /// its extensions list (the IntelliJ keys, Vim, one other).
    private static func makeForkHome(_ home: String) -> Bool {
        let bundle = (home as NSString).appendingPathComponent("Applications/Forky Self-Test.app/Contents/Resources/app")
        let user = (home as NSString).appendingPathComponent("Library/Application Support/\(forkName)/User")
        let extensions = (home as NSString).appendingPathComponent(".nt-selftest-fork/extensions")
        let product = #"{"nameShort": "NT Self-Test Fork", "dataFolderName": ".nt-selftest-fork", "version": "1.2.3"}"#
        let list = #"[{"identifier": {"id": "k--kato.intellij-idea-keybindings"}}, {"identifier": {"id": "vscodevim.vim"}}, "#
            + #"{"identifier": {"id": "esbenp.prettier-vscode"}}]"#
        do {
            for folder in [bundle, user, extensions] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try product.write(toFile: (bundle as NSString).appendingPathComponent("product.json"), atomically: true, encoding: .utf8)
            try "{}".write(toFile: (user as NSString).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            try list.write(toFile: (extensions as NSString).appendingPathComponent("extensions.json"), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Every label's text and every button's title in the import window, top to bottom as laid out.
    static func importWindowTexts(_ window: ImportWindowController) -> [String] {
        func texts(in view: NSView) -> [String] {
            var found: [String] = []
            if let button = view as? NSButton {
                found.append(button.title)
            } else if let field = view as? NSTextField {
                found.append(field.stringValue)
            }
            for subview in view.subviews { found += texts(in: subview) }
            return found
        }
        guard let content = window.window?.contentView else { return [] }
        return texts(in: content)
    }
}
