import Foundation

// The user's own shortcuts from another app (§2.4): the Next Term commands they can land on, the keys no
// import takes (§2.1: Control keys without ⌘ belong to the shell and the agents; some keys belong to
// macOS), and settling the rows against Next Term's own shortcuts before the preview shows them. Each app's
// keymap reader lives beside its importer (ImportVSCodeKeys.swift, ImportJetBrainsKeys.swift) and only reads.

public enum ImportShortcuts {
    /// The Next Term commands an imported shortcut can land on, with their menu titles. Ids as
    /// `KeyboardShortcuts.id(of:)` gives them; only commands with a clear equivalent in VS Code or a
    /// JetBrains IDE (the self-test checks each is in the menus).
    public static let titles: [String: String] = {
        var titles = [
            "showSettings:": "Settings…",
            "newTab:": "New Tab",
            "newWindow:": "New Window",
            "openProjectPanel:": "Open Project…",
            "goToFile:": "Go to File…",
            "closeProject:": "Close Project",
            "saveDocument:": "Save",
            "saveAllDocuments:": "Save All",
            "splitRight:": "Split Right",
            "splitDown:": "Split Down",
            "renameTab:": "Rename Tab…",
            "closeTab:": "Close Tab",
            "performClose:": "Close Window",
            "undo:": "Undo",
            "redo:": "Redo",
            "cut:": "Cut",
            "copy:": "Copy",
            "paste:": "Paste",
            "selectAll:": "Select All",
            "performFindPanelAction:#1": "Find…",
            "replaceInFile:": "Replace…",
            "performFindPanelAction:#2": "Find Next",
            "performFindPanelAction:#3": "Find Previous",
            "performFindPanelAction:#7": "Use Selection for Find",
            "findInFiles:": "Find in Files…",
            "replaceInFiles:": "Replace in Files…",
            "goToLine:": "Go to Line…",
            "toggleComment:": "Comment Line",
            "indentSelection:": "Indent",
            "outdentSelection:": "Outdent",
            "duplicateLine:": "Duplicate Line",
            "deleteLine:": "Delete Line",
            "moveLineUp:": "Move Line Up",
            "moveLineDown:": "Move Line Down",
            "clearBuffer:": "Clear Buffer",
            "toggleProjectSidebar:": "Hide or Show Project Sidebar",
            "toggleEditorFocus:": "Focus Editor or Terminal",
            "toggleTerminalCollapsed:": "Collapse Terminal",
            "revealInSidebar:": "Show File in Project Sidebar",
            "showChanges:": "Show Changes",
            "toggleSoftWrap:": "Soft Wrap",
            "toggleSidebarSide:": "Project Sidebar on the Right",
            "increaseFontSize:": "Bigger",
            "decreaseFontSize:": "Smaller",
            "resetFontSize:": "Actual Size",
            "toggleFullScreen:": "Enter Full Screen",
            "performMiniaturize:": "Minimize",
            "showNextTab:": "Show Next Tab",
            "showPreviousTab:": "Show Previous Tab",
            "selectPaneLeft:": "Select Pane on the Left",
            "selectPaneRight:": "Select Pane on the Right",
            "selectPaneAbove:": "Select Pane Above",
            "selectPaneBelow:": "Select Pane Below",
            "selectNextPane:": "Select Next Pane",
            "selectPreviousPane:": "Select Previous Pane",
            "selectTabByNumber:#9": "Select Last Tab",
        ]
        for position in ["bottom", "right", "left", "top"] {
            titles["setTerminalPosition:" + position] = "Terminal Position › " + position.capitalized
        }
        for n in 1...8 { titles["selectTabByNumber:#\(n)"] = "Select Tab \(n)" }
        return titles
    }()

    /// Commands that act on the terminal, where a key the other app keeps to its terminal means the same here.
    static let terminalCommands: Set<String> = [
        "newTab:", "splitRight:", "splitDown:", "renameTab:", "closeTab:", "clearBuffer:", "showNextTab:", "showPreviousTab:",
        "selectNextPane:", "selectPreviousPane:", "toggleEditorFocus:", "toggleTerminalCollapsed:",
    ]

    // MARK: keys no import takes

    /// A Control key without ⌘ (function keys aside): readline's ⌃R and ⌃G, Claude Code's ⌃G, ⌃T, ⌃O… These
    /// stay with the shell and the agents whatever is imported (§2.1 [T]). Written against the stored form,
    /// so ⌃_ (stored as ⌃⇧-) and ⌃` count too.
    public static func isShellKey(_ chord: KeyChord) -> Bool {
        chord.control && !chord.command && !chord.isFunctionKey
    }

    /// Keys macOS keeps for itself on every Mac (§2.1 [S]), with what it uses them for. The app's own
    /// standard keys (⌘H, ⌘Q, ⌘M…) are Next Term commands, so they show up as a clash with them instead.
    public static let macOSKeys: [KeyChord: String] = {
        let space = " ", f5 = "\u{F708}", f11 = "\u{F70E}"
        var keys: [KeyChord: String] = [
            KeyChord(key: space, command: true): "Spotlight",
            KeyChord(key: space, command: true, option: true): "Spotlight in Finder",
            KeyChord(key: space, command: true, control: true): "Emoji & Symbols",
            KeyChord(key: "\t", command: true): "switching apps",
            KeyChord(key: "\t", command: true, shift: true): "switching apps",
            KeyChord(key: "`", command: true): "moving between an app's windows",
            KeyChord(key: "`", command: true, shift: true): "moving between an app's windows",
            KeyChord(key: "3", command: true, shift: true): "screenshots",
            KeyChord(key: "4", command: true, shift: true): "screenshots",
            KeyChord(key: "5", command: true, shift: true): "screenshots",
            KeyChord(key: "3", command: true, shift: true, control: true): "screenshots",
            KeyChord(key: "4", command: true, shift: true, control: true): "screenshots",
            KeyChord(key: "q", command: true, control: true): "Lock Screen",
            KeyChord(key: "q", command: true, shift: true): "Log Out",
            KeyChord(key: "q", command: true, shift: true, option: true): "Log Out",
            KeyChord(key: "d", command: true, option: true): "hiding the Dock",
            KeyChord(key: "d", command: true, control: true): "Look Up",
            KeyChord(key: "/", command: true, shift: true): "the Help menu's search",
            KeyChord(key: f5, command: true): "VoiceOver",
            KeyChord(key: f5, command: true, option: true): "Accessibility Shortcuts",
            KeyChord(key: f11): "Show Desktop",
            KeyChord(key: f11, shift: true): "Show Desktop",
        ]
        // ⌃F1–⌃F8: moving the keyboard to the menu bar, the Dock, toolbars…
        for scalar in 0xF704...0xF70B {
            keys[KeyChord(key: String(Character(UnicodeScalar(scalar)!)), control: true)] = "keyboard navigation"
        }
        return keys
    }()

    /// Why a key can't be a menu shortcut at all (nil: it can).
    static func unusable(_ chord: KeyChord) -> String? {
        if chord.key == "\u{1B}" { return "⎋ stays with the terminal and its agents" }
        return chord.isUsable ? nil : "a menu shortcut needs ⌘ or ⌃ (Option alone types a character)"
    }

    /// A key the preview offers ticked: not the shell's and not macOS's.
    static func isFree(_ chord: KeyChord) -> Bool { !isShellKey(chord) && macOSKeys[chord] == nil }

    static let shellNote = "Control keys without ⌘ stay with your shell and agents"
    static let everyKeyNote = "every key for it was removed there; tick to leave it without a shortcut here too"

    /// A preview row: ticked unless the key is the shell's (then it can't be ticked at all) or macOS's.
    static func row(_ command: String, _ chord: KeyChord?, source: String, removed: [KeyChord] = [], note: String? = nil) -> PlannedShortcut {
        let title = titles[command] ?? command
        guard let chord else {
            // Taking a key away is ticked only when the other app named the key (settled against Next Term's
            // own key later); "every key" is too vague to do unasked.
            return PlannedShortcut(command: command, title: title, chord: nil, source: source, removed: removed,
                                   ticked: !removed.isEmpty, note: removed.isEmpty ? join(everyKeyNote, note) : note)
        }
        if isShellKey(chord) {
            return PlannedShortcut(command: command, title: title, chord: chord, source: source, allowed: false, note: shellNote)
        }
        if let use = macOSKeys[chord] {
            return PlannedShortcut(command: command, title: title, chord: chord, source: source, ticked: false,
                                   note: join("macOS uses \(chord.display) for \(use); tick it only if you turned that off", note))
        }
        return PlannedShortcut(command: command, title: title, chord: chord, source: source, note: note)
    }

    static func join(_ first: String, _ second: String?) -> String {
        second.map { first + "; " + $0 } ?? first
    }

    // MARK: reading keys

    enum ParsedKey: Equatable {
        case chord(KeyChord)
        case notSupported(String)
    }

    static let notRecognised = "key not recognised"
    static let twoStep = "two-step keys aren't supported yet"
    static let numpad = "numpad keys aren't supported"
    static let noCommand = "no matching Next Term command"

    /// F1–F12 by number, as AppKit's function-key characters (F13 and up have no menu key here).
    static func functionKey(_ number: Int) -> String? {
        guard (1...12).contains(number) else { return nil }
        return String(Character(UnicodeScalar(0xF703 + number)!))
    }

    /// A key name or value for a preview line, unless it looks like a credential (then never shown).
    static func shown(_ text: String) -> String {
        SecretGuard.looksSecret(text) ? "…" : text
    }
}

extension ImportPlan {
    /// The plan with its shortcut rows settled against Next Term's shortcuts as the import would leave them.
    /// `current`: every command's shortcut under the preset being applied, the user's own changes on top;
    /// `aliases`: keys hidden menu items also answer to (⌘= for Bigger); `titles`: menu titles, for naming
    /// a command no row is about. A row that changes nothing goes; taking away a key Next Term doesn't use
    /// is reported instead; a key another command keeps leaves the row unticked, naming that command.
    public func settlingShortcuts(current: [String: KeyChord?], aliases: [KeyChord: String] = [:],
                                  titles: [String: String] = [:]) -> ImportPlan {
        var plan = self
        func name(_ id: String) -> String { ImportShortcuts.titles[id] ?? titles[id] ?? id }
        var rows: [PlannedShortcut] = []
        for row in shortcuts {
            guard let now = current[row.command] else {
                plan.skipped.append(SkippedItem(row.source, "no matching command in this version of Next Term"))
                continue
            }
            if let chord = row.chord {
                if chord == now { continue } // already so
            } else {
                guard let now else { continue } // no key to take away
                if !row.removed.isEmpty && !row.removed.contains(now) {
                    plan.skipped.append(SkippedItem(row.source, "\(name(row.command)) is on \(now.display) here, so it keeps it"))
                    continue
                }
            }
            rows.append(row)
        }

        // Two rows on one key: the first keeps it (an importer puts the one the other app obeys first), unless
        // one acts in the editor and the other on the terminal (KeyBindings.canShareKey).
        var claimed: [KeyChord: [String]] = [:]
        for i in rows.indices where rows[i].ticked {
            guard let chord = rows[i].chord else { continue }
            let command = rows[i].command
            if let first = claimed[chord, default: []].first(where: { !KeyBindings.canShareKey($0, command) }) {
                rows[i].ticked = false
                rows[i].note = ImportShortcuts.join("\(name(first)) gets \(chord.display) in this import", rows[i].note)
            } else {
                claimed[chord, default: []].append(command)
            }
        }

        // Keys other commands keep. Checked against the shortcuts as they will be with every ticked row
        // applied, so two commands swapping keys is no clash; a row unticked puts its command's key back,
        // which can clash with another row in turn, so this runs until nothing changes.
        var after = current
        for row in rows where row.ticked { after[row.command] = .some(row.chord) }
        func owners(of chord: KeyChord, except id: String) -> [String] {
            after.keys.sorted().filter { $0 != id && (after[$0] ?? nil) == chord && !KeyBindings.canShareKey($0, id) }
        }
        var changed = true
        while changed {
            changed = false
            for i in rows.indices where rows[i].ticked {
                guard let chord = rows[i].chord else { continue }
                let others = owners(of: chord, except: rows[i].command).map(name)
                if !others.isEmpty {
                    // ⌘D can be two commands' (one in the editor, one elsewhere): both are named.
                    let whose = others.map { $0 + "’s" }.joined(separator: " and ")
                    let left = others.joined(separator: " and ") + (others.count == 1 ? " is" : " are")
                    rows[i].ticked = false
                    rows[i].note = ImportShortcuts.join(
                        "\(chord.display) is \(whose) here; tick to move it (\(left) left without a shortcut)", rows[i].note)
                } else if let alias = aliases[chord], alias != rows[i].command {
                    // A hidden menu item's key can't be moved.
                    rows[i].ticked = false
                    rows[i].allowed = false
                    rows[i].note = ImportShortcuts.join("\(chord.display) is also \(name(alias)) here", rows[i].note)
                } else {
                    continue
                }
                after[rows[i].command] = .some(current[rows[i].command] ?? nil)
                changed = true
            }
        }
        // A key a row shares with a command in the other part: which one has it where.
        for i in rows.indices where rows[i].ticked {
            let command = rows[i].command
            guard let chord = rows[i].chord,
                  let other = after.keys.sorted().first(where: { $0 != command && (after[$0] ?? nil) == chord }) else { continue }
            let editor = KeyBindings.editorCommands.contains(command) ? command : other
            let elsewhere = editor == command ? other : command
            let shared = "\(chord.display) is \(name(editor)) while the editor has the keyboard, \(name(elsewhere)) everywhere else"
            if rows[i].note?.contains(shared) != true { rows[i].note = ImportShortcuts.join(shared, rows[i].note) }
        }
        plan.shortcuts = rows
        return plan
    }
}
