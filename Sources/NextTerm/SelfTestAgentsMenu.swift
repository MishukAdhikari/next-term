import AppKit
import NextTermCore

/// The Agents menu: where it sits, what it lists, Skills… opening Settings › Skills with the count of skill updates, and
/// the commands that moved there from File and Edit keeping their keys, actions and the keys you saved for them.
extension SelfTest {
    static func agentsMenuChecks(_ c: TerminalWindowController) async {
        let shortcuts = KeyboardShortcuts.shared
        // The menus' own keys while these run, and yours back after (as saved: absent stays absent).
        let savedBindings = UserDefaults.standard.data(forKey: "keyBindings")
        let savedUpdates = SkillsInstaller.updates
        defer {
            SkillsInstaller.updates = savedUpdates
            UserDefaults.standard.set(savedBindings, forKey: "keyBindings")
            shortcuts.apply()
        }
        shortcuts.bindings = KeyBindings()
        shortcuts.apply()
        SkillsInstaller.updates = [:]

        let bar = NSApp.mainMenu?.items ?? []
        check(bar.dropFirst().map(\.title) == ["File", "Edit", "View", "Agents", "Git", "Window"], "agents menu: it sits between View and Git",
              bar.map(\.title).joined(separator: ", "))
        guard let agents = bar.first(where: { $0.title == "Agents" })?.submenu else { return check(false, "agents menu: the menu bar has it") }
        let listed = agents.items.map { $0.isSeparatorItem ? "—" : $0.title }
        check(listed == ["Skills…", "—", "Resume Agent Session…", "Send to Agent", "Suggest a Command…"],
              "agents menu: Skills…, then the agents' commands", listed.joined(separator: ", "))
        func titles(_ name: String) -> [String] { bar.first { $0.title == name }?.submenu?.items.map(\.title) ?? [] }
        let left = titles("File").filter { ["Resume Agent Session…", "Suggest a Command…"].contains($0) } + titles("Edit").filter { $0 == "Send to Agent" }
        check(left.isEmpty, "agents menu: the commands are no longer in File or Edit", left.joined(separator: ", "))
        let finder = (bar.first { $0.title == "Window" }?.submenu?.items ?? []).first { $0.action == #selector(AppDelegate.showSkills(_:)) }
        check(finder?.title == "Skills", "agents menu: Window › Skills, to find skills, stays where it was", finder?.title ?? "missing")

        // Each moved command keeps its action, target and key (its menu default, laid on as Settings has it now), and
        // Settings › Keyboard Shortcuts lists it under Agents.
        let moved: [(id: String, action: Selector, chord: KeyChord, target: AnyObject?)] = [
            ("resumeSession:", #selector(TerminalWindowController.resumeSession(_:)), KeyChord(key: "o", command: true, option: true), nil),
            ("sendToAgent:", #selector(TerminalWindowController.sendToAgent(_:)), KeyChord(key: "k", command: true, option: true), nil),
            ("suggestCommand:", #selector(CommandSuggestionController.suggestCommand(_:)), KeyChord(key: "k", command: true, control: true),
             CommandSuggestionController.shared),
        ]
        var wrong: [String] = []
        for entry in moved {
            let item = agents.items.first { $0.action == entry.action }
            let command = shortcuts.commands.first { $0.id == entry.id }
            let keyed = item.flatMap(KeyboardShortcuts.chord(of:)) == shortcuts.chord(for: entry.id) && item?.target === entry.target
            let listedRight = command?.path == "Agents" && command?.item === item && command?.defaultChord == entry.chord
            if !keyed || !listedRight { wrong.append("\(entry.id) \(item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "no key") in \(command?.path ?? "nowhere")") }
        }
        let skillsCommand = shortcuts.commands.first { $0.id == "showSkillsSettings:" }
        if skillsCommand?.path != "Agents" || skillsCommand?.defaultChord != nil { wrong.append("Skills… \(skillsCommand?.path ?? "not listed")") }
        check(wrong.isEmpty, "agents menu: the moved commands keep their actions and keys, and Settings lists them under Agents",
              wrong.joined(separator: "; "))

        await skillsItemChecks(agents)
        await savedKeyChecks(c, agents)
    }

    /// Skills… opens Settings › Skills, and shows how many skills have an update: none, then two, then one, then none.
    private static func skillsItemChecks(_ agents: NSMenu) async {
        guard let index = agents.items.firstIndex(where: { $0.action == #selector(AppDelegate.showSkillsSettings(_:)) }) else {
            return check(false, "agents menu: Skills… is there")
        }
        let item = agents.items[index]
        func shown() -> String {
            if #available(macOS 14.0, *) {
                let badge = item.badge.map { "badge \($0.itemCount) \($0.type == .updates ? "updates" : "other") “\($0.stringValue ?? "")”" } ?? "no badge"
                return "\(item.title), \(badge), VoiceOver: \(item.accessibilityTitle() ?? "nothing")"
            }
            return item.title
        }
        func shows(_ count: Int) -> Bool {
            if #available(macOS 14.0, *) {
                guard count > 0 else { return item.title == "Skills…" && item.badge == nil }
                // The badge's words are the system's (localised); VoiceOver hears them with the title.
                guard let badge = item.badge, badge.itemCount == count, badge.type == .updates, let words = badge.stringValue else { return false }
                return item.title == "Skills…" && item.accessibilityTitle()?.contains(words) == true
            }
            return item.title == SkillUpdates.title("Skills…", count: count)
        }
        check(await wait(2) { shows(0) }, "agents menu: Skills… shows no count before a check has answered", shown())
        let kept = UserDefaults.standard.data(forKey: SkillsUpdateCheck.answersKey)
        SkillsInstaller.updates = ["release-notes": .available(commit: "a1"), "tidy-prose": .available(commit: "b2"), "pdf": .current,
                                   "gone": .unknown("Its folder is no longer in example/skills.")]
        check(await wait(2) { shows(2) }, "agents menu: two skills with an update show 2 on Skills…, read by VoiceOver", shown())
        SkillsInstaller.updates["tidy-prose"] = .current // updated in Settings › Skills
        check(await wait(2) { shows(1) }, "agents menu: the count follows an update", shown())
        SkillsInstaller.updates["release-notes"] = nil // removed
        check(await wait(2) { shows(0) }, "agents menu: and no count with none", shown())
        check(!SkillsUpdateCheck.started && UserDefaults.standard.data(forKey: SkillsUpdateCheck.answersKey) == kept,
              "agents menu: the self-test never checks GitHub for skill updates, nor keeps its made-up answers")

        // Opening Settings › Skills, on a home of its own: your skill folders are never read here.
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-agents-menu-\(getpid())").path
        let savedHome = SkillsStore.home
        SkillsStore.home = home
        defer {
            SkillsStore.home = savedHome
            try? FileManager.default.removeItem(atPath: home)
        }
        func settings() -> SettingsWindowController? { NSApp.windows.compactMap { $0.windowController as? SettingsWindowController }.first }
        func selectedTab() -> String? { ((settings()?.window?.contentView as? NSTabView)?.selectedTabViewItem?.identifier as? String) }
        let wasOpen = settings()?.window?.isVisible == true
        let previousTab = selectedTab() ?? "general"
        agents.performActionForItem(at: index)
        let opened = await wait(3) { settings()?.window?.isVisible == true && selectedTab() == "skills" }
        check(opened, "agents menu: Skills… opens Settings on its Skills tab", "\(String(describing: settings()?.window?.isVisible)) \(selectedTab() ?? "no tab")")
        // As it was: the tab it was on, and closed unless it was open.
        settings()?.showTab(previousTab)
        if !wasOpen { settings()?.window?.close() }

        // A skill removed outside Next Term (`npx skills remove pdf` in a tab) leaves the count: only release-notes is
        // still in this home's lock file.
        let lock = SkillLock.path(home: home, environment: [:])
        try? FileManager.default.createDirectory(atPath: (lock as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let lockText = "{\n  \"version\": 3,\n  \"skills\": {\n    \"release-notes\": { \"source\": \"example-org/skills\", "
            + "\"skillPath\": \"release-notes/SKILL.md\", \"skillFolderHash\": \"abc\" }\n  }\n}\n"
        try? lockText.write(toFile: lock, atomically: true, encoding: .utf8)
        SkillsInstaller.updates = ["release-notes": .available(commit: "a1"), "pdf": .available(commit: "b2")]
        SkillsUpdateCheck.prune(to: await SkillsInstaller.tracked())
        let left = SkillsInstaller.updates.keys.sorted()
        check(left == ["release-notes"] && UserDefaults.standard.data(forKey: SkillsUpdateCheck.answersKey) == kept,
              "agents menu: a skill removed outside Next Term leaves Skills…' count", left.joined(separator: ", "))
        check(await wait(2) { shows(1) }, "agents menu: and the count says so", shown())
    }

    /// A key you saved for a moved command (saved by its action, as before it moved) is still its key, in the menu and in
    /// Settings, and pressing it does the command; the default comes back with Default.
    private static func savedKeyChecks(_ c: TerminalWindowController, _ agents: NSMenu) async {
        let shortcuts = KeyboardShortcuts.shared
        let mine = KeyChord(key: "j", command: true, option: true)
        let taken = shortcuts.commands.filter { $0.id != "resumeSession:" && shortcuts.chord(for: $0.id) == mine }.map(\.id)
        guard taken.isEmpty else { return note("agents menu: a saved key skipped, ⌥⌘J is \(taken.joined(separator: ", "))'s here") }
        // What an earlier Next Term saved: Resume Agent Session… on ⌥⌘J, Suggest a Command… with no key.
        var saved = KeyBindings()
        saved.set(mine, for: "resumeSession:", default: shortcuts.baseChord(for: "resumeSession:"))
        saved.set(nil, for: "suggestCommand:", default: shortcuts.baseChord(for: "suggestCommand:"))
        shortcuts.bindings = saved
        shortcuts.apply() // as a launch lays the saved keys over the menus
        func key(_ action: Selector) -> String {
            agents.items.first { $0.action == action }.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        }
        let keys = [key(#selector(TerminalWindowController.resumeSession(_:))), key(#selector(CommandSuggestionController.suggestCommand(_:))),
                    shortcuts.chord(for: "resumeSession:")?.display ?? "none", shortcuts.isCustomised("suggestCommand:") ? "customised" : "default"]
        check(keys == ["⌥⌘J", "none", "⌥⌘J", "customised"], "agents menu: keys saved for the moved commands are still theirs, in the menu and in Settings",
              keys.joined(separator: " "))

        // Pressed as the keyboard sends it, in a tab of its own at a prompt.
        let tab = c.addTab(directory: NSTemporaryDirectory())
        _ = await wait(20) { tab.status.integrated }
        if await focus(c, tab, for: "agents menu: a saved key pressed"), let window = c.window {
            let panel = c.sessionsPanel
            if panel.isVisible { panel.close() }
            pressAppKey(window, "o", code: 31, flags: [.command, .option])
            let byOldKey = await wait(1) { panel.isVisible }
            if byOldKey { panel.close() }
            pressAppKey(window, "j", code: 38, flags: [.command, .option])
            let byNewKey = await wait(3) { panel.isVisible }
            check(!byOldKey && byNewKey, "agents menu: the saved key opens Resume Agent Session…, and its old key doesn't", "old \(byOldKey), new \(byNewKey)")
            panel.close()
        }
        c.remove(tab)

        shortcuts.reset("resumeSession:")
        let back = key(#selector(TerminalWindowController.resumeSession(_:)))
        check(back == shortcuts.baseChord(for: "resumeSession:")?.display && back == "⌥⌘O", "agents menu: Default puts ⌥⌘O back on Resume Agent Session…", back)
    }
}
