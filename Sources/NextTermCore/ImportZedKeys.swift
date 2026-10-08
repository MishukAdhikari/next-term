import Foundation

// The user's own shortcuts from Zed's keymap.json (§2.4), for the actions Next Term has too. From each section
// only its `context` and its `bindings` (each key and the action's name) are read; what an action is given
// (text a terminal would be sent, keystrokes to type) is never looked at, except a tab's number. Like the rest
// of the Zed import, this only reads.

extension ImportZed {
    /// Zed action → Next Term command, where the two do the same thing.
    static let actionMap: [String: String] = [
        "zed::OpenSettings": "showSettings:",
        "workspace::NewTerminal": "newTab:",
        "workspace::NewWindow": "newWindow:",
        "workspace::Open": "openProjectPanel:",
        "file_finder::Toggle": "goToFile:",
        "workspace::CloseWindow": "performClose:",
        "workspace::Save": "saveDocument:",
        "workspace::SaveAll": "saveAllDocuments:",
        "pane::SplitRight": "splitRight:",
        "pane::SplitDown": "splitDown:",
        "pane::CloseActiveItem": "closeTab:",
        "editor::Undo": "undo:",
        "editor::Redo": "redo:",
        "editor::Cut": "cut:",
        "editor::Copy": "copy:",
        "editor::Paste": "paste:",
        "editor::SelectAll": "selectAll:",
        "buffer_search::Deploy": "performFindPanelAction:#1",
        "buffer_search::DeployReplace": "replaceInFile:",
        "search::SelectNextMatch": "performFindPanelAction:#2",
        "search::SelectPreviousMatch": "performFindPanelAction:#3",
        "pane::DeploySearch": "findInFiles:",
        "workspace::DeploySearch": "findInFiles:",
        "go_to_line::Toggle": "goToLine:",
        "editor::ToggleComments": "toggleComment:",
        "editor::Indent": "indentSelection:",
        "editor::Outdent": "outdentSelection:",
        "editor::DuplicateLineDown": "duplicateLine:",
        "editor::DuplicateSelection": "duplicateLine:",
        "editor::DeleteLine": "deleteLine:",
        "editor::MoveLineUp": "moveLineUp:",
        "editor::MoveLineDown": "moveLineDown:",
        "terminal::Clear": "clearBuffer:",
        "workspace::ToggleLeftDock": "toggleProjectSidebar:",
        "pane::RevealInProjectPanel": "revealInSidebar:",
        "terminal_panel::ToggleFocus": "toggleEditorFocus:",
        "workspace::ToggleBottomDock": "toggleTerminalCollapsed:",
        "editor::ToggleSoftWrap": "toggleSoftWrap:",
        "zed::IncreaseBufferFontSize": "increaseFontSize:",
        "zed::DecreaseBufferFontSize": "decreaseFontSize:",
        "zed::ResetBufferFontSize": "resetFontSize:",
        "zed::ToggleFullScreen": "toggleFullScreen:",
        "zed::Minimize": "performMiniaturize:",
        "pane::ActivateNextItem": "showNextTab:",
        "pane::ActivatePreviousItem": "showPreviousTab:",
        "pane::ActivatePrevItem": "showPreviousTab:",  // its older name
        "pane::ActivateLastItem": "selectTabByNumber:#9",
        "workspace::ActivatePaneLeft": "selectPaneLeft:",
        "workspace::ActivatePaneRight": "selectPaneRight:",
        "workspace::ActivatePaneUp": "selectPaneAbove:",
        "workspace::ActivatePaneDown": "selectPaneBelow:",
        "workspace::ActivateNextPane": "selectNextPane:",
        "workspace::ActivatePreviousPane": "selectPreviousPane:",
    ]

    /// `["pane::ActivateItem", 0]` is the first tab: the one action whose argument is read (a number, 0 to 7).
    static let tabByIndex = "pane::ActivateItem"

    /// Actions that turn a key off where they are bound, as `null` does.
    static let noAction: Set<String> = ["zed::NoAction", "zed::Unbind"]

    /// One binding of keymap.json, in file order.
    struct Binding: Equatable {
        var key: String
        var context: String?
        /// The action's name (nil: `null`, or no name Zed would take).
        var action: String?
        /// The action came with an argument, which is never read (a tab's number aside).
        var hasArgument = false
        var tabIndex: Int?
    }

    /// keymap.json beside settings.json, as preview rows, and what was left out.
    static func keymapPlan(_ path: String, usKeyboard: Bool) -> (shortcuts: [PlannedShortcut], skipped: [SkippedItem]) {
        guard isRegularFile(path) else { return ([], []) }
        guard let text = ImportFile.text(path) else { return ([], [SkippedItem("keymap.json", "couldn't be read")]) }
        // As Zed first writes it: comments and an empty list, or nothing at all.
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        if JSONC.plain(text)?.trimmingCharacters(in: blank).isEmpty == true { return ([], []) }
        guard let bindings = bindings(text) else {
            return ([], [SkippedItem("keymap.json", "couldn't be read as JSON; your shortcuts were skipped")])
        }
        return shortcuts(bindings, usKeyboard: usKeyboard)
    }

    /// Every binding in file order (nil: not a JSONC list). Sections that aren't objects, and bindings that aren't
    /// a name, a list starting with one, or null, are left out.
    static func bindings(_ text: String) -> [Binding]? {
        guard let document = JSONC(text), let root = document.root, let sections = document.elements(of: root) else { return nil }
        var result: [Binding] = []
        for section in sections {
            guard case .object(let object) = section else { continue }
            let context = object.members.last { $0.key == "context" }?.value.object(in: text) as? String
            guard let bindings = object.members.last(where: { $0.key == "bindings" }), case .object(let keys) = bindings.value else { continue }
            for member in keys.members {
                var binding = Binding(key: member.key, context: context)
                switch member.value {
                case .scalar:
                    // A name, or null. Anything else is no action Zed would take either.
                    let value = member.value.object(in: text)
                    if value is NSNull { result.append(binding); continue }
                    guard let name = value as? String else { continue }
                    binding.action = name
                case .array:
                    guard let elements = document.elements(of: member.value), let first = elements.first,
                          case .scalar = first, let name = first.object(in: text) as? String else { continue }
                    binding.action = name
                    binding.hasArgument = elements.count > 1
                    if name == tabByIndex, elements.count == 2, case .scalar = elements[1],
                       let index = ImportVSCode.number(elements[1].object(in: text)), index == index.rounded(), (0...7).contains(index) {
                        binding.tabIndex = Int(index)
                    }
                case .object:
                    continue
                }
                result.append(binding)
            }
        }
        return result
    }

    /// The Next Term command a binding lands on, if any.
    static func command(for binding: Binding) -> String? {
        guard let action = binding.action else { return nil }
        if action == tabByIndex { return binding.tabIndex.map { "selectTabByNumber:#\($0 + 1)" } }
        return actionMap[action]
    }

    /// The bindings as rows, as Zed reads them (`top`): a binding Zed never obeys, because another on its key
    /// comes first wherever it works, is listed instead; of one command's keys left, the last one comes over (or
    /// else the last that is free to take). Two commands on one key are settled by `settled`.
    static func shortcuts(_ bindings: [Binding], usKeyboard: Bool) -> (shortcuts: [PlannedShortcut], skipped: [SkippedItem]) {
        struct Added {
            let index: Int
            let binding: Binding
            let chord: KeyChord
            let note: String?
        }
        var skipped: [SkippedItem] = []
        var order: [String] = []
        var added: [String: [Added]] = [:]
        let keys = bindings.map { binding -> KeyChord? in
            if case .chord(let chord) = keystroke(binding.key, usKeyboard: usKeyboard) { return chord }
            return nil
        }
        for (index, binding) in bindings.enumerated() {
            let label = describe(binding)
            guard let action = binding.action, !noAction.contains(action) else {
                skipped.append(SkippedItem(label, "turning a key off isn't brought over"))
                continue
            }
            guard let target = command(for: binding) else {
                skipped.append(SkippedItem(label, ImportShortcuts.noCommand))
                continue
            }
            let note: String?
            switch scope(of: binding.context) {
            case .everywhere: note = nil
            case .editor: note = KeyBindings.editorCommands.contains(target) ? nil : "kept to the editor in Zed"
            case .terminal where ImportShortcuts.terminalCommands.contains(target): note = "kept to the terminal in Zed"
            case .terminal, .limited:
                let context = ImportShortcuts.shown(binding.context ?? "")
                let shown = context.count > 60 ? String(context.prefix(57)) + "…" : context
                skipped.append(SkippedItem(label, "works only in “\(shown)” in Zed; keys for one context come later"))
                continue
            }
            if binding.hasArgument && binding.tabIndex == nil {
                skipped.append(SkippedItem(label, "passes arguments in Zed, which don't come over"))
                continue
            }
            switch keystroke(binding.key, usKeyboard: usKeyboard) {
            case .notSupported(let reason):
                skipped.append(SkippedItem(label, reason))
            case .chord(let chord):
                if let reason = ImportShortcuts.unusable(chord) {
                    skipped.append(SkippedItem(label, reason))
                } else if let other = outranking(index, in: bindings, keys: keys) {
                    skipped.append(SkippedItem(label, outrankedReason(bindings[other], further: other > index)))
                } else {
                    if !order.contains(target) { order.append(target) }
                    added[target, default: []].append(Added(index: index, binding: binding, chord: chord, note: note))
                }
            }
        }

        var rows: [KeyRow] = []
        for target in order {
            guard let list = added[target], let last = list.last else { continue }
            let pick = list.last { ImportShortcuts.isFree($0.chord) } ?? last
            let row = ImportShortcuts.row(target, pick.chord, source: "keymap.json: " + describe(pick.binding), note: pick.note)
            rows.append(KeyRow(index: pick.index, row: row))
            for other in list where other.index != pick.index {
                skipped.append(SkippedItem(describe(other.binding), "one shortcut per command here; \(pick.chord.display) comes over"))
            }
        }
        return (settled(rows, bindings: bindings), skipped)
    }

    /// Where a key press lands, in Next Term's parts: the editor has the keyboard, a terminal has it, or something
    /// else in the window does.
    enum Area: CaseIterable {
        case editor, terminal, other

        var name: String {
            switch self {
            case .editor: return "the editor"
            case .terminal: return "the terminal"
            case .other: return "the rest of the window"
            }
        }
    }

    /// How low in Zed's context tree a binding matches in `area` (nil: it doesn't work there). As Zed ranks
    /// them, a binding with no context matches at the lowest level, the same as one for the editor or the
    /// terminal it is in; `Pane` is above those and `Workspace` above that. Narrower contexts are left out.
    static func level(of binding: Binding, in area: Area) -> Int? {
        switch scope(of: binding.context) {
        case .everywhere:
            let context = binding.context?.trimmingCharacters(in: .whitespaces) ?? ""
            if context.isEmpty { return 3 }
            return context.contains("Pane") ? 2 : 1
        case .editor: return area == .editor ? 3 : nil
        case .terminal: return area == .terminal ? 3 : nil
        case .limited: return nil
        }
    }

    /// The binding Zed obeys in `area` among `candidates` (indexes into `bindings`, all on one key): the lowest in
    /// the context tree, then the one further down (nil: none works there).
    static func top(of candidates: [Int], in area: Area, bindings: [Binding]) -> Int? {
        var best: (level: Int, index: Int)?
        for index in candidates.sorted() {
            guard let level = level(of: bindings[index], in: area) else { continue }
            if let current = best, level < current.level { continue }
            best = (level, index)
        }
        return best?.index
    }

    static func sameAction(_ first: Binding, _ second: Binding) -> Bool {
        first.action == second.action && first.tabIndex == second.tabIndex
    }

    /// The binding Zed obeys instead of the one at `index` wherever that one works: another action, or `null`
    /// (nil: the one at `index` works somewhere). Another binding of the same action changes nothing.
    static func outranking(_ index: Int, in bindings: [Binding], keys: [KeyChord?]) -> Int? {
        guard let chord = keys[index] else { return nil }
        let candidates = bindings.indices.filter { keys[$0] == chord }
        var first: Int?
        for area in Area.allCases where level(of: bindings[index], in: area) != nil {
            guard let winner = top(of: candidates, in: area, bindings: bindings), !sameAction(bindings[winner], bindings[index]) else { return nil }
            if first == nil { first = winner }
        }
        return first
    }

    static func outrankedReason(_ winner: Binding, further: Bool) -> String {
        let off = winner.action.map { noAction.contains($0) } ?? true
        if further { return off ? "turned off further down" : "replaced further down by " + ImportShortcuts.shown(winner.action ?? "") }
        return "Zed obeys \(describe(winner)) on this key instead"
    }

    /// A row with the binding it came from.
    struct KeyRow {
        let index: Int
        let row: PlannedShortcut
    }

    /// One key on two commands, after the bindings Zed never obeys are gone, so each works somewhere. The two
    /// keep it when Next Term can share it the way Zed does (KeyBindings.canShareKey): the editor's command is
    /// the one Zed obeys in the editor, and the other the one it obeys in the terminal. Otherwise the one Zed
    /// obeys in more places keeps it (the one further down, if even), and the other is unticked.
    static func settled(_ rows: [KeyRow], bindings: [Binding]) -> [PlannedShortcut] {
        rows.map { entry -> PlannedShortcut in
            var row = entry.row
            guard row.ticked, let chord = row.chord else { return row }
            let rivals = rows.filter { $0.row.ticked && $0.row.chord == chord }
            guard rivals.count > 1 else { return row }
            let indexes = rivals.map(\.index)
            var winners: [Area: Int] = [:]
            for area in Area.allCases { winners[area] = top(of: indexes, in: area, bindings: bindings) }
            if rivals.count == 2, shareKey(rivals[0], rivals[1], winners: winners) { return row }
            func wins(_ rival: KeyRow) -> [Area] { Area.allCases.filter { winners[$0] == rival.index } }
            let best = rivals.max { first, second in
                let a = wins(first).count, b = wins(second).count
                return a != b ? a < b : first.index < second.index
            }
            guard let best, best.index != entry.index else { return row }
            row.ticked = false
            let mine = wins(entry).map(\.name).joined(separator: " and ")
            let note = mine.isEmpty ? "Zed gives \(chord.display) to \(best.row.title)"
                : "Zed gives \(chord.display) to this only in \(mine), to \(best.row.title) elsewhere; one key can't be both here"
            row.note = ImportShortcuts.join(note, row.note)
            return row
        }
    }

    /// Whether Zed obeys the editor's command of the two in the editor and the other in the terminal, as Next
    /// Term would share the key.
    static func shareKey(_ first: KeyRow, _ second: KeyRow, winners: [Area: Int]) -> Bool {
        guard KeyBindings.canShareKey(first.row.command, second.row.command) else { return false }
        let editorFirst = KeyBindings.editorCommands.contains(first.row.command)
        let editor = editorFirst ? first : second
        let other = editorFirst ? second : first
        return winners[.editor] == editor.index && winners[.terminal] == other.index
    }

    /// "cmd-shift-d → editor::DuplicateLineDown", for a preview line (a part that looks like a credential is
    /// never shown).
    static func describe(_ binding: Binding) -> String {
        let key = binding.key.trimmingCharacters(in: .whitespaces)
        var action = binding.action ?? "null"
        if let index = binding.tabIndex { action += " \(index)" }
        return ImportShortcuts.shown(key.isEmpty ? "(no key)" : key) + " → " + ImportShortcuts.shown(action)
    }

    // MARK: contexts

    /// Where a binding applies: everywhere (no context, the workspace or a pane, which hold the editors and the
    /// terminals both), the editor or the terminal (only those, joined by &&), or somewhere narrower (anything
    /// else: a panel, a mode, a vim state, an ||, a !).
    static func scope(of context: String?) -> ImportVSCode.Scope {
        guard let context = context?.trimmingCharacters(in: .whitespaces), !context.isEmpty else { return .everywhere }
        var editor = false, terminal = false
        for clause in context.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch clause.replacingOccurrences(of: " ", with: "") {
            case "Workspace", "Pane": continue
            case "Editor", "mode==full": editor = true
            case "Terminal": terminal = true
            default: return .limited
            }
        }
        if editor && terminal { return .limited }
        return terminal ? .terminal : editor ? .editor : .everywhere
    }

    // MARK: keystrokes

    /// Zed's modifier names (`secondary` is ⌘ on a Mac).
    static let modifierNames: [(name: String, modifier: String)] = [
        ("ctrl", "control"), ("control", "control"), ("alt", "option"), ("option", "option"), ("opt", "option"),
        ("shift", "shift"), ("cmd", "command"), ("command", "command"), ("super", "command"), ("win", "command"),
        ("secondary", "command"), ("fn", "fn"),
    ]

    /// Symbols typed with Shift, as their key on a U.S. layout ("cmd-}" is ⇧⌘]).
    static let shiftedSymbols: [String: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// One Zed keystroke ("cmd-shift-d", "ctrl-`", "alt-up", "cmd--"). Two steps ("cmd-k cmd-s") and the fn key
    /// aren't supported; a shifted symbol is read as on a U.S. keyboard, so only when that is the layout.
    static func keystroke(_ raw: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        let steps = raw.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard steps.count == 1 else {
            return .notSupported(steps.isEmpty ? ImportShortcuts.notRecognised : ImportShortcuts.twoStep)
        }
        var rest = steps[0].lowercased()
        var command = false, shift = false, option = false, control = false
        stripping: while true {
            for (name, modifier) in modifierNames where rest.count > name.count + 1 && rest.hasPrefix(name + "-") {
                switch modifier {
                case "control": control = true
                case "option": option = true
                case "shift": shift = true
                case "command": command = true
                default: return .notSupported("the fn key isn't supported")
                }
                rest.removeFirst(name.count + 1)
                continue stripping
            }
            break
        }
        if let base = shiftedSymbols[rest] {
            guard usKeyboard else { return .notSupported("a symbol typed with Shift, which another key may type on your layout") }
            shift = true
            rest = base
        }
        func chord(_ key: String) -> ImportShortcuts.ParsedKey {
            .chord(KeyChord(key: key, command: command, shift: shift, option: option, control: control))
        }
        if rest.count == 1, let c = rest.first, c.isASCII, c.isLetter || c.isNumber || ImportVSCode.symbolKeys.contains(c) {
            return chord(rest)
        }
        if let named = ImportVSCode.namedKeys[rest] { return chord(named) }
        if rest.hasPrefix("f"), let number = Int(rest.dropFirst()) {
            return ImportShortcuts.functionKey(number).map(chord) ?? .notSupported("keys above F12 aren't supported")
        }
        return .notSupported(ImportShortcuts.notRecognised)
    }
}
