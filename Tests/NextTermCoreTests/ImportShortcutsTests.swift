import Foundation
import Testing
@testable import NextTermCore

/// The user's own shortcuts as preview rows: the keys no import takes, the command tables, and settling
/// rows against Next Term's shortcuts (the parsers are tested beside their importers).
@Suite struct ImportShortcutsTests {
    static func cmd(_ key: String, shift: Bool = false, option: Bool = false, control: Bool = false) -> KeyChord {
        KeyChord(key: key, command: true, shift: shift, option: option, control: control)
    }

    /// Next Term's menu shortcuts as `AppDelegate.buildMenu` sets them (nil: none), for settling rows the
    /// way the app does.
    static let menuDefaults: [String: KeyChord?] = {
        var map: [String: KeyChord?] = [
            "showSettings:": cmd(","), "hide:": cmd("h"), "hideOtherApplications:": cmd("h", option: true), "terminate:": cmd("q"),
            "newTab:": cmd("t"), "newWindow:": cmd("n"), "openProjectPanel:": cmd("o"), "goToFile:": cmd("p"),
            "resumeSession:": cmd("o", option: true), "closeProject:": nil, "saveDocument:": cmd("s"),
            "saveAllDocuments:": cmd("s", option: true), "splitRight:": cmd("d"), "splitDown:": cmd("d", shift: true),
            "renameTab:": cmd("r", option: true), "closeTab:": cmd("w"), "performClose:": cmd("w", shift: true),
            "undo:": cmd("z"), "redo:": cmd("z", shift: true), "cut:": cmd("x"), "copy:": cmd("c"), "paste:": cmd("v"), "selectAll:": cmd("a"),
            "performFindPanelAction:#1": cmd("f"), "replaceInFile:": cmd("f", option: true), "performFindPanelAction:#2": cmd("g"),
            "performFindPanelAction:#3": cmd("g", shift: true), "performFindPanelAction:#7": cmd("e"),
            "findInFiles:": cmd("f", shift: true), "replaceInFiles:": cmd("r", shift: true), "sendToAgent:": cmd("k", option: true),
            "goToLine:": cmd("l"), "toggleComment:": cmd("/"), "indentSelection:": cmd("]"), "outdentSelection:": cmd("["),
            "duplicateLine:": cmd("d"), "deleteLine:": cmd("k", shift: true), "moveLineUp:": cmd("\u{F700}", control: true),
            "moveLineDown:": cmd("\u{F701}", control: true), "copyPathWithLine:": nil,
            "clearBuffer:": cmd("k"), "toggleProjectSidebar:": cmd("b"), "toggleEditorFocus:": KeyChord(key: "`", control: true),
            "toggleTerminalCollapsed:": cmd("j"), "revealInSidebar:": nil, "showChanges:": cmd("g", option: true),
            "toggleSoftWrap:": nil, "toggleSidebarSide:": nil, "increaseFontSize:": cmd("+"), "decreaseFontSize:": cmd("-"),
            "resetFontSize:": cmd("0"), "toggleFullScreen:": cmd("f", control: true), "performMiniaturize:": cmd("m"),
            "showNextTab:": cmd("]", shift: true), "showPreviousTab:": cmd("[", shift: true),
            "selectPaneLeft:": cmd("\u{F702}", option: true), "selectPaneRight:": cmd("\u{F703}", option: true),
            "selectPaneAbove:": cmd("\u{F700}", option: true), "selectPaneBelow:": cmd("\u{F701}", option: true),
            "selectNextPane:": cmd("]", option: true), "selectPreviousPane:": cmd("[", option: true),
            "toggleZoomPane:": cmd("\r", shift: true), "equalizePanes:": nil,
        ]
        for n in 1...9 { map["selectTabByNumber:#\(n)"] = .some(cmd("\(n)")) }
        return map
    }()

    /// Every command's shortcut under `preset`, as `KeyboardShortcuts.chords(under:)` gives them.
    static func current(_ preset: KeymapPreset = .nextTerm, mine: [String: KeyChord?] = [:]) -> [String: KeyChord?] {
        var chords: [String: KeyChord?] = [:]
        for (id, chord) in menuDefaults { chords[id] = .some(mine[id] ?? preset.chord(for: id, default: chord)) }
        return chords
    }

    func row(_ command: String, _ chord: KeyChord?, removed: [KeyChord] = []) -> PlannedShortcut {
        ImportShortcuts.row(command, chord, source: "test: \(command)", removed: removed)
    }

    func settled(_ rows: [PlannedShortcut], _ preset: KeymapPreset = .nextTerm, aliases: [KeyChord: String] = [:]) -> ImportPlan {
        ImportPlan(preset: preset, shortcuts: rows).settlingShortcuts(current: Self.current(preset), aliases: aliases)
    }

    // MARK: keys no import takes

    @Test func controlKeysWithoutCommandStayWithTheShell() {
        for chord in [KeyChord(key: "r", control: true), KeyChord(key: "g", control: true), KeyChord(key: "`", control: true),
                      KeyChord(key: "-", shift: true, control: true), // ⌃_ as stored
                      KeyChord(key: "6", shift: true, control: true), // ⌃^
                      KeyChord(key: "/", control: true), KeyChord(key: " ", control: true),
                      KeyChord(key: "\u{F702}", control: true), KeyChord(key: "p", option: true, control: true)] {
            #expect(ImportShortcuts.isShellKey(chord), "\(chord.display)")
        }
        for chord in [Self.cmd("k"), Self.cmd("f", control: true), KeyChord(key: "\u{F705}", control: true), KeyChord(key: "\u{F708}")] {
            #expect(!ImportShortcuts.isShellKey(chord), "\(chord.display)")
        }
    }

    @Test func rowsForTheKeysNoImportTakes() {
        let shell = row("goToLine:", KeyChord(key: "g", control: true))
        #expect(!shell.ticked && !shell.allowed && shell.note == ImportShortcuts.shellNote)
        let spotlight = row("goToFile:", Self.cmd(" "))
        #expect(!spotlight.ticked && spotlight.allowed && spotlight.note?.contains("Spotlight") == true)
        #expect(!row("goToFile:", KeyChord(key: "\u{F70E}")).ticked) // F11, Show Desktop
        #expect(!row("goToFile:", KeyChord(key: "\u{F705}", control: true)).ticked) // ⌃F2, the menu bar
        let free = row("goToFile:", Self.cmd("t", option: true))
        #expect(free.ticked && free.allowed && free.note == nil && free.title == "Go to File…")
        // Taking a key away: ticked only when the other app named the key.
        #expect(row("closeTab:", nil, removed: [Self.cmd("w")]).ticked)
        let every = row("closeTab:", nil)
        #expect(!every.ticked && every.allowed && every.note == ImportShortcuts.everyKeyNote)
    }

    @Test func keysAMenuCantHold() {
        #expect(ImportShortcuts.unusable(KeyChord(key: "z", option: true)) != nil)
        #expect(ImportShortcuts.unusable(KeyChord(key: "\u{1B}", command: true)) != nil)
        #expect(ImportShortcuts.unusable(KeyChord(key: "p", shift: true)) != nil)
        #expect(ImportShortcuts.unusable(KeyChord(key: "\u{F708}")) == nil) // F5 alone
        #expect(ImportShortcuts.unusable(KeyChord(key: "g", control: true)) == nil) // usable, but the shell's
    }

    // MARK: the command tables

    @Test func everyMappedCommandIsANextTermCommand() {
        let titles = Set(ImportShortcuts.titles.keys)
        #expect(Set(ImportVSCode.commandMap.values).subtracting(titles).isEmpty)
        #expect(Set(ImportJetBrains.actionMap.values).subtracting(titles).isEmpty)
        #expect(ImportShortcuts.terminalCommands.subtracting(titles).isEmpty)
        // The same command ids the menus give (the self-test checks them against the real menus too).
        #expect(Set(Self.menuDefaults.keys).isSuperset(of: titles.filter { !$0.hasPrefix("setTerminalPosition:") }))
    }

    @Test func replaceInTheOpenFile() {
        #expect(ImportJetBrains.actionMap["Replace"] == "replaceInFile:" && ImportJetBrains.actionMap["ReplaceInPath"] == "replaceInFiles:")
        #expect(ImportVSCode.commandMap["editor.action.startFindReplaceAction"] == "replaceInFile:")
        // ⌥⌘F, as in VS Code; ⌘R under the JetBrains keys, as in their IDEs.
        let replace = Self.cmd("f", option: true)
        #expect(Self.current()["replaceInFile:"] == .some(replace) && Self.current(.vsCode)["replaceInFile:"] == .some(replace))
        #expect(Self.current(.jetBrains)["replaceInFile:"] == .some(Self.cmd("r")))
        // No other command has either key under any set.
        for preset in KeymapPreset.allCases {
            let chords = Self.current(preset)
            let key = chords["replaceInFile:"] ?? nil
            #expect(chords.filter { $0.key != "replaceInFile:" && $0.value == key }.isEmpty, "\(preset)")
        }
    }

    @Test func everyTitleIsAnActionInTheMenus() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NextTerm/AppDelegate.swift")
        let menus = try String(contentsOf: source, encoding: .utf8)
        for id in ImportShortcuts.titles.keys {
            let action = String(id.prefix { $0 != ":" })
            #expect(menus.contains("\(action)(_:)") || menus.contains("(\"\(action):\")"), "\(id)")
        }
    }

    @Test func theFilesHaveNoNetworking() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NextTermCore")
        for name in ["ImportShortcuts.swift", "ImportVSCodeKeys.swift", "ImportJetBrainsKeys.swift"] {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("URLSession") && !text.contains("import Network") && !text.contains("CFNetwork"), "\(name)")
            #expect(text.split(separator: "\n").filter { $0.hasPrefix("import ") } == ["import Foundation"], "\(name)")
        }
    }

    // MARK: settling against Next Term's shortcuts

    @Test func aRowThatChangesNothingGoes() {
        let plan = settled([row("goToFile:", Self.cmd("p")), row("goToLine:", Self.cmd("l", option: true))])
        #expect(plan.shortcuts.map(\.command) == ["goToLine:"])
        #expect(plan.skipped.isEmpty)
    }

    @Test func aKeyAnotherCommandHasIsLeftUnticked() {
        // ⌘T → Go to File: New Tab has ⌘T.
        let plan = settled([row("goToFile:", Self.cmd("t"))])
        let only = plan.shortcuts.first
        #expect(only?.ticked == false && only?.allowed == true)
        #expect(only?.note == "⌘T is New Tab’s here; tick to move it (New Tab is left without a shortcut)")
        // The app's own keys (⌘H, ⌘Q) count as well.
        #expect(settled([row("goToFile:", Self.cmd("h"))]).shortcuts.first?.ticked == false)
    }

    @Test func aKeyTheOtherPartHasIsShared() {
        // ⇧⌘D for Duplicate Line (a JetBrains keymap): Split Down keeps it outside the editor, and the row says so.
        let shared = settled([row("duplicateLine:", Self.cmd("d", shift: true))])
        #expect(shared.shortcuts.first?.ticked == true)
        #expect(shared.shortcuts.first?.note == "⇧⌘D is Duplicate Line while the editor has the keyboard, Split Down everywhere else")
        #expect(shared.settlingShortcuts(current: Self.current()) == shared)
        // Split Down onto ⌘D: Split Right's (a clash); Duplicate Line keeps ⌘D in the editor.
        let down = settled([row("splitDown:", Self.cmd("d"))]).shortcuts.first
        #expect(down?.ticked == false && down?.note == "⌘D is Split Right’s here; tick to move it (Split Right is left without a shortcut)")
        // A command for both parts on ⌘D clashes with both, and the row names both.
        let line = settled([row("goToLine:", Self.cmd("d"))]).shortcuts.first
        #expect(line?.ticked == false)
        #expect(line?.note == "⌘D is Duplicate Line’s and Split Right’s here; tick to move it (Duplicate Line and Split Right are left without a shortcut)")
        // Two rows on one key, one for each part: both stay ticked.
        let both = settled([row("duplicateLine:", Self.cmd("y")), row("splitRight:", Self.cmd("y"))])
        #expect(both.shortcuts.map(\.ticked) == [true, true])
    }

    @Test func swappingTwoKeysIsNoClash() {
        let plan = settled([row("goToFile:", Self.cmd("t")), row("newTab:", Self.cmd("p"))])
        #expect(plan.shortcuts.map(\.ticked) == [true, true])
    }

    @Test func twoRowsOnOneKeyTheFirstKeepsIt() {
        let plan = settled([row("goToLine:", Self.cmd("y")), row("goToFile:", Self.cmd("y"))])
        #expect(plan.shortcuts.map(\.ticked) == [true, false])
        #expect(plan.shortcuts[1].note == "Go to Line… gets ⌘Y in this import")
    }

    @Test func anUntickedRowCanMakeAnotherClash() {
        // Go to File takes ⌘T because New Tab moves… to a key macOS keeps, so New Tab stays on ⌘T after all.
        let plan = settled([row("goToFile:", Self.cmd("t")), row("newTab:", Self.cmd(" "))])
        #expect(plan.shortcuts.map(\.ticked) == [false, false])
        #expect(plan.shortcuts[0].note?.hasPrefix("⌘T is New Tab’s here") == true)
    }

    @Test func thePresetDecidesWhichKeysAreFree() {
        // ⌘P is free under the JetBrains keys (Go to File is ⇧⌘O there), and ⌘\ is Split Right's under both IDEs' keys.
        let jetBrains = settled([row("goToFile:", Self.cmd("p")), row("toggleProjectSidebar:", Self.cmd("\\"))], .jetBrains)
        #expect(jetBrains.shortcuts.map(\.ticked) == [true, false])
        let nextTerm = settled([row("goToFile:", Self.cmd("p")), row("toggleProjectSidebar:", Self.cmd("\\"))])
        #expect(nextTerm.shortcuts.map(\.command) == ["toggleProjectSidebar:"] && nextTerm.shortcuts[0].ticked)
    }

    @Test func removalsChangeOnlyTheKeyNextTermUses() {
        let plan = settled([
            row("closeTab:", nil, removed: [Self.cmd("w")]),                  // ⌘W is Close Tab here too: it goes
            row("goToLine:", nil, removed: [KeyChord(key: "g", control: true)]), // VS Code's ⌃G: Next Term's is ⌘L
            row("revealInSidebar:", nil, removed: [Self.cmd("r")]),          // no key here to take away
            row("splitRight:", nil),                                         // every key: offered, unticked
        ])
        #expect(plan.shortcuts.map(\.command) == ["closeTab:", "splitRight:"])
        #expect(plan.shortcuts.map(\.ticked) == [true, false])
        #expect(plan.skipped == [SkippedItem("test: goToLine:", "Go to Line… is on ⌘L here, so it keeps it")])
    }

    @Test func aHiddenItemsKeyCantBeMoved() {
        let plan = settled([row("toggleComment:", Self.cmd("="))], aliases: [Self.cmd("="): "increaseFontSize:"])
        #expect(plan.shortcuts.first?.allowed == false && plan.shortcuts.first?.note == "⌘= is also Bigger here")
    }

    @Test func aCommandThisVersionLacksIsReported() {
        let plan = ImportPlan(preset: .nextTerm, shortcuts: [row("goToFile:", Self.cmd("t", option: true))])
            .settlingShortcuts(current: ["newTab:": .some(Self.cmd("t"))])
        #expect(plan.shortcuts.isEmpty)
        #expect(plan.skipped == [SkippedItem("test: goToFile:", "no matching command in this version of Next Term")])
    }

    @Test func settlingTwiceChangesNothingMore() {
        let rows = [row("goToFile:", Self.cmd("t")), row("goToLine:", Self.cmd("l", option: true)), row("closeTab:", nil, removed: [Self.cmd("w")])]
        let once = settled(rows)
        #expect(once.settlingShortcuts(current: Self.current()) == once)
    }
}
