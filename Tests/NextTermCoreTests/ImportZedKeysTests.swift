import Foundation
import Testing
@testable import NextTermCore

/// Zed's keymap.json, read from hand-made keymaps (no file on disk unless the test writes one in a temp home).
@Suite struct ImportZedKeysTests {
    func shortcuts(_ keymap: String, usKeyboard: Bool = true) throws -> (shortcuts: [PlannedShortcut], skipped: [SkippedItem]) {
        let bindings = try #require(ImportZed.bindings(keymap))
        return ImportZed.shortcuts(bindings, usKeyboard: usKeyboard)
    }

    func reasons(_ skipped: [SkippedItem]) -> [String: String] {
        Dictionary(skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    func key(_ text: String, usKeyboard: Bool = true) -> KeyChord? {
        if case .chord(let chord) = ImportZed.keystroke(text, usKeyboard: usKeyboard) { return chord }
        return nil
    }

    func reason(_ text: String, usKeyboard: Bool = true) -> String? {
        if case .notSupported(let reason) = ImportZed.keystroke(text, usKeyboard: usKeyboard) { return reason }
        return nil
    }

    @Test func keystrokes() {
        #expect(key("cmd-shift-d") == KeyChord(key: "d", command: true, shift: true))
        #expect(key("secondary-k") == KeyChord(key: "k", command: true))
        #expect(key("super-t") == KeyChord(key: "t", command: true))
        #expect(key("ctrl-alt-up")?.display == "⌃⌥↑")
        #expect(key("cmd--") == KeyChord(key: "-", command: true))
        #expect(key("ctrl-shift--") == KeyChord(key: "-", shift: true, control: true))
        #expect(key("cmd-=") == KeyChord(key: "=", command: true))
        #expect(key("cmd-backspace")?.display == "⌘⌫")
        #expect(key("cmd-enter")?.display == "⌘↩")
        #expect(key("shift-f6")?.display == "⇧F6")
        #expect(key("Cmd-Shift-P") == KeyChord(key: "p", command: true, shift: true))
        // A symbol typed with Shift is its key with ⇧ on a U.S. layout ("cmd-}" is ⇧⌘]).
        #expect(key("cmd-}") == KeyChord(key: "]", command: true, shift: true))
        #expect(key("cmd-{") == KeyChord(key: "[", command: true, shift: true))
        #expect(reason("cmd-}", usKeyboard: false) == "a symbol typed with Shift, which another key may type on your layout")
        #expect(reason("cmd-k cmd-s") == ImportShortcuts.twoStep)
        #expect(reason("fn-f") == "the fn key isn't supported")
        #expect(reason("cmd-f20") == "keys above F12 aren't supported")
        #expect(reason("cmd-") == ImportShortcuts.notRecognised)
        #expect(reason("cmd-unknownkey") == ImportShortcuts.notRecognised)
        #expect(reason("") == ImportShortcuts.notRecognised)
    }

    @Test func contexts() {
        let cases: [(String?, ImportVSCode.Scope)] = [
            (nil, .everywhere), ("", .everywhere), ("Workspace", .everywhere), ("Pane", .everywhere),
            ("Editor", .editor), ("Editor && mode == full", .editor), ("Editor && mode==full", .editor),
            ("Terminal", .terminal), ("Workspace && Terminal", .terminal),
            ("ProjectPanel", .limited), ("Editor && vim_mode == normal", .limited), ("Editor || Terminal", .limited),
            ("Editor && Terminal", .limited), ("!Terminal", .limited), ("Workspace > Pane", .limited),
        ]
        for (context, scope) in cases { #expect(ImportZed.scope(of: context) == scope, "\(context ?? "nil")") }
    }

    @Test func ownKeysFromAKeymap() throws {
        let result = try shortcuts("""
            // Zed keymap
            [
              {
                "context": "Workspace",
                "bindings": {
                  "cmd-t": "workspace::NewTerminal",
                  "cmd-shift-p": "command_palette::Toggle",   // nothing to land on
                  "cmd-1": ["pane::ActivateItem", 0],
                  "cmd-9": "pane::ActivateLastItem",
                  "cmd-shift-]": "pane::ActivateNextItem",
                  "cmd-w": null,
                  "cmd-k cmd-s": "zed::OpenKeymap",
                  "ctrl-`": "terminal_panel::ToggleFocus",
                },
              },
              {
                "context": "Editor",
                "bindings": {
                  "cmd-shift-d": "editor::DuplicateLineDown",
                  "cmd-backspace": "editor::DeleteLine",
                  "ctrl-shift-up": "editor::MoveLineUp",
                  "cmd-shift-e": "pane::RevealInProjectPanel",
                  "alt-z": "editor::ToggleSoftWrap",
                },
              },
              {
                "context": "Terminal",
                "bindings": {
                  "cmd-k": "terminal::Clear",
                  "cmd-c": "terminal::Copy",
                  "ctrl-g": ["terminal::SendText", "export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123\\n"],
                },
              },
              { "context": "ProjectPanel", "bindings": { "cmd-backspace": "project_panel::Delete", "cmd-n": "workspace::NewWindow" } },
              { "context": "Editor && vim_mode == normal", "bindings": { "space f": "file_finder::Toggle" } },
              { "bindings": { "cmd-shift-f": ["pane::DeploySearch", { "replace_enabled": true }], "cmd-o": "zed::NoAction" } },
            ]
            """)
        let rows = Dictionary(result.shortcuts.map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(result.shortcuts.map(\.command) == ["newTab:", "selectTabByNumber:#1", "selectTabByNumber:#9", "showNextTab:",
                                                    "toggleEditorFocus:", "duplicateLine:", "deleteLine:", "moveLineUp:",
                                                    "revealInSidebar:", "clearBuffer:"])
        #expect(rows["newTab:"]?.chord == KeyChord(key: "t", command: true))
        #expect(rows["newTab:"]?.source == "keymap.json: cmd-t → workspace::NewTerminal")
        #expect(rows["selectTabByNumber:#1"]?.source == "keymap.json: cmd-1 → pane::ActivateItem 0")
        #expect(rows["showNextTab:"]?.chord == KeyChord(key: "]", command: true, shift: true))
        // A Control key without ⌘ stays with the shell.
        #expect(rows["toggleEditorFocus:"]?.allowed == false)
        // Kept to one part in Zed: an editor command needs no note, another command says where it was.
        #expect(rows["duplicateLine:"]?.chord == KeyChord(key: "d", command: true, shift: true) && rows["duplicateLine:"]?.note == nil)
        #expect(rows["revealInSidebar:"]?.note == "kept to the editor in Zed")
        #expect(rows["clearBuffer:"]?.note == "kept to the terminal in Zed")

        let skipped = reasons(result.skipped)
        #expect(skipped["cmd-shift-p → command_palette::Toggle"] == ImportShortcuts.noCommand)
        #expect(skipped["cmd-w → null"] == "turning a key off isn't brought over")
        #expect(skipped["cmd-o → zed::NoAction"] == "turning a key off isn't brought over")
        #expect(skipped["cmd-k cmd-s → zed::OpenKeymap"] == ImportShortcuts.noCommand)
        #expect(skipped["alt-z → editor::ToggleSoftWrap"] == "a menu shortcut needs ⌘ or ⌃ (Option alone types a character)")
        #expect(skipped["cmd-c → terminal::Copy"] == ImportShortcuts.noCommand)
        #expect(skipped["ctrl-g → terminal::SendText"] == ImportShortcuts.noCommand)
        #expect(skipped["cmd-n → workspace::NewWindow"] == "works only in “ProjectPanel” in Zed; keys for one context come later")
        #expect(skipped["space f → file_finder::Toggle"] == "works only in “Editor && vim_mode == normal” in Zed; keys for one context come later")
        #expect(skipped["cmd-shift-f → pane::DeploySearch"] == "passes arguments in Zed, which don't come over")
        // What an action is given (text for the terminal) is never read or shown.
        #expect(!"\(result)".contains("ghp_") && !"\(result)".contains("replace_enabled"))
    }

    @Test func theBindingFurtherDownWins() throws {
        // One command, two keys: the later one comes over, the other is reported.
        let twice = try shortcuts("""
            [{ "bindings": { "cmd-shift-o": "file_finder::Toggle" } },
             { "bindings": { "cmd-e": "file_finder::Toggle" } }]
            """)
        #expect(twice.shortcuts.map(\.chord) == [KeyChord(key: "e", command: true)])
        #expect(reasons(twice.skipped)["cmd-shift-o → file_finder::Toggle"] == "one shortcut per command here; ⌘E comes over")
        // ...unless the later one is a key macOS keeps.
        let free = try shortcuts(#"[{ "bindings": { "cmd-e": "file_finder::Toggle", "cmd-space": "file_finder::Toggle" } }]"#)
        #expect(free.shortcuts.first?.chord == KeyChord(key: "e", command: true))

        // One key, two commands: the later binding keeps it, and the earlier row is unticked.
        let clash = try shortcuts("""
            [{ "bindings": { "cmd-e": "go_to_line::Toggle" } },
             { "bindings": { "cmd-e": "file_finder::Toggle" } }]
            """)
        #expect(clash.shortcuts.map(\.command) == ["goToLine:", "goToFile:"])
        #expect(clash.shortcuts.map(\.ticked) == [false, true])
        #expect(clash.shortcuts.first?.note == "a binding further down gives ⌘E to Go to File…")
    }

    @Test func everyActionLandsOnACommandAnImportMaySet() {
        for (action, command) in ImportZed.actionMap { #expect(ImportShortcuts.titles[command] != nil, "\(action)") }
        for index in 0...7 {
            let binding = ImportZed.Binding(key: "cmd-\(index + 1)", context: nil, action: ImportZed.tabByIndex, hasArgument: true, tabIndex: index)
            #expect(ImportZed.command(for: binding).flatMap { ImportShortcuts.titles[$0] } != nil)
        }
        // A tab number outside 0–7 (or not a number) lands nowhere.
        let far = ImportZed.bindings(#"[{ "bindings": { "cmd-0": ["pane::ActivateItem", 9], "cmd-8": ["pane::ActivateItem", "x"] } }]"#)
        #expect(far?.allSatisfy { ImportZed.command(for: $0) == nil } == true)
    }

    @Test func oddKeymaps() throws {
        // Not a list, sections that aren't objects, bindings that aren't names: left out, never an error.
        #expect(ImportZed.bindings(#"{"bindings": {}}"#) == nil)
        #expect(ImportZed.bindings("[1, \"two\", {\"bindings\": 3}, {\"bindings\": {\"cmd-t\": 4, \"cmd-y\": {}}}]") == [])

        let home = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-import-zk-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/keymap.json"
        #expect(ImportZed.keymapPlan(path, usKeyboard: true).skipped.isEmpty, "no file: nothing to say")
        for empty in ["", "// Zed keymap\n", "[]", "// nothing yet\n[\n]\n"] {
            try empty.write(toFile: path, atomically: true, encoding: .utf8)
            let plan = ImportZed.keymapPlan(path, usKeyboard: true)
            #expect(plan.shortcuts.isEmpty && plan.skipped.isEmpty, "\(empty.debugDescription)")
        }
        try "[{ \"bindings\": ".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ImportZed.keymapPlan(path, usKeyboard: true).skipped == [SkippedItem("keymap.json", "couldn't be read as JSON; your shortcuts were skipped")])
        #expect(mkfifo(home + "/pipe.json", 0o600) == 0)
        #expect(ImportZed.keymapPlan(home + "/pipe.json", usKeyboard: true).skipped.isEmpty, "a named pipe is never opened")
    }

    @Test func settledAgainstNextTermsKeys() throws {
        // Zed's own Duplicate Line key (⇧⌘D) is Split Down's outside the editor: shared, and the row says so.
        let plan = ImportPlan(preset: .nextTerm, shortcuts: try shortcuts(#"[{ "context": "Editor", "bindings": { "cmd-shift-d": "editor::DuplicateLineDown" } }]"#).shortcuts)
        let settled = plan.settlingShortcuts(current: ImportShortcutsTests.current())
        #expect(settled.shortcuts.first?.ticked == true)
        #expect(settled.shortcuts.first?.note == "⇧⌘D is Duplicate Line while the editor has the keyboard, Split Down everywhere else")
    }
}
