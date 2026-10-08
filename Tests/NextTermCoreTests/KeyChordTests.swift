import Foundation
import Testing
@testable import NextTermCore

@Suite struct KeyChordTests {
    @Test func displaysLikeMenus() {
        #expect(KeyChord(key: "t", command: true).display == "⌘T")
        #expect(KeyChord(key: "]", command: true, shift: true).display == "⇧⌘]")
        #expect(KeyChord(key: "`", control: true).display == "⌃`")
        #expect(KeyChord(key: "\u{F704}").display == "F1")
        #expect(KeyChord(key: "\u{8}", command: true).display == "⌘⌫")
        // An uppercase key equivalent means Shift, and is stored lowercase.
        #expect(KeyChord(key: "T", command: true) == KeyChord(key: "t", command: true, shift: true))
    }

    @Test func refusesShortcutsThatWouldEatTyping() {
        #expect(!KeyChord(key: "a").isUsable)
        #expect(!KeyChord(key: "a", shift: true).isUsable)
        #expect(!KeyChord(key: "a", option: true).isUsable) // ⌥A types å
        #expect(KeyChord(key: "a", control: true).isUsable)
        #expect(KeyChord(key: "\u{F705}").isUsable)        // F2
        #expect(!KeyChord(key: "\u{1B}", command: true).isUsable)
    }

    @Test func overridesResetsAndConflicts() {
        let newTab = KeyChord(key: "t", command: true), find = KeyChord(key: "f", command: true)
        let defaults: [String: KeyChord?] = ["newTab:": newTab, "find:": find, "clear:": nil]
        var bindings = KeyBindings()
        bindings.set(KeyChord(key: "n", command: true, option: true), for: "newTab:", default: newTab)
        #expect(bindings.chord(for: "newTab:", default: newTab) == KeyChord(key: "n", command: true, option: true))
        // Free now: ⌘T is nobody's; ⌘F still belongs to find.
        #expect(bindings.owner(of: newTab, defaults: defaults, except: "clear:") == nil)
        #expect(bindings.owner(of: find, defaults: defaults, except: "clear:") == "find:")
        bindings.set(nil, for: "find:", default: find) // removed
        #expect(bindings.chord(for: "find:", default: find) == nil)
        // Saved and read back.
        #expect(KeyBindings.decode(bindings.encoded()) == bindings)
        // Back to the default forgets the override.
        bindings.set(newTab, for: "newTab:", default: newTab)
        #expect(bindings.overrides["newTab:"] == nil)
        bindings.resetAll()
        #expect(bindings.overrides.isEmpty)
    }

    @Test func anEditorCommandAndATerminalCommandShareAKey() {
        let d = KeyChord(key: "d", command: true), shiftD = KeyChord(key: "d", command: true, shift: true)
        let defaults: [String: KeyChord?] = ["splitRight:": d, "splitDown:": shiftD, "duplicateLine:": d, "goToLine:": KeyChord(key: "l", command: true),
                                             "deleteLine:": KeyChord(key: "k", command: true, shift: true), "copyPathWithLine:": nil]
        var bindings = KeyBindings()
        // ⌘D: Duplicate Line in the editor, Split Right elsewhere. Neither is in the other's way.
        #expect(bindings.owners(of: d, defaults: defaults, except: "duplicateLine:").isEmpty)
        #expect(bindings.owners(of: d, defaults: defaults, except: "splitRight:").isEmpty)
        #expect(bindings.sharer(of: d, defaults: defaults, except: "duplicateLine:") == "splitRight:")
        #expect(bindings.sharer(of: d, defaults: defaults, except: "splitRight:") == "duplicateLine:")
        // A command for both parts clashes with both of them.
        #expect(bindings.owners(of: d, defaults: defaults, except: "goToLine:") == ["duplicateLine:", "splitRight:"])
        // So do two terminal commands, and two editor commands.
        #expect(bindings.owners(of: d, defaults: defaults, except: "splitDown:") == ["splitRight:"])
        #expect(bindings.owners(of: d, defaults: defaults, except: "deleteLine:") == ["duplicateLine:"])
        #expect(bindings.owner(of: shiftD, defaults: defaults, except: "duplicateLine:") == nil)
        // Another key for either one: each keeps its own.
        bindings.set(KeyChord(key: "\\", command: true), for: "splitRight:", default: d)
        #expect(bindings.sharer(of: d, defaults: defaults, except: "duplicateLine:") == nil)
        #expect(bindings.owners(of: d, defaults: defaults, except: "goToLine:") == ["duplicateLine:"])
        #expect(KeyBindings.canShareKey("copyPathWithLine:", "clearBuffer:") && !KeyBindings.canShareKey("splitRight:", "splitDown:"))
        #expect(!KeyBindings.canShareKey("duplicateLine:", "performFindPanelAction:#1"))
    }

    @Test func keysOutsideTheMenusBelongToAPartOfTheWindow() {
        let commands = KeyBindings.partCommands
        let ids = commands.map(\.id)
        #expect(Set(ids).count == ids.count)
        func chord(_ id: String) -> KeyChord? { commands.first { $0.id == id }?.chord }
        // Today's keys are the defaults.
        #expect(chord("diff.accept")?.display == "⌘↩" && chord("sidebar.rename")?.display == "↩")
        #expect(chord("sidebar.trash")?.display == "⌘⌫" && chord("sidebar.open")?.display == "⌘↓" && chord("gitLists.open")?.display == "↩")
        #expect(["branchPopup.fetch", "branchPopup.copyName", "branchPopup.delete", "branchPopup.newBranch"].compactMap { chord($0)?.display }
            == ["⌘R", "⌘C", "⌘⌫", "⌘↩"])
        #expect(KeyBindings.scope(of: "sidebar.trash") == .part(.sidebar) && KeyBindings.scope(of: "duplicateLine:") == .part(.editor))
        #expect(KeyBindings.scope(of: "splitRight:") == .terminal && KeyBindings.scope(of: "newTab:") == .everywhere)
        // No two commands of one part start on one key, and no default clashes with another.
        let defaults = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, Optional($0.chord)) })
            .merging(["copy:": KeyChord(key: "c", command: true), "deleteLine:": KeyChord(key: "\u{8}", command: true)]) { first, _ in first }
        let bindings = KeyBindings()
        for command in commands {
            #expect(bindings.owners(of: command.chord, defaults: defaults, except: command.id).isEmpty, "\(command.id)")
        }
    }

    @Test func aKeyBelongsToOneCommandPerPart() {
        let returnKey = KeyChord(key: "\r"), commandReturn = KeyChord(key: "\r", command: true)
        let defaults: [String: KeyChord?] = ["sidebar.rename": returnKey, "gitLists.open": returnKey, "diff.accept": commandReturn,
                                             "branchPopup.newBranch": commandReturn, "toggleZoomPane:": KeyChord(key: "\r", command: true, shift: true),
                                             "sidebar.open": KeyChord(key: "\u{F701}", command: true), "newTab:": KeyChord(key: "t", command: true)]
        let bindings = KeyBindings()
        // Two parts share ↩ and ⌘↩.
        #expect(bindings.owners(of: returnKey, defaults: defaults, except: "sidebar.rename").isEmpty)
        #expect(bindings.sharers(of: returnKey, defaults: defaults, except: "sidebar.rename") == ["gitLists.open"])
        #expect(bindings.owners(of: commandReturn, defaults: defaults, except: "diff.accept").isEmpty)
        // A second command in the same part clashes, and so does a command for everywhere (but not with the branch popup's).
        #expect(bindings.owners(of: returnKey, defaults: defaults, except: "sidebar.open") == ["sidebar.rename"])
        #expect(bindings.owners(of: commandReturn, defaults: defaults, except: "newTab:") == ["diff.accept"])
        // A part's key and a terminal command's share; the branch popup, which has the keyboard while it is open, shares with anything.
        #expect(KeyBindings.canShareKey("sidebar.trash", "clearBuffer:") && KeyBindings.canShareKey("toggleZoomPane:", "diff.accept"))
        #expect(KeyBindings.canShareKey("branchPopup.copyName", "copy:") && !KeyBindings.canShareKey("sidebar.trash", "copy:"))
        #expect(!KeyBindings.canShareKey("branchPopup.fetch", "branchPopup.delete") && KeyBindings.canShareKey("deleteLine:", "sidebar.trash"))
        // Accept answers wherever the keyboard is in the window while a proposed edit shows, the sidebar beside it.
        #expect(!KeyBindings.canShareKey("diff.accept", "sidebar.open") && !KeyBindings.canShareKey("sidebar.rename", "diff.accept"))
        #expect(KeyBindings.canShareKey("diff.accept", "gitLists.open") && KeyBindings.canShareKey("diff.accept", "duplicateLine:"))
        #expect(bindings.owners(of: commandReturn, defaults: defaults.merging(["sidebar.open": commandReturn]) { _, new in new }, except: "diff.accept")
            == ["sidebar.open"])
        // What Settings says about a shared key.
        let titles = ["duplicateLine:": "Duplicate Line", "splitRight:": "Split Right", "sidebar.trash": "Move to Trash", "deleteLine:": "Delete Line",
                      "branchPopup.copyName": "Copy Name", "copy:": "Copy"]
        func title(_ id: String) -> String { titles[id] ?? id }
        #expect(KeyBindings.sharingNote(KeyChord(key: "d", command: true), ["splitRight:", "duplicateLine:"], title: title)
            == "⌘D is Duplicate Line while the editor has the keyboard, Split Right everywhere else")
        #expect(KeyBindings.sharingNote(KeyChord(key: "\u{8}", command: true), ["sidebar.trash", "deleteLine:"], title: title)
            == "⌘⌫ is Delete Line while the editor has the keyboard, Move to Trash while the project sidebar has the keyboard")
        #expect(KeyBindings.sharingNote(KeyChord(key: "c", command: true), ["copy:", "branchPopup.copyName"], title: title)
            == "⌘C is Copy Name while the branch popup is open, Copy everywhere else")
    }

    @Test func aPartWithoutTypingTakesPlainKeys() {
        // ↩, ⌫ and ⌦ alone in the sidebar and the Git lists, where nothing is typed; never in the menus.
        #expect(KeyBindings.isUsable(KeyChord(key: "\r"), for: "sidebar.rename") && KeyBindings.isUsable(KeyChord(key: "\u{F728}"), for: "sidebar.trash"))
        #expect(KeyBindings.isUsable(KeyChord(key: "\r", shift: true), for: "gitLists.open"))
        #expect(!KeyBindings.isUsable(KeyChord(key: "r"), for: "sidebar.rename") && !KeyBindings.isUsable(KeyChord(key: "\r"), for: "newTab:"))
        // The proposed edit's Accept answers wherever the keyboard is in the window, and the branch popup has a search field.
        #expect(!KeyBindings.isUsable(KeyChord(key: "\r"), for: "diff.accept") && !KeyBindings.isUsable(KeyChord(key: "\u{8}"), for: "branchPopup.delete"))
        #expect(KeyBindings.isUsable(KeyChord(key: "\r", command: true), for: "diff.accept"))
    }
}
