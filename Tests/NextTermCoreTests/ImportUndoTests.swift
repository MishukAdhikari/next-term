import Foundation
import Testing
@testable import NextTermCore

/// Undo Import's snapshot: an Apply that changes nothing keeps the earlier Undo, and Undo can name what was
/// changed by hand since. Only a test suite of UserDefaults is used, never Next Term's own.
@Suite struct ImportUndoTests {
    typealias Value = ImportSnapshot.Value

    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let (defaults, name) = try TestDefaults.make("import-undo-tests")
        defer { TestDefaults.remove(defaults, name) }
        try body(defaults)
    }

    func bindings(_ pairs: [(String, KeyChord?)]) -> Data {
        var overrides: [String: KeyChord?] = [:]
        for (id, chord) in pairs { overrides.updateValue(chord, forKey: id) }
        return KeyBindings(overrides: overrides).encoded()
    }

    @Test func readsEachKindOfValue() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "softWrap")
            defaults.set(15.0, forKey: "fontSize")
            defaults.set(3_000, forKey: "terminalScrollback")
            defaults.set("vsCode", forKey: "keymapPreset")
            defaults.set(["*.log"], forKey: "hiddenFilePatterns")
            defaults.set(Data([1, 2]), forKey: "terminalPalette")
            let keys = ["softWrap", "fontSize", "terminalScrollback", "keymapPreset", "hiddenFilePatterns", "terminalPalette", "editorFontFamily"]
            let values = ImportSnapshot.values(of: keys, in: defaults)
            // Typed apart from the #expect, so the literal type-checks quickly on older compilers.
            var expected: [String: Value] = ["softWrap": .bool(true), "fontSize": .double(15), "terminalScrollback": .double(3_000)]
            expected["keymapPreset"] = .string("vsCode")
            expected["hiddenFilePatterns"] = .strings(["*.log"])
            expected["terminalPalette"] = .data(Data([1, 2]))
            #expect(values == expected)
        }
    }

    /// The same saved shortcuts with their keys in the given order.
    func reordered(_ data: Data, reversed: Bool) throws -> Data {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sortedKeys = object.keys.sorted()
        let keys = reversed ? Array(sortedKeys.reversed()) : sortedKeys
        var members: [String] = []
        for key in keys {
            let value = try JSONSerialization.data(withJSONObject: object[key] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
            members.append("\"\(key)\":" + String(decoding: value, as: UTF8.self))
        }
        return Data(("{" + members.joined(separator: ",") + "}").utf8)
    }

    @Test func anApplyThatChangesNothingMakesNoSnapshot() throws {
        let before: [String: Value] = ["fontSize": .double(14), "softWrap": .bool(true)]
        #expect(ImportSnapshot.applied(keys: ["fontSize", "softWrap", "recentProjects"], before: before, after: before,
                                       source: "Cursor", summary: "2 settings") == nil)
        // The same shortcuts saved in another order are the same shortcuts.
        let one = bindings([("goToFile:", KeyChord(key: "p", command: true, option: true)), ("goToLine:", nil), ("saveDocument:", KeyChord(key: "s", command: true))])
        let sorted = try reordered(one, reversed: false), other = try reordered(one, reversed: true)
        #expect(sorted != other) // one of them is in another order than `one`
        #expect(KeyBindings.decode(other) == KeyBindings.decode(one) && KeyBindings.decode(one).overrides.count == 3)
        #expect(ImportSnapshot.same("keyBindings", .data(one), .data(sorted)) && ImportSnapshot.same("keyBindings", .data(one), .data(other)))
        #expect(ImportSnapshot.applied(keys: ["keyBindings"], before: ["keyBindings": .data(one)], after: ["keyBindings": .data(other)],
                                       source: "Cursor", summary: "") == nil)
        #expect(!ImportSnapshot.same("keyBindings", .data(one), .data(bindings([("goToLine:", nil)]))))
        #expect(!ImportSnapshot.same("terminalPalette", .data(Data([1])), .data(Data([2]))))
    }

    @Test func aSnapshotHoldsOnlyWhatChanged() throws {
        let before: [String: Value] = ["fontSize": .double(14), "softWrap": .bool(true)]
        let after: [String: Value] = ["fontSize": .double(16), "softWrap": .bool(true), "editorFontFamily": .string("Menlo")]
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try #require(ImportSnapshot.applied(keys: ["fontSize", "softWrap", "editorFontFamily"], before: before, after: after,
                                                           source: "Cursor", summary: "3 settings", date: date))
        #expect(snapshot.touched == ["fontSize", "editorFontFamily"])
        #expect(snapshot.before == ["fontSize": .double(14)]) // the font had none before
        let expectedAfter: [String: Value] = ["fontSize": .double(16), "editorFontFamily": .string("Menlo")]
        #expect(snapshot.after == expectedAfter)
        #expect(snapshot.source == "Cursor" && snapshot.summary == "3 settings" && snapshot.date == date)
        #expect(snapshot.id?.isEmpty == false)
        let next = try #require(ImportSnapshot.applied(keys: ["fontSize"], before: before, after: after, source: "Zed", summary: ""))
        #expect(next.id != snapshot.id)
    }

    @Test func undoNamesWhatChangedSinceTheImport() throws {
        let snapshot = ImportSnapshot(source: "Cursor", summary: "", before: ["fontSize": .double(14)],
                                      touched: ["fontSize", "terminalPalette", "customTerminalPalette", "editorFontFamily"],
                                      after: ["fontSize": .double(16), "terminalPalette": .data(Data([1])), "customTerminalPalette": .data(Data([1])),
                                              "editorFontFamily": .string("Menlo")])
        let unchanged: [String: Value] = ["fontSize": .double(16), "terminalPalette": .data(Data([1])),
                                           "customTerminalPalette": .data(Data([1])), "editorFontFamily": .string("Menlo")]
        #expect(snapshot.changedSince(unchanged).isEmpty)
        var current = unchanged
        current["fontSize"] = .double(18)
        current["terminalPalette"] = .data(Data([2]))
        current["customTerminalPalette"] = .data(Data([2]))
        current["editorFontFamily"] = nil // back to Next Term's font
        let changed = snapshot.changedSince(current)
        let expected: [String] = ["fontSize", "terminalPalette", "customTerminalPalette", "editorFontFamily"]
        #expect(changed == expected)
        #expect(ImportSnapshot.titles(of: changed) == ["Font size", "Terminal colours", "Editor font"])
        // A snapshot from before 0.11 has no values after, so it can't say.
        let old = ImportSnapshot(source: "Cursor", summary: "", before: [:], touched: ["fontSize"], after: nil)
        #expect(old.changedSince(current).isEmpty)
    }

    @Test func snapshotsSavedBeforeStillRead() throws {
        // As 0.10 saved one: no `after`, no `id`.
        let saved = #"{"date":800000000,"source":"Cursor","summary":"2 settings","before":{"fontSize":{"double":{"_0":14}},"#
            + #""softWrap":{"bool":{"_0":true}}},"touched":["fontSize","softWrap","editorFontFamily"]}"#
        let snapshot = try JSONDecoder().decode(ImportSnapshot.self, from: Data(saved.utf8))
        #expect(snapshot.before == ["fontSize": .double(14), "softWrap": .bool(true)])
        #expect(snapshot.touched == ["fontSize", "softWrap", "editorFontFamily"] && snapshot.after == nil && snapshot.id == nil)
        // And a new one comes back as it was.
        let new = ImportSnapshot(source: "Zed", summary: "1 setting", before: ["keyBindings": .data(Data([7]))], touched: ["keyBindings"],
                                 after: ["keyBindings": .data(Data([8]))])
        #expect(try JSONDecoder().decode(ImportSnapshot.self, from: JSONEncoder().encode(new)) == new)
    }

    /// Opening a project reorders and extends the recent projects: that is not a change since the import, and Undo
    /// takes back only the folders the import added, keeping the ones opened since.
    @Test func recentProjectsAreTakenBackNotPutBack() throws {
        let before: [String] = ["/p/own-1", "/p/own-2"]
        let after: [String] = before + ["/p/imported-1", "/p/imported-2"]
        let snapshot = try #require(ImportSnapshot.applied(keys: ["recentProjects", "fontSize"],
                                                          before: ["recentProjects": .strings(before), "fontSize": .double(13)],
                                                          after: ["recentProjects": .strings(after), "fontSize": .double(15)],
                                                          source: "Zed", summary: "2 projects, 1 setting"))
        // Since the import, a project was opened (it goes first) and one imported project was opened again.
        let current: [String] = ["/p/new", "/p/imported-2", "/p/own-1", "/p/own-2", "/p/imported-1"]
        let changed = snapshot.changedSince(["recentProjects": .strings(current), "fontSize": .double(15)])
        #expect(changed.isEmpty)
        #expect(snapshot.changedSince(["recentProjects": .strings(current), "fontSize": .double(16)]) == ["fontSize"])
        let undone: [String] = snapshot.recentProjectsAfterUndo(current: current)
        let expected: [String] = ["/p/new", "/p/own-1", "/p/own-2"]
        #expect(undone == expected)
        // A project the user removed since stays removed.
        let removed: [String] = snapshot.recentProjectsAfterUndo(current: ["/p/own-2", "/p/imported-1"])
        let left: [String] = ["/p/own-2"]
        #expect(removed == left)
        // A snapshot saved before `after` existed puts the list back as it was.
        let older = ImportSnapshot(id: nil, source: "Zed", summary: "", before: ["recentProjects": .strings(before)],
                                   touched: ["recentProjects"], after: nil)
        #expect(older.recentProjectsAfterUndo(current: current) == before)
    }

    @Test func everyImportedSettingHasATitle() {
        let settings: [ImportedSetting] = [
            .fontSize(13), .terminalFontSize(13), .editorLineHeight(1.2), .softWrap(true), .optionAsMeta(true), .terminalPosition("bottom"), .sidebarSide("left"),
            .editorFontFamily("Menlo"), .terminalFontFamily("Menlo"), .terminalPalette(TerminalPalette(name: "x")), .terminalScrollback(1_000),
            .terminalStartFolder("project"), .terminalCursorShape("bar"), .terminalCursorBlink(true), .trimTrailingWhitespace(true),
            .insertFinalNewline(true), .hiddenFiles([]), .tabList(TabListImport(tabs: "left", sidebarSide: "right", showsFolders: true)),
        ]
        let keys = settings.flatMap(\.keys) + ["keymapPreset", "keyBindings", "recentProjects"]
        for key in keys { #expect(ImportSnapshot.title(of: key) != key, "\(key)") }
    }

    // MARK: the tab list row

    /// One row writes the tabs' side, and the sidebar's and Show Folders when it names them, so Apply keeps each for
    /// Undo; Undo names them as Settings does.
    @Test func theTabListRowKeepsEveryKeyItWrites() {
        let every = ImportedSetting.tabList(TabListImport(tabs: "left", sidebarSide: "right", showsFolders: true))
        let expected: [String] = ["terminalTabs", "sidebarSide", "tabListShowsFolders"]
        #expect(every.key == "terminalTabs" && every.keys == expected)
        #expect(ImportedSetting.tabList(TabListImport(tabs: "left")).keys == ["terminalTabs"])
        #expect(ImportedSetting.tabList(TabListImport(tabs: "right", showsFolders: false)).keys == ["terminalTabs", "tabListShowsFolders"])
        #expect(ImportSnapshot.title(of: "terminalTabs") == "Terminal tabs")
        #expect(ImportSnapshot.title(of: "tabListShowsFolders") == "Folders in the tab list")
        #expect(ImportedSetting.boolKeys.contains("tabListShowsFolders"))
    }

    /// Show Folders is kept as a Bool, so Undo puts back a Bool and not a number.
    @Test func showFoldersReadsBackAsABool() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "tabListShowsFolders")
            defaults.set("left", forKey: "terminalTabs")
            let values = ImportSnapshot.values(of: ["tabListShowsFolders", "terminalTabs"], in: defaults)
            let expected: [String: Value] = ["tabListShowsFolders": .bool(true), "terminalTabs": .string("left")]
            #expect(values == expected)
        }
    }

    /// The tabs moved back to the top by hand since the import: Undo's alert names them.
    @Test func undoNamesTheTerminalTabsChangedSince() {
        let before: [String: Value] = ["sidebarSide": .string("left")]
        let after: [String: Value] = ["terminalTabs": .string("left"), "sidebarSide": .string("right"), "tabListShowsFolders": .bool(true)]
        let keys: [String] = ["terminalTabs", "sidebarSide", "tabListShowsFolders"]
        let snapshot = ImportSnapshot.applied(keys: keys, before: before, after: after, source: "Terminal", summary: "1 setting")
        #expect(snapshot?.touched == keys)
        var current = after
        current["terminalTabs"] = .string("top")
        let changed: [String] = snapshot?.changedSince(current) ?? []
        #expect(ImportSnapshot.titles(of: changed) == ["Terminal tabs"])
    }
}
