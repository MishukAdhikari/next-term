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
}
