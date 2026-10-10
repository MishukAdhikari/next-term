import Foundation

// "Coming from cmux?": cmux draws its terminals with Ghostty and reads Ghostty's config files, then its own Ghostty
// config in ~/Library/Application Support/com.cmuxterm.app, so those come over through the Ghostty reader (with
// cmux's bundled themes looked at first). Its own shortcuts are in ~/.config/cmux/cmux.json (`shortcuts.bindings`,
// format from cmux's docs and its config parser): only that object is read. cmux.json also holds actions, commands
// and hooks that run programs, which are never read. Nothing is written.

public enum ImportCmux {
    static func settingsFile(home: String) -> String { (home as NSString).appendingPathComponent(".config/cmux/cmux.json") }

    /// cmux's own Ghostty config folder (it writes the edits made in its Settings there).
    static func ghosttyFolder(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/com.cmuxterm.app")
    }

    /// cmux's own Ghostty config: `config.ghostty`, else the older `config`, whichever is not empty (as cmux reads it).
    static func ghosttyFile(home: String) -> String? {
        ["config.ghostty", "config"].map { (ghosttyFolder(home: home) as NSString).appendingPathComponent($0) }.first { path in
            isRegularFile(path) && ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0 > 0
        }
    }

    static let bundles = ["cmux.app"]

    /// cmux, when it has a cmux.json (it writes one at its first launch) or its own Ghostty config. Last use is the
    /// newer file's date.
    public static func detect(home: String = NSHomeDirectory(), applications: [String]? = nil) -> [DetectedApp] {
        let files = [settingsFile(home: home), ghosttyFile(home: home)].compactMap { $0 }.filter(isRegularFile)
        guard let first = files.first else { return [] }
        let apps = applications ?? ImportVSCode.applicationFolders(home: home)
        let bundle = ImportAppBundles.find(bundles, applications: apps)
        let used = files.compactMap(ImportFile.modificationDate).max()
        return [DetectedApp(kind: .cmux, name: "cmux", configPath: first, lastUsed: used, appPath: bundle?.path, version: bundle?.version)]
    }

    // MARK: plan

    /// The Ghostty settings cmux reads, then its own shortcuts. `applications`: where cmux.app and other apps with
    /// Ghostty's themes are looked for; `fonts`: the fonts this Mac has (tests pass their own of both).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system, applications: [String]? = nil) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .cmux else { return plan }
        let apps = applications ?? ImportVSCode.applicationFolders(home: home)
        // cmux's shortcuts come before Ghostty's keybinds: cmux handles a key before the terminal sees it.
        addShortcuts(home: home, usKeyboard: usKeyboard, to: &plan)
        let bundle = app.appPath ?? ImportAppBundles.find(bundles, applications: apps)?.path
        let files = ImportGhostty.configFiles(home: home) + [ghosttyFile(home: home)].compactMap { $0 }
        let folders = ImportGhostty.configFolders(home: home) + [ghosttyFolder(home: home)]
        let source = ImportGhostty.Source(files: files, folders: folders, bundles: [bundle].compactMap { $0 }, app: "cmux")
        ImportGhostty.addSettings(source, home: home, usKeyboard: usKeyboard, fonts: fonts, applications: apps, to: &plan)
        return plan
    }

    // MARK: shortcuts

    /// cmux's actions with a Next Term command of the same meaning. A cmux "surface" is a tab in a pane, as Next
    /// Term's tabs are; its workspaces (the sidebar) have no equivalent, so their actions aren't mapped.
    static let actions: [String: String] = [
        "newSurface": "newTab:", "closeTab": "closeTab:", "renameTab": "renameTab:", "closeOtherTabsInPane": "closeOtherTabs:",
        "nextSurface": "showNextTab:", "prevSurface": "showPreviousTab:", "newWindow": "newWindow:", "closeWindow": "performClose:",
        "toggleFullScreen": "toggleFullScreen:", "openSettings": "showSettings:", "openFolder": "openProjectPanel:",
        "splitRight": "splitRight:", "splitDown": "splitDown:", "focusLeft": "selectPaneLeft:", "focusRight": "selectPaneRight:",
        "focusUp": "selectPaneAbove:", "focusDown": "selectPaneBelow:", "focusNextPane": "selectNextPane:",
        "focusPreviousPane": "selectPreviousPane:", "toggleSplitZoom": "toggleZoomPane:", "find": "performFindPanelAction:#1",
        "findNext": "performFindPanelAction:#2", "findPrevious": "performFindPanelAction:#3",
        "useSelectionForFind": "performFindPanelAction:#7", "toggleFileExplorer": "toggleProjectSidebar:",
    ]

    /// Values cmux reads as "no shortcut".
    static let unbound: Set<String> = ["", "none", "clear", "unbound", "disabled"]

    /// `shortcuts.bindings` in cmux.json: `"action": "cmd+shift+t"`, a two-key chord as an array, or no shortcut
    /// (null, "", "none"…). Nothing else in the file is read; its other sections are named.
    static func addShortcuts(home: String, usKeyboard: Bool, to plan: inout ImportPlan) {
        let path = settingsFile(home: home)
        guard isRegularFile(path) else { return }
        guard let real = ImportFile.ownFile(path, folders: [(path as NSString).deletingLastPathComponent]) else {
            return plan.skipped.append(SkippedItem("cmux.json", ImportFile.linkedOut))
        }
        guard let data = ImportFile.data(real), data.count <= 4 << 20, let text = String(data: data, encoding: .utf8),
              JSONC.isShallow(text), let document = JSONC(text), case .object(let root)? = document.root else {
            return plan.skipped.append(SkippedItem("cmux.json", "couldn't be read, so cmux's own shortcuts didn't come over"))
        }
        let others = root.members.map(\.key).filter { !["$schema", "schemaVersion", "shortcuts"].contains($0) }
        if case .object(let shortcuts)? = root.member("shortcuts")?.value, case .object(let bindings)? = shortcuts.member("bindings")?.value {
            addBindings(bindings, in: text, usKeyboard: usKeyboard, to: &plan)
        }
        let shown = others.filter { !SecretGuard.looksSecret($0) && $0.count <= 60 }
        if !shown.isEmpty {
            let list = shown.prefix(12).joined(separator: ", ") + (shown.count > 12 ? " and \(shown.count - 12) more" : "")
            plan.skipped.append(SkippedItem("other cmux.json settings: " + list,
                                            "no matching Next Term setting yet; actions, commands and hooks there are never read"))
        }
    }

    static func addBindings(_ bindings: JSONC.Object, in text: String, usKeyboard: Bool, to plan: inout ImportPlan) {
        var unmatched = 0
        for member in bindings.members {
            let action = member.key
            guard let command = actions[action] ?? (action == "selectSurfaceByNumber" ? "selectTabByNumber:#1" : nil) else {
                unmatched += 1
                continue
            }
            let value = member.value.object(in: text)
            if value is NSNull || (value as? String).map({ unbound.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) == true {
                let source = "shortcuts.bindings.\(action): none"
                if action == "selectSurfaceByNumber" { continue }
                plan.shortcuts.append(ImportShortcuts.row(command, nil, source: source))
                continue
            }
            if let strokes = value as? [Any] {
                let shown = strokes.compactMap { $0 as? String }.map(ImportShortcuts.shown).joined(separator: ", ")
                let source = ImportKeys.label("shortcuts.bindings.\(action): [\(shown)]")
                plan.skipped.append(SkippedItem(source, strokes.count == 2 ? ImportShortcuts.twoStep : ImportShortcuts.notRecognised))
                continue
            }
            guard let stroke = value as? String else {
                plan.skipped.append(SkippedItem("shortcuts.bindings.\(action)", "value not recognised"))
                continue
            }
            let source = ImportKeys.label("shortcuts.bindings.\(action): \(stroke)")
            let parsed = key(stroke, usKeyboard: usKeyboard)
            guard case .chord(let chord) = parsed else {
                if case .notSupported(let reason) = parsed { plan.skipped.append(SkippedItem(source, reason)) }
                continue
            }
            if action == "selectSurfaceByNumber" {
                addNumbered(chord, source: source, to: &plan)
            } else {
                plan.shortcuts.append(ImportShortcuts.row(command, chord, source: source))
            }
        }
        if unmatched > 0 {
            plan.skipped.append(SkippedItem("\(unmatched) cmux shortcut\(unmatched == 1 ? "" : "s")",
                                            "no matching Next Term command (workspaces, notifications, the browser and other cmux features)"))
        }
    }

    /// cmux's one binding for surfaces 1–9 ("ctrl+1" stands for ⌃1…⌃9): tabs 1–8 and the last one here. A key
    /// the shell keeps is one row, not nine.
    static func addNumbered(_ chord: KeyChord, source: String, to plan: inout ImportPlan) {
        guard !ImportShortcuts.isShellKey(chord) else {
            return plan.skipped.append(SkippedItem(source, ImportShortcuts.shellNote))
        }
        for n in 1...9 {
            var key = chord
            key.key = String(n)
            plan.shortcuts.append(ImportShortcuts.row("selectTabByNumber:#\(n)", key, source: source))
        }
    }

    /// A cmux stroke as its config parser reads it: modifiers (`cmd`, `shift`, `opt`, `ctrl` and their other names)
    /// joined by `+`, then the key; `plus` is the = key there.
    static func key(_ stroke: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        let parts = stroke.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return .notSupported(ImportShortcuts.notRecognised) }
        let names: [String: String] = ["plus": "=", "spacebar": "space", "<space>": "space", "←": "left", "→": "right",
                                       "↑": "up", "↓": "down", "↩": "enter"]
        let lowered = last.lowercased()
        return ImportKeys.parse(modifiers: Array(parts.dropLast()), key: names[lowered] ?? lowered, usKeyboard: usKeyboard)
    }
}
