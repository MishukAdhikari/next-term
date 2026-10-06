import Foundation

// The user's own shortcuts from a JetBrains IDE (§2.4): the actions their keymaps set (the active keymap and
// the custom keymaps it rests on), for the actions Next Term has too. Keymap files are opened only through
// `read` (keymaps/*.xml is on its allowlist), and nothing is written.

extension ImportJetBrains {
    /// JetBrains action id → Next Term command, where the two do the same thing.
    static let actionMap: [String: String] = {
        var map = [
            "ShowSettings": "showSettings:",
            "Terminal.NewTab": "newTab:",
            "OpenFile": "openProjectPanel:",
            "GotoFile": "goToFile:",
            "CloseProject": "closeProject:",
            "SaveDocument": "saveDocument:",
            "SaveAll": "saveAllDocuments:",
            "SplitVertically": "splitRight:",   // side by side
            "SplitHorizontally": "splitDown:",  // one above the other
            "Terminal.RenameSession": "renameTab:",
            "CloseContent": "closeTab:",
            "$Undo": "undo:",
            "$Redo": "redo:",
            "$Cut": "cut:",
            "$Copy": "copy:",
            "$Paste": "paste:",
            "$SelectAll": "selectAll:",
            "Find": "performFindPanelAction:#1",
            "FindNext": "performFindPanelAction:#2",
            "FindPrevious": "performFindPanelAction:#3",
            "FindInPath": "findInFiles:",
            "ReplaceInPath": "replaceInFiles:",
            "GotoLine": "goToLine:",
            "CommentByLineComment": "toggleComment:",
            "EditorIndentSelection": "indentSelection:",
            "EditorUnindentSelection": "outdentSelection:",
            "Terminal.ClearBuffer": "clearBuffer:",
            "ActivateProjectToolWindow": "toggleProjectSidebar:",
            "SelectInProjectView": "revealInSidebar:",
            "ActivateTerminalToolWindow": "toggleEditorFocus:",
            "Compare.SameVersion": "showChanges:",
            "EditorToggleUseSoftWraps": "toggleSoftWrap:",
            "EditorIncreaseFontSize": "increaseFontSize:",
            "EditorDecreaseFontSize": "decreaseFontSize:",
            "EditorResetFontSize": "resetFontSize:",
            "ToggleFullScreen": "toggleFullScreen:",
            "MinimizeCurrentWindow": "performMiniaturize:",
            "NextTab": "showNextTab:",
            "PreviousTab": "showPreviousTab:",
            "NextSplitter": "selectNextPane:",
            "PrevSplitter": "selectPreviousPane:",
            "GoToLastTab": "selectTabByNumber:#9",
        ]
        for n in 1...8 { map["GoToTab\(n)"] = "selectTabByNumber:#\(n)" }
        return map
    }()

    /// A row for every action the user's keymaps set that Next Term has too, and what was left out. Each
    /// keymap lists an action's whole set of shortcuts, so the nearest keymap that names an action decides it.
    static func addKeymapShortcuts(_ keymap: Keymap, config: String, to plan: inout ImportPlan) {
        var seen = Set<String>()
        var otherRemovals = 0
        for custom in keymap.customs {
            guard let root = read(config, custom.file), root.name == "keymap" else { continue }
            let name = SecretGuard.looksSecret(custom.name) ? "your keymap" : "“\(custom.name)”"
            for action in root.children where action.name == "action" {
                guard let id = action["id"], !id.isEmpty, seen.insert(id).inserted else { continue }
                guard !SecretGuard.looksSecret(id) else {
                    plan.skipped.append(SkippedItem("a shortcut", "looked like a credential"))
                    continue
                }
                guard let target = actionMap[id] else {
                    if action.children.isEmpty {
                        otherRemovals += 1
                    } else {
                        plan.skipped.append(SkippedItem(describe(action, id: id), ImportShortcuts.noCommand))
                    }
                    continue
                }
                addShortcut(action, id: id, target: target, keymap: name, to: &plan)
            }
        }
        if otherRemovals > 0 {
            plan.skipped.append(SkippedItem(plural(otherRemovals, "action", "actions") + " left without shortcuts in your keymap",
                                            "they have no matching Next Term command, so nothing changes here"))
        }
    }

    /// One mapped action: its first shortcut Next Term can take becomes the row (the IDE's menus show an
    /// action's first one, and a command has one shortcut here); the rest are reported.
    static func addShortcut(_ action: Node, id: String, target: String, keymap: String, to plan: inout ImportPlan) {
        var keys: [(text: String, chord: KeyChord)] = []
        var unsupported = false // a shortcut that can't come over: the user did give the action keys
        for child in action.children {
            switch child.name {
            case "keyboard-shortcut":
                let first = child["first-keystroke"] ?? ""
                let label = id + " " + ImportShortcuts.shown(first)
                if let second = child["second-keystroke"], !second.isEmpty {
                    unsupported = true
                    plan.skipped.append(SkippedItem(label + ", " + ImportShortcuts.shown(second), ImportShortcuts.twoStep))
                    continue
                }
                switch keyStroke(first) {
                case .notSupported(let reason):
                    unsupported = true
                    plan.skipped.append(SkippedItem(label, reason))
                case .chord(let chord):
                    if let reason = ImportShortcuts.unusable(chord) {
                        unsupported = true
                        plan.skipped.append(SkippedItem(label, reason))
                    } else if !keys.contains(where: { $0.chord == chord }) {
                        keys.append((first, chord))
                    }
                }
            case "mouse-shortcut":
                unsupported = true
                plan.skipped.append(SkippedItem(id + " " + ImportShortcuts.shown(child["keystroke"] ?? "mouse"), "mouse shortcuts aren't brought over"))
            case "keyboard-gesture-shortcut":
                unsupported = true
                plan.skipped.append(SkippedItem(id + " (a double-press key)", "double-press keys aren't supported yet"))
            default:
                continue
            }
        }
        if let first = keys.first {
            let pick = keys.first { ImportShortcuts.isFree($0.chord) } ?? first
            plan.shortcuts.append(ImportShortcuts.row(target, pick.chord, source: "\(keymap): \(id) \(ImportShortcuts.shown(pick.text))"))
            for key in keys where key.chord != pick.chord {
                plan.skipped.append(SkippedItem(id + " " + ImportShortcuts.shown(key.text), "one shortcut per command here; \(pick.chord.display) comes over"))
            }
        } else if !unsupported {
            // Listed with no shortcuts: the user took every key away from it.
            plan.shortcuts.append(ImportShortcuts.row(target, nil, source: "\(keymap): \(id) has no shortcut"))
        }
    }

    /// "EditorDuplicate meta shift D", for a preview line.
    static func describe(_ action: Node, id: String) -> String {
        let keys = action.children.compactMap { child -> String? in
            switch child.name {
            case "keyboard-shortcut":
                guard let first = child["first-keystroke"] else { return nil }
                return [first, child["second-keystroke"]].compactMap { $0 }.map(ImportShortcuts.shown).joined(separator: ", ")
            case "mouse-shortcut": return child["keystroke"].map(ImportShortcuts.shown)
            default: return nil
            }
        }
        return keys.first.map { id + " " + $0 } ?? id
    }

    // MARK: keystrokes

    /// Java key code names (`KeyEvent.VK_…` without the prefix) as AppKit's key-equivalent characters.
    static let keyNames: [String: String] = [
        "ENTER": "\r", "BACK_SPACE": "\u{8}", "TAB": "\t", "ESCAPE": "\u{1B}", "SPACE": " ", "DELETE": "\u{F728}",
        "LEFT": "\u{F702}", "RIGHT": "\u{F703}", "UP": "\u{F700}", "DOWN": "\u{F701}",
        "HOME": "\u{F729}", "END": "\u{F72B}", "PAGE_UP": "\u{F72C}", "PAGE_DOWN": "\u{F72D}",
        "COMMA": ",", "MINUS": "-", "PERIOD": ".", "SLASH": "/", "SEMICOLON": ";", "EQUALS": "=", "OPEN_BRACKET": "[",
        "BACK_SLASH": "\\", "CLOSE_BRACKET": "]", "BACK_QUOTE": "`", "QUOTE": "'", "PLUS": "+",
    ]

    static let numpadKeys: Set<String> = ["MULTIPLY", "ADD", "SUBTRACT", "DECIMAL", "DIVIDE", "SEPARATOR"]

    /// A keystroke as JetBrains writes it (Java's KeyStroke text): modifiers, then one key code name
    /// ("meta shift O", "control alt OPEN_BRACKET", "shift F6"). Saved shortcuts are written as typed, ⌘ as
    /// `meta`, so no ⌃/⌘ swap applies to them.
    static func keyStroke(_ text: String) -> ImportShortcuts.ParsedKey {
        var command = false, shift = false, option = false, control = false
        var key: String?
        for token in text.split(separator: " ").map(String.init) {
            switch token {
            case "meta": command = true
            case "shift": shift = true
            case "control", "ctrl": control = true
            case "alt", "altGraph": option = true
            case "pressed": continue
            default:
                guard key == nil else { return .notSupported(ImportShortcuts.notRecognised) }
                key = token
            }
        }
        guard let name = key else { return .notSupported(ImportShortcuts.notRecognised) }
        func chord(_ key: String) -> ImportShortcuts.ParsedKey {
            .chord(KeyChord(key: key, command: command, shift: shift, option: option, control: control))
        }
        if name.count == 1, let c = name.first, c.isASCII, c.isLetter || c.isNumber { return chord(name.lowercased()) }
        if let named = keyNames[name] { return chord(named) }
        if name.hasPrefix("F"), let number = Int(name.dropFirst()) {
            return ImportShortcuts.functionKey(number).map(chord) ?? .notSupported("keys above F12 aren't supported")
        }
        if name.hasPrefix("NUMPAD") || numpadKeys.contains(name) { return .notSupported(ImportShortcuts.numpad) }
        return .notSupported(ImportShortcuts.notRecognised)
    }
}
