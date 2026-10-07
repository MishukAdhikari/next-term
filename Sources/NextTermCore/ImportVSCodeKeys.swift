import Foundation

// The user's own shortcuts from keybindings.json (§2.4), for the commands Next Term has too. Only `key`,
// `command` and `when` are converted from each rule; `args` (text a terminal would be sent, say) is only
// noticed, never read. Like the rest of the VS Code import, this only reads.

extension ImportVSCode {
    /// VS Code command → Next Term command, where the two do the same thing.
    static let commandMap: [String: String] = {
        var map = [
            "workbench.action.openSettings": "showSettings:",
            "workbench.action.openSettings2": "showSettings:",
            "workbench.action.terminal.new": "newTab:",
            "workbench.action.newWindow": "newWindow:",
            "workbench.action.files.openFileFolder": "openProjectPanel:",
            "workbench.action.files.openFolder": "openProjectPanel:",
            "workbench.action.closeFolder": "closeProject:",
            "workbench.action.quickOpen": "goToFile:",
            "workbench.action.files.save": "saveDocument:",
            "workbench.action.files.saveAll": "saveAllDocuments:",
            "workbench.action.terminal.split": "splitRight:",
            "workbench.action.terminal.rename": "renameTab:",
            "workbench.action.closeActiveEditor": "closeTab:",
            "workbench.action.closeWindow": "performClose:",
            "undo": "undo:",
            "redo": "redo:",
            "editor.action.clipboardCutAction": "cut:",
            "editor.action.clipboardCopyAction": "copy:",
            "editor.action.clipboardPasteAction": "paste:",
            "editor.action.selectAll": "selectAll:",
            "actions.find": "performFindPanelAction:#1",
            "editor.action.startFindReplaceAction": "replaceInFile:",
            "editor.action.nextMatchFindAction": "performFindPanelAction:#2",
            "editor.action.previousMatchFindAction": "performFindPanelAction:#3",
            "actions.findWithSelection": "performFindPanelAction:#7",
            "workbench.action.findInFiles": "findInFiles:",
            "workbench.view.search": "findInFiles:",
            "workbench.action.replaceInFiles": "replaceInFiles:",
            "workbench.action.gotoLine": "goToLine:",
            "editor.action.commentLine": "toggleComment:",
            "editor.action.indentLines": "indentSelection:",
            "editor.action.outdentLines": "outdentSelection:",
            "workbench.action.terminal.clear": "clearBuffer:",
            "workbench.action.toggleSidebarVisibility": "toggleProjectSidebar:",
            "workbench.files.action.showActiveFileInExplorer": "revealInSidebar:",
            "workbench.action.toggleSidebarPosition": "toggleSidebarSide:",
            "workbench.action.terminal.toggleTerminal": "toggleEditorFocus:",
            "workbench.action.togglePanel": "toggleTerminalCollapsed:",
            "git.openChange": "showChanges:",
            "editor.action.toggleWordWrap": "toggleSoftWrap:",
            "workbench.action.zoomIn": "increaseFontSize:",
            "editor.action.fontZoomIn": "increaseFontSize:",
            "workbench.action.zoomOut": "decreaseFontSize:",
            "editor.action.fontZoomOut": "decreaseFontSize:",
            "workbench.action.zoomReset": "resetFontSize:",
            "editor.action.fontZoomReset": "resetFontSize:",
            "workbench.action.toggleFullScreen": "toggleFullScreen:",
            "workbench.action.minimizeWindow": "performMiniaturize:",
            "workbench.action.nextEditor": "showNextTab:",
            "workbench.action.previousEditor": "showPreviousTab:",
            "workbench.action.nextEditorInGroup": "showNextTab:",
            "workbench.action.previousEditorInGroup": "showPreviousTab:",
            "workbench.action.terminal.focusNext": "showNextTab:",
            "workbench.action.terminal.focusPrevious": "showPreviousTab:",
            "workbench.action.terminal.focusNextPane": "selectNextPane:",
            "workbench.action.terminal.focusPreviousPane": "selectPreviousPane:",
            "workbench.action.navigateLeft": "selectPaneLeft:",
            "workbench.action.navigateRight": "selectPaneRight:",
            "workbench.action.navigateUp": "selectPaneAbove:",
            "workbench.action.navigateDown": "selectPaneBelow:",
            "workbench.action.lastEditorInGroup": "selectTabByNumber:#9",
        ]
        for position in ["Bottom", "Right", "Left", "Top"] {
            map["workbench.action.positionPanel" + position] = "setTerminalPosition:" + position.lowercased()
        }
        // openEditorAtIndex9 is the ninth editor, not the last one, so it has no match.
        for n in 1...8 { map["workbench.action.openEditorAtIndex\(n)"] = "selectTabByNumber:#\(n)" }
        return map
    }()

    /// One rule of keybindings.json. `command` nil: the rule has none (or not as text).
    struct Rule: Equatable {
        var key: String
        var command: String?
        var when: String? = nil
        var hasArgs = false
    }

    /// The default profile's keybindings.json (`<User>/keybindings.json`) as preview rows, and what was left out.
    static func keybindingsPlan(user: String, usKeyboard: Bool) -> (shortcuts: [PlannedShortcut], skipped: [SkippedItem]) {
        let path = (user as NSString).appendingPathComponent("keybindings.json")
        guard isRegularFile(path) else { return ([], []) }
        guard let text = readText(path, limit: 4 << 20) else { return ([], [SkippedItem("keybindings.json", "couldn't be read")]) }
        // A new one holds a comment and [] only; a file of comments alone is just as empty.
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        if JSONC.plain(text)?.trimmingCharacters(in: blank).isEmpty == true { return ([], []) }
        guard let rules = rules(text) else {
            return ([], [SkippedItem("keybindings.json", "couldn't be read as JSON; your shortcuts were skipped")])
        }
        return shortcuts(rules, usKeyboard: usKeyboard)
    }

    /// The rules in file order (nil: not a JSONC array). Elements that aren't objects are left out.
    static func rules(_ text: String) -> [Rule]? {
        guard let document = JSONC(text), let root = document.root, let elements = document.elements(of: root) else { return nil }
        return elements.compactMap { element -> Rule? in
            guard case .object(let object) = element else { return nil }
            func string(_ key: String) -> String? { object.members.last { $0.key == key }?.value.object(in: text) as? String }
            return Rule(key: string("key") ?? "", command: string("command"), when: string("when"), hasArgs: object.member("args") != nil)
        }
    }

    /// The rules as rows, following VS Code (keybindings doc, `keybindingResolver.ts`): a rule adds a key
    /// to a command; `-command` removes a key VS Code gives it by default (with no key, all of them), never
    /// one the user added; a command shows its last rule's key; on one key, the rule further down wins.
    static func shortcuts(_ rules: [Rule], usKeyboard: Bool) -> (shortcuts: [PlannedShortcut], skipped: [SkippedItem]) {
        struct Added {
            let index: Int
            let rule: Rule
            let chord: KeyChord
            let note: String?
        }
        var skipped: [SkippedItem] = []
        var order: [String] = []                 // Next Term commands, as the file first names them
        var added: [String: [Added]] = [:]
        var addedAny = Set<String>()             // commands with a rule of their own, usable here or not
        var removals: [String: [(index: Int, rule: Rule)]] = [:]
        var otherRemovals = 0
        for (index, rule) in rules.enumerated() {
            let label = describe(rule)
            guard let command = rule.command?.trimmingCharacters(in: .whitespaces) else {
                skipped.append(SkippedItem(label, "has no command"))
                continue
            }
            if command.isEmpty || command == "-" {
                skipped.append(SkippedItem(label, "turning a key off isn't brought over"))
                continue
            }
            let removal = command.hasPrefix("-")
            guard let target = commandMap[removal ? String(command.dropFirst()) : command] else {
                if removal { otherRemovals += 1 } else { skipped.append(SkippedItem(label, ImportShortcuts.noCommand)) }
                continue
            }
            if !removal { addedAny.insert(target) }
            let note: String?
            switch scope(of: rule.when) {
            case .everywhere: note = nil
            case .editor: note = "kept to the editor in VS Code"
            case .terminal where ImportShortcuts.terminalCommands.contains(target): note = "kept to the terminal in VS Code"
            case .terminal, .limited:
                let when = ImportShortcuts.shown(rule.when ?? "")
                let shown = when.count > 60 ? String(when.prefix(57)) + "…" : when
                skipped.append(SkippedItem(label, "works only when “\(shown)” in VS Code; keys for one context come later"))
                continue
            }
            if rule.hasArgs {
                skipped.append(SkippedItem(label, "passes arguments in VS Code, which don't come over"))
                continue
            }
            if !order.contains(target) { order.append(target) }
            if removal {
                removals[target, default: []].append((index, rule))
                continue
            }
            switch parseKey(rule.key, usKeyboard: usKeyboard) {
            case .notSupported(let reason):
                skipped.append(SkippedItem(label, reason))
            case .chord(let chord):
                if let reason = ImportShortcuts.unusable(chord) {
                    skipped.append(SkippedItem(label, reason))
                } else {
                    added[target, default: []].append(Added(index: index, rule: rule, chord: chord, note: note))
                }
            }
        }

        var rows: [(index: Int, row: PlannedShortcut)] = []
        for target in order {
            if let list = added[target], let last = list.last {
                // One key per command here: the last rule's, as VS Code's menus show it, or else the last one
                // that is free to take.
                let pick = list.last { ImportShortcuts.isFree($0.chord) } ?? last
                rows.append((pick.index, ImportShortcuts.row(target, pick.chord, source: "keybindings.json: " + describe(pick.rule), note: pick.note)))
                for other in list where other.index != pick.index {
                    skipped.append(SkippedItem(describe(other.rule), "one shortcut per command here; \(pick.chord.display) comes over"))
                }
            } else if let gone = removals[target], let first = gone.first, !addedAny.contains(target) {
                // Only a removal: the key goes here too when it is the one Next Term uses (settled later). A
                // command the user gave another key (one that can't come over) keeps Next Term's.
                var keys: [KeyChord] = []
                var every = false
                for removal in gone {
                    if removal.rule.key.trimmingCharacters(in: .whitespaces).isEmpty {
                        every = true
                    } else if case .chord(let chord) = parseKey(removal.rule.key, usKeyboard: usKeyboard) {
                        keys.append(chord)
                    }
                }
                guard every || !keys.isEmpty else { continue } // only keys Next Term can't have, so it has none of them
                let source = "keybindings.json: " + gone.map { describe($0.rule) }.joined(separator: ", ")
                rows.append((first.index, ImportShortcuts.row(target, nil, source: source, removed: every ? [] : keys)))
            }
        }
        // One key on two commands: VS Code obeys the rule further down, so the other row is unticked.
        var winner: [KeyChord: (index: Int, title: String)] = [:]
        for (index, row) in rows where row.ticked {
            if let chord = row.chord, (winner[chord]?.index ?? -1) < index { winner[chord] = (index, row.title) }
        }
        let shortcuts = rows.map { entry -> PlannedShortcut in
            var row = entry.row
            guard row.ticked, let chord = row.chord, let win = winner[chord], win.index != entry.index else { return row }
            row.ticked = false
            row.note = ImportShortcuts.join("a rule further down gives \(chord.display) to \(win.title)", row.note)
            return row
        }
        if otherRemovals > 0 {
            skipped.append(SkippedItem(counted(otherRemovals, "shortcut") + " removed in keybindings.json",
                                       "they belong to commands Next Term doesn't have, so nothing changes here"))
        }
        return (shortcuts, skipped)
    }

    /// "cmd+k cmd+s → workbench.action.files.saveAs", for a preview line (a part that looks like a
    /// credential is never shown).
    static func describe(_ rule: Rule) -> String {
        let key = rule.key.trimmingCharacters(in: .whitespaces)
        let command = rule.command.map { $0.isEmpty ? "\"\"" : $0 } ?? "(no command)"
        return ImportShortcuts.shown(key.isEmpty ? "(no key)" : key) + " → " + ImportShortcuts.shown(command)
    }

    // MARK: when clauses

    enum Scope: Equatable {
        case everywhere, editor, terminal, limited
    }

    /// Clauses that only say the editor has the keyboard (or that the terminal doesn't).
    static let editorClauses: Set<String> = ["editorTextFocus", "editorFocus", "textInputFocus", "!terminalFocus"]
    /// Clauses that only say the terminal has the keyboard, or that one is open.
    static let terminalClauses: Set<String> = ["terminalFocus", "terminalFocusInAny", "terminal.active", "terminalIsOpen",
                                               "terminalProcessSupported", "terminalHasBeenCreated"]
    static let neutralClauses: Set<String> = ["!editorReadonly"]

    /// Where a rule applies: everywhere (no `when`), the editor or the terminal (only those basics joined by
    /// &&), or somewhere narrower (anything else: a selection, a widget, a language, an ||).
    static func scope(of when: String?) -> Scope {
        guard let when = when?.trimmingCharacters(in: .whitespaces), !when.isEmpty else { return .everywhere }
        var editor = false, terminal = false
        for clause in when.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if editorClauses.contains(clause) {
                editor = true
            } else if terminalClauses.contains(clause) {
                terminal = true
            } else if !neutralClauses.contains(clause) {
                return .limited
            }
        }
        if editor && terminal { return .limited }
        return terminal ? .terminal : editor ? .editor : .everywhere
    }

    // MARK: key strings

    /// Named keys, as AppKit's key-equivalent characters.
    static let namedKeys: [String: String] = [
        "left": "\u{F702}", "right": "\u{F703}", "up": "\u{F700}", "down": "\u{F701}",
        "home": "\u{F729}", "end": "\u{F72B}", "pageup": "\u{F72C}", "pagedown": "\u{F72D}",
        "enter": "\r", "tab": "\t", "space": " ", "backspace": "\u{8}", "delete": "\u{F728}", "escape": "\u{1B}",
    ]

    /// Scan codes (`[KeyA]`, `[BracketLeft]`) that name a key by its place: what it types depends on the layout.
    static let placedKeys: [String: String] = [
        "minus": "-", "equal": "=", "bracketleft": "[", "bracketright": "]", "backslash": "\\", "semicolon": ";",
        "quote": "'", "backquote": "`", "comma": ",", "period": ".", "slash": "/",
    ]

    static let symbolKeys = "`-=[]\\;',./"

    /// One VS Code key ("cmd+shift+p", "ctrl+`", "alt+[ArrowUp]"). Two steps ("cmd+k cmd+s") aren't supported;
    /// scan codes for characters are read as on a U.S. keyboard, so only when that is the layout.
    static func parseKey(_ raw: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        let steps = raw.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ")
        guard steps.count == 1 else {
            return .notSupported(steps.isEmpty ? ImportShortcuts.notRecognised : ImportShortcuts.twoStep)
        }
        var rest = steps[0]
        var command = false, shift = false, option = false, control = false
        stripping: while true {
            for name in ["ctrl", "shift", "alt", "cmd", "meta", "win"] {
                guard rest.count > name.count + 1, rest.hasPrefix(name),
                      let separator = rest.dropFirst(name.count).first, separator == "+" || separator == "-" else { continue }
                switch name {
                case "ctrl": control = true
                case "shift": shift = true
                case "alt": option = true
                default: command = true // cmd, meta and win are all ⌘ on a Mac
                }
                rest = rest.dropFirst(name.count + 1)
                continue stripping
            }
            break
        }
        func chord(_ key: String) -> ImportShortcuts.ParsedKey {
            .chord(KeyChord(key: key, command: command, shift: shift, option: option, control: control))
        }
        let key = String(rest)
        if key.count == 1, let c = key.first, c.isASCII, c.isLetter || c.isNumber || symbolKeys.contains(c) { return chord(key) }
        if let named = namedKeys[key] { return chord(named) }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()) {
            return ImportShortcuts.functionKey(number).map(chord) ?? .notSupported("keys above F12 aren't supported")
        }
        if key.hasPrefix("numpad") { return .notSupported(ImportShortcuts.numpad) }
        guard key.hasPrefix("["), key.hasSuffix("]"), key.count > 2 else { return .notSupported(ImportShortcuts.notRecognised) }

        // A scan code.
        let code = String(key.dropFirst().dropLast())
        if code.hasPrefix("arrow"), let named = namedKeys[String(code.dropFirst(5))] { return chord(named) }
        if let named = namedKeys[code] { return chord(named) }
        if code.hasPrefix("f"), let number = Int(code.dropFirst()), let function = ImportShortcuts.functionKey(number) { return chord(function) }
        if code.hasPrefix("numpad") { return .notSupported(ImportShortcuts.numpad) }
        var typed = placedKeys[code]
        if code.count == 4, code.hasPrefix("key"), let letter = code.last, letter.isASCII, letter.isLetter { typed = String(letter) }
        if code.count == 6, code.hasPrefix("digit"), let digit = code.last, digit.isASCII, digit.isNumber { typed = String(digit) }
        guard let typed else { return .notSupported(ImportShortcuts.notRecognised) }
        return usKeyboard ? chord(typed) : .notSupported("given by its place on the keyboard, which types something else on your layout")
    }
}
