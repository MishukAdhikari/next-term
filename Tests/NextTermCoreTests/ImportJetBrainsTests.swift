import Foundation
import Testing
@testable import NextTermCore

/// Fixtures are written the way the IDEs write them (shapes copied from PhpStorm 2026.1 and Android Studio
/// 2025.3 on a real Mac), always into a temporary home.
@Suite struct ImportJetBrainsTests {
    var fm: FileManager { .default }

    func home() throws -> String {
        // Short: a long folder name in the path would trip the secret guard's long-token pattern.
        let dir = canonicalPath(fm.temporaryDirectory.path) + "/nt-jb-" + UUID().uuidString.prefix(8)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, to path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A settings folder with `options/` (and one settings file, so it has a last-used date).
    @discardableResult
    func ide(_ home: String, _ name: String, vendor: String = "JetBrains", usedDaysAgo: Double? = 0) throws -> String {
        let config = home + "/Library/Application Support/\(vendor)/\(name)"
        try fm.createDirectory(atPath: config + "/options", withIntermediateDirectories: true)
        if let days = usedDaysAgo {
            try write("<application />", to: config + "/options/ide.general.xml")
            try touch(config + "/options/ide.general.xml", daysAgo: days)
        }
        return config
    }

    func touch(_ path: String, daysAgo: Double) throws {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86400)], ofItemAtPath: path)
    }

    func folder(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func app(_ config: String, preset: KeymapPreset? = nil) -> DetectedApp {
        DetectedApp(kind: .jetBrains, name: "PhpStorm 2026.1", configPath: config, lastUsed: nil, preset: preset)
    }

    func component(_ name: String, _ options: [(String, String)]) -> String {
        let lines = options.map { "    <option name=\"\($0.0)\" value=\"\($0.1)\" />" }.joined(separator: "\n")
        return "<application>\n  <component name=\"\(name)\">\n\(lines)\n  </component>\n</application>"
    }

    func keymapChoice(_ name: String) -> String {
        "<application>\n  <component name=\"KeymapManager\">\n    <active_keymap name=\"\(name)\" />\n  </component>\n</application>"
    }

    func customKeymap(_ name: String, parent: String?, actions: [String]) -> String {
        let parentAttribute = parent.map { " parent=\"\($0)\"" } ?? ""
        let body = actions.map { "  <action id=\"\($0)\">\n    <keyboard-shortcut first-keystroke=\"meta shift D\" />\n  </action>" }
        return (["<keymap version=\"1\" name=\"\(name)\"\(parentAttribute)>"] + body + ["</keymap>"]).joined(separator: "\n")
    }

    struct Entry {
        var key: String
        var activation: Int64? = nil
        var opened: Int64? = nil
        var hidden = false
    }

    func recents(_ entries: [Entry]) -> String {
        let items = entries.map { entry -> String in
            var options = ["<option name=\"binFolder\" value=\"$APPLICATION_HOME_DIR$/bin\" />",
                           "<option name=\"build\" value=\"PS-261.22158.282\" />"]
            if let stamp = entry.activation { options.insert("<option name=\"activationTimestamp\" value=\"\(stamp)\" />", at: 0) }
            if let stamp = entry.opened { options.append("<option name=\"projectOpenTimestamp\" value=\"\(stamp)\" />") }
            return """
                    <entry key="\(entry.key)">
                      <value>
                        <RecentProjectMetaInfo frameTitle="x"\(entry.hidden ? " hidden=\"true\"" : "") projectWorkspaceId="2g9hnFP1fGCoTG6VFo1caQotQ13">
                          \(options.joined(separator: "\n              "))
                          <frame x="0" y="0" width="1680" height="1050" />
                        </RecentProjectMetaInfo>
                      </value>
                    </entry>
            """
        }
        return """
            <application>
              <component name="RecentProjectsManager">
                <option name="additionalInfo">
                  <map>
            \(items.joined(separator: "\n"))
                  </map>
                </option>
                <option name="lastOpenedProject" value="$USER_HOME$/Code/a" />
              </component>
            </application>
            """
    }

    // MARK: Detection

    @Test func findsTheNewestVersionOfEachIDE() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        try ide(home, "PhpStorm2025.3", usedDaysAgo: 10)
        let phpStorm = try ide(home, "PhpStorm2026.1", usedDaysAgo: 5)
        // The newest options/*.xml is the last use; other files and folders in options/ don't count.
        try write("<application />", to: phpStorm + "/options/recentProjects.xml")
        try touch(phpStorm + "/options/recentProjects.xml", daysAgo: 1)
        try write("notes", to: phpStorm + "/options/notes.txt")
        try folder(phpStorm + "/options/mac")
        try ide(home, "PhpStormLight2026.2")           // LightEdit mode
        try ide(home, "Phpstorm")                      // no version
        try ide(home, "Daemon")
        try ide(home, "consentOptions")
        try ide(home, "acp-agents")
        try ide(home, "JetBrainsGateway2025.2")
        try folder(home + "/Library/Application Support/JetBrains/WebStorm2025.2/plugins") // no options/
        try ide(home, "IntelliJIdea2024.1", usedDaysAgo: 200) // unused for 180+ days
        let studio = try ide(home, "AndroidStudio2025.3.4", vendor: "Google", usedDaysAgo: 3)
        try ide(home, "Chrome1.2", vendor: "Google")

        let found = ImportJetBrains.detect(home: home)
        #expect(found.map(\.name) == ["PhpStorm 2026.1", "Android Studio 2025.3.4"])
        #expect(found.map(\.configPath) == [phpStorm, studio])
        #expect(found.allSatisfy { $0.kind == .jetBrains && $0.preset == .jetBrains })
        let recentProjectsDate = try fm.attributesOfItem(atPath: phpStorm + "/options/recentProjects.xml")[.modificationDate] as? Date
        #expect(found.first?.lastUsed == recentProjectsDate)
    }

    @Test func unusedIDEsShowWhenNothingElseIsFound() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        try ide(home, "PhpStorm2023.1", usedDaysAgo: 300)
        try ide(home, "IntelliJIdea2024.1", usedDaysAgo: 200)
        try ide(home, "IdeaIC2022.1", usedDaysAgo: nil) // options/ but never saved a setting
        #expect(ImportJetBrains.detect(home: home).map(\.name) == ["IntelliJ IDEA 2024.1", "PhpStorm 2023.1", "IntelliJ IDEA CE 2022.1"])
        #expect(ImportJetBrains.detect(home: home + "/nowhere").isEmpty)
    }

    @Test func aRecentlyUsedVersionWinsOverAnAbandonedNewerOne() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        try ide(home, "PhpStorm2026.2", usedDaysAgo: 200)
        try ide(home, "PhpStorm2026.1", usedDaysAgo: 1)
        // Versions compare as numbers: 2025.10 is newer than 2025.9.
        try ide(home, "PyCharm2025.9", usedDaysAgo: 1)
        try ide(home, "PyCharm2025.10", usedDaysAgo: 2)
        #expect(Set(ImportJetBrains.detect(home: home).map(\.name)) == ["PhpStorm 2026.1", "PyCharm 2025.10"])
    }

    @Test func folderNames() {
        #expect(ImportJetBrains.splitVersion("PhpStorm2026.1")?.product == "PhpStorm")
        #expect(ImportJetBrains.splitVersion("AndroidStudio2025.3.4")?.version == [2025, 3, 4])
        #expect(ImportJetBrains.splitVersion("Phpstorm") == nil)
        #expect(ImportJetBrains.splitVersion("PhpStorm2026") == nil)
        #expect(ImportJetBrains.splitVersion("2026.1") == nil)
    }

    // MARK: Keymaps

    /// The preset `detect` gives a PhpStorm whose keymap files are `files`, the keymap notes a plan adds, and
    /// the user's own shortcuts it found.
    func keymapResult(_ files: [String: String]) throws -> (preset: KeymapPreset?, notes: [SkippedItem], shortcuts: [PlannedShortcut]) {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = try ide(home, "PhpStorm2026.1")
        for (path, text) in files { try write(text, to: config + "/" + path) }
        let preset = ImportJetBrains.detect(home: home).first?.preset
        let plan = ImportJetBrains.plan(for: app(config), home: home)
        let notes = plan.skipped.filter { $0.item.contains("Keymap") || $0.item.contains("Classic") }
        return (preset, notes, plan.shortcuts)
    }

    @Test func keymapsChooseThePreset() throws {
        // Never chosen: JetBrains' macOS keymap.
        var result = try keymapResult([:])
        #expect(result.preset == .jetBrains && result.notes.isEmpty)

        result = try keymapResult(["options/mac/keymap.xml": keymapChoice("Mac OS X 10.5+")])
        #expect(result.preset == .jetBrains && result.notes.isEmpty)

        result = try keymapResult(["options/mac/keymap.xml": keymapChoice("VSCode OSX")])
        #expect(result.preset == .vsCode && result.notes.isEmpty)

        // Older IDEs keep the choice in options/keymap.xml; options/mac/ wins when both exist.
        result = try keymapResult(["options/keymap.xml": keymapChoice("VSCode")])
        #expect(result.preset == .vsCode)
        result = try keymapResult(["options/keymap.xml": keymapChoice("VSCode"), "options/mac/keymap.xml": keymapChoice("Mac OS X 10.5+")])
        #expect(result.preset == .jetBrains)
    }

    @Test func customKeymapsFollowTheirParents() throws {
        // The user's own keymap (as on this Mac): the JetBrains preset, and its changes as rows.
        var result = try keymapResult([
            "options/mac/keymap.xml": keymapChoice("macOS - Mishuk"),
            "keymaps/macOS - Mishuk.xml": customKeymap("macOS - Mishuk", parent: "Mac OS X 10.5+", actions: ["GotoFile", "EditorDuplicate", "SaveAll"]),
        ])
        #expect(result.preset == .jetBrains && result.notes.isEmpty)
        #expect(result.shortcuts.map(\.command) == ["goToFile:", "saveAllDocuments:"])

        // A custom keymap on VS Code's, found by the name inside the file (the file name was made safe).
        result = try keymapResult([
            "options/mac/keymap.xml": keymapChoice("Work / VS Code"),
            "keymaps/Work _ VS Code.xml": customKeymap("Work / VS Code", parent: "VSCode OSX", actions: ["GotoFile"]),
        ])
        #expect(result.preset == .vsCode && result.notes.isEmpty)
        #expect(result.shortcuts.map(\.source) == ["“Work / VS Code”: GotoFile meta shift D"])

        // Two levels down to IntelliJ IDEA Classic: an action both set comes from the nearer keymap.
        result = try keymapResult([
            "options/mac/keymap.xml": keymapChoice("Mine 2"),
            "keymaps/Mine 2.xml": customKeymap("Mine 2", parent: "Mine", actions: ["GotoFile", "SaveAll"]),
            "keymaps/Mine.xml": customKeymap("Mine", parent: "Mac OS X", actions: ["GotoFile", "Find"]),
        ])
        #expect(result.preset == .jetBrains)
        #expect(result.notes.map(\.item) == ["IntelliJ IDEA Classic keys"])
        #expect(result.shortcuts.map(\.command) == ["goToFile:", "saveAllDocuments:", "performFindPanelAction:#1"])
        #expect(result.shortcuts.first?.source == "“Mine 2”: GotoFile meta shift D")

        // A custom keymap that isn't the active one isn't read.
        result = try keymapResult([
            "options/mac/keymap.xml": keymapChoice("Mac OS X 10.5+"),
            "keymaps/Old.xml": customKeymap("Old", parent: "Mac OS X 10.5+", actions: ["GotoFile"]),
        ])
        #expect(result.shortcuts.isEmpty)
    }

    /// Shaped like the custom keymap on a real Mac: the IDE writes every shortcut an action has, and an empty
    /// element for an action left with none.
    static let ownKeymap = """
        <keymap version="1" name="macOS - Mishuk" parent="Mac OS X 10.5+">
          <action id="ActivateTerminalToolWindow">
            <keyboard-shortcut first-keystroke="meta T" />
          </action>
          <action id="CloseContent" />
          <action id="EditorDuplicate">
            <keyboard-shortcut first-keystroke="meta shift D" />
          </action>
          <action id="FindInPath">
            <keyboard-shortcut first-keystroke="meta shift F" />
            <mouse-shortcut keystroke="meta button2" />
          </action>
          <action id="GotoFile">
            <keyboard-shortcut first-keystroke="meta P" />
          </action>
          <action id="GotoLine">
            <keyboard-shortcut first-keystroke="control G" />
          </action>
          <action id="NextTab">
            <keyboard-shortcut first-keystroke="control RIGHT" />
            <keyboard-shortcut first-keystroke="meta shift CLOSE_BRACKET" />
          </action>
          <action id="ParameterInfo" />
          <action id="SaveAll">
            <keyboard-shortcut first-keystroke="meta K" second-keystroke="meta S" />
          </action>
          <action id="SelectNextOccurrence">
            <keyboard-shortcut first-keystroke="meta D" />
          </action>
          <action id="SplitVertically">
            <keyboard-shortcut first-keystroke="meta BACK_SLASH" />
          </action>
          <action id="GotoAction">
            <keyboard-gesture-shortcut keystroke="shift" modifier="dblClick" />
          </action>
          <action id="EditorToggleUseSoftWraps">
            <keyboard-shortcut first-keystroke="alt Z" />
          </action>
          <action id="ShowSettings">
            <keyboard-shortcut first-keystroke="meta NUMPAD5" />
          </action>
        </keymap>
        """

    @Test func ownShortcutsFromAKeymap() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = try ide(home, "PhpStorm2026.1")
        // Older IDEs keep the active keymap in options/keymap.xml.
        try write(keymapChoice("macOS - Mishuk"), to: config + "/options/keymap.xml")
        try write(Self.ownKeymap, to: config + "/keymaps/macOS - Mishuk.xml")
        let plan = ImportJetBrains.plan(for: app(config), home: home)
        #expect(plan.shortcuts.map(\.command) == ["toggleEditorFocus:", "closeTab:", "findInFiles:", "goToFile:", "goToLine:",
                                                  "showNextTab:", "splitRight:"])
        func row(_ id: String) -> PlannedShortcut? { plan.shortcuts.first { $0.command == id } }
        #expect(row("toggleEditorFocus:")?.chord == KeyChord(key: "t", command: true) && row("toggleEditorFocus:")?.ticked == true)
        #expect(row("toggleEditorFocus:")?.source == "“macOS - Mishuk”: ActivateTerminalToolWindow meta T")
        // Every key taken away: offered, unticked.
        #expect(row("closeTab:")?.chord == nil && row("closeTab:")?.removed == [] && row("closeTab:")?.ticked == false)
        #expect(row("goToFile:")?.chord == KeyChord(key: "p", command: true))
        #expect(row("goToLine:")?.allowed == false)
        // ⌃→ stays with the shell (and macOS's Spaces); ⇧⌘] comes over.
        #expect(row("showNextTab:")?.chord == KeyChord(key: "]", command: true, shift: true))
        #expect(row("splitRight:")?.chord == KeyChord(key: "\\", command: true))

        let skipped = Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
        #expect(skipped["EditorDuplicate meta shift D"] == "no matching Next Term command")
        #expect(skipped["SelectNextOccurrence meta D"] == "no matching Next Term command")
        #expect(skipped["GotoAction"] == "no matching Next Term command")
        #expect(skipped["FindInPath meta button2"] == "mouse shortcuts aren't brought over")
        #expect(skipped["SaveAll meta K, meta S"] == "two-step keys aren't supported yet")
        #expect(skipped["NextTab control RIGHT"] == "one shortcut per command here; ⇧⌘] comes over")
        #expect(skipped["EditorToggleUseSoftWraps alt Z"] == "a menu shortcut needs ⌘ or ⌃ (Option alone types a character)")
        #expect(skipped["ShowSettings meta NUMPAD5"] == "numpad keys aren't supported")
        #expect(skipped["1 action left without shortcuts in your keymap"] == "they have no matching Next Term command, so nothing changes here")

        // Settled under the JetBrains keys: ⌘T is New Tab's; Find in Files, Show Next Tab and Split Right
        // already have these keys; ⌘P is free there, since Go to File is on ⇧⌘O.
        let settled = plan.settlingShortcuts(current: ImportShortcutsTests.current(.jetBrains))
        #expect(settled.shortcuts.map(\.command) == ["toggleEditorFocus:", "closeTab:", "goToFile:", "goToLine:"])
        #expect(settled.shortcuts.map(\.ticked) == [false, false, true, false])
        #expect(settled.shortcuts[0].note?.hasPrefix("⌘T is New Tab’s here") == true)
    }

    @Test func keyStrokes() {
        func key(_ text: String) -> KeyChord? {
            if case .chord(let chord) = ImportJetBrains.keyStroke(text) { return chord }
            return nil
        }
        func reason(_ text: String) -> String? {
            if case .notSupported(let reason) = ImportJetBrains.keyStroke(text) { return reason }
            return nil
        }
        #expect(key("meta shift O") == KeyChord(key: "o", command: true, shift: true))
        #expect(key("shift meta O") == KeyChord(key: "o", command: true, shift: true))
        #expect(key("control alt OPEN_BRACKET")?.display == "⌃⌥[")
        #expect(key("shift F6")?.display == "⇧F6")
        #expect(key("meta BACK_SLASH") == KeyChord(key: "\\", command: true) && key("meta EQUALS") == KeyChord(key: "=", command: true))
        #expect(key("meta 1") == KeyChord(key: "1", command: true))
        #expect(key("alt ENTER")?.display == "⌥↩" && key("meta DELETE")?.display == "⌘⌦" && key("meta BACK_SPACE")?.display == "⌘⌫")
        #expect(key("meta pressed P") == KeyChord(key: "p", command: true))
        #expect(key("control shift BACK_QUOTE") == KeyChord(key: "`", shift: true, control: true))
        #expect(reason("meta NUMPAD1") == "numpad keys aren't supported" && reason("meta ADD") == "numpad keys aren't supported")
        #expect(reason("meta F13") == "keys above F12 aren't supported")
        #expect(reason("meta") == "key not recognised" && reason("meta A B") == "key not recognised" && reason("meta INSERT") == "key not recognised")
    }

    @Test func classicAndOtherKeymaps() throws {
        var result = try keymapResult(["options/mac/keymap.xml": keymapChoice("Mac OS X")])
        #expect(result.preset == .jetBrains)
        #expect(result.notes.count == 1 && result.notes[0].item == "IntelliJ IDEA Classic keys")
        #expect(result.notes[0].reason.contains("⇧⌘N") && result.notes[0].reason.contains("⌘L"))

        for name in ["Eclipse (Mac OS X)", "Sublime Text (Mac OS X)", "$default", "Emacs"] {
            result = try keymapResult(["options/mac/keymap.xml": keymapChoice(name)])
            #expect(result.preset == .jetBrains)
            #expect(result.notes == [SkippedItem("Keymap “\(name)”", "the JetBrains preset follows JetBrains' macOS keymap, so some keys differ from this one")])
        }
    }

    @Test func oddKeymapFiles() throws {
        // Parents that loop end the walk.
        var result = try keymapResult([
            "options/mac/keymap.xml": keymapChoice("A"),
            "keymaps/A.xml": customKeymap("A", parent: "B", actions: ["GotoFile"]),
            "keymaps/B.xml": customKeymap("B", parent: "A", actions: []),
        ])
        #expect(result.preset == .jetBrains)
        // A name that tries to leave keymaps/ is never turned into a path.
        result = try keymapResult([
            "options/mac/keymap.xml": keymapChoice("../options/github"),
            "options/github.xml": customKeymap("x", parent: "VSCode OSX", actions: []),
        ])
        #expect(result.preset == .jetBrains)
        // Not XML, or the wrong root: as if no keymap were chosen.
        result = try keymapResult(["options/mac/keymap.xml": "<application><component name=\"KeymapManager\">"])
        #expect(result.preset == .jetBrains && result.notes.isEmpty)
        result = try keymapResult(["options/mac/keymap.xml": keymapChoice("Mine"), "keymaps/Mine.xml": "<scheme name=\"Mine\" parent=\"VSCode OSX\"/>"])
        #expect(result.preset == .jetBrains)
    }

    @Test func thePlanKeepsTheDetectedPreset() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = try ide(home, "PhpStorm2026.1")
        #expect(ImportJetBrains.plan(for: app(config, preset: .vsCode), home: home).preset == .vsCode)
        #expect(ImportJetBrains.plan(for: app(config), home: home).preset == .jetBrains)
    }

    // MARK: Settings

    func plan(_ files: [String: String], usKeyboard: Bool = true) throws -> ImportPlan {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = try ide(home, "PhpStorm2026.1")
        for (path, text) in files { try write(text, to: config + "/" + path) }
        return ImportJetBrains.plan(for: app(config), home: home, usKeyboard: usKeyboard)
    }

    @Test func editorFontSizeAndLineSpacing() throws {
        let plan = try self.plan(["options/editor-font.xml": component("DefaultFont", [
            ("VERSION", "1"), ("FONT_SIZE", "14"), ("FONT_SIZE_2D", "14.0"), ("FONT_FAMILY", "Fira Code"),
            ("LINE_SPACING", "1.37"), ("USE_LIGATURES", "true"),
        ])])
        #expect(plan.settings == [
            PlannedSetting(.fontSize(14), source: "options/editor-font.xml FONT_SIZE 14"),
            PlannedSetting(.editorLineHeight(1.35), source: "options/editor-font.xml LINE_SPACING 1.37"),
        ])
        #expect(plan.skipped == [SkippedItem("Editor font “Fira Code”", "font choice is coming"),
                                 SkippedItem("Font ligatures", "font choice is coming")])
    }

    @Test func valuesAreClamped() throws {
        var plan = try self.plan(["options/editor-font.xml": component("DefaultFont", [("FONT_SIZE", "40"), ("LINE_SPACING", "0.8")])])
        #expect(plan.settings.map(\.setting) == [.fontSize(32), .editorLineHeight(1.0)])
        #expect(plan.settings.map(\.note) == ["Next Term's sizes go from 8 to 32", "Next Term's line height goes from 1.0 to 2.0"])
        #expect(plan.settings.allSatisfy { $0.ticked })

        // Only the fractional size is set: rounded.
        plan = try self.plan(["options/editor-font.xml": component("DefaultFont", [("FONT_SIZE_2D", "13.5"), ("LINE_SPACING", "2.6")])])
        #expect(plan.settings.map(\.setting) == [.fontSize(14), .editorLineHeight(2.0)])
        #expect(plan.settings.first?.source == "options/editor-font.xml FONT_SIZE_2D 13.5")
        #expect(plan.settings.first?.note == nil)
    }

    @Test func valuesThatAreNotNumbersAreReported() throws {
        let plan = try self.plan([
            "options/editor-font.xml": component("DefaultFont", [("FONT_SIZE", "big"), ("LINE_SPACING", "nan")]),
            "options/terminal-font.xml": component("TerminalFontOptions", [("FONT_SIZE", "-3")]),
            "options/terminal.xml": component("TerminalOptionsProvider", [("useOptionAsMetaKey", "yes")]),
        ])
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped.map(\.item) == ["options/editor-font.xml FONT_SIZE", "options/editor-font.xml LINE_SPACING",
                                             "options/terminal.xml useOptionAsMetaKey", "options/terminal-font.xml FONT_SIZE"])
    }

    @Test func nothingSetMeansNoRows() throws {
        // As on this Mac: the files exist with only their version or unrelated components.
        let plan = try self.plan([
            "options/editor-font.xml": component("DefaultFont", [("VERSION", "1")]),
            "options/editor.xml": """
                <application>
                  <component name="DeclarativeInlayHintsSettings">
                    <option name="providerIdToEnabled">
                      <map>
                        <entry key="js.chain.hints" value="true" />
                      </map>
                    </option>
                  </component>
                  <component name="InlineCompletionOnboarding">
                    <option name="onboardingFinished" value="true" />
                  </component>
                </application>
                """,
            "options/terminal-font.xml": """
                <application>
                  <component name="TerminalFontOptions">
                    <option name="VERSION" value="1" />
                    <option name="SECONDARY_FONT_FAMILY" />
                  </component>
                </application>
                """,
        ])
        #expect(plan.settings.isEmpty && plan.skipped.isEmpty && plan.recentProjects.isEmpty)
    }

    @Test func aColourSchemeWithItsOwnFontWins() throws {
        let scheme = """
            <scheme name="_@user_Monokai Pro (Material)" version="142" parent_scheme="Darcula">
              <option name="FONT_SCALE" value="1.0" />
              <metaInfo>
                <property name="created">2021-07-02T02:55:54</property>
                <property name="ide">PhpStorm</property>
              </metaInfo>
              <option name="LINE_SPACING" value="1.4" />
              <font>
                <option name="EDITOR_FONT_NAME" value="Menlo" />
                <option name="EDITOR_FONT_SIZE" value="15" />
              </font>
              <font>
                <option name="EDITOR_FONT_NAME" value="JetBrains Mono" />
                <option name="EDITOR_FONT_SIZE" value="12" />
              </font>
              <colors>
                <option name="FILESTATUS_ADDED" value="c3e887" />
              </colors>
            </scheme>
            """
        let plan = try self.plan([
            "options/colors.scheme.xml": "<application>\n  <component name=\"EditorColorsManagerImpl\">\n    <global_color_scheme name=\"Monokai Pro (Material)\" />\n  </component>\n</application>",
            "colors/_@user_Monokai Pro _Material_.icls": scheme,
            "colors/_@user_Darcula.icls": "<scheme name=\"_@user_Darcula\" version=\"142\" parent_scheme=\"Darcula\">\n  <option name=\"EDITOR_FONT_SIZE\" value=\"20\" />\n  <option name=\"EDITOR_FONT_NAME\" value=\"Monaco\" />\n</scheme>",
            "options/editor-font.xml": component("DefaultFont", [("FONT_SIZE", "12"), ("LINE_SPACING", "1.1"), ("FONT_FAMILY", "Fira Code")]),
        ])
        #expect(plan.settings == [
            PlannedSetting(.fontSize(15), source: "colors/_@user_Monokai Pro _Material_.icls EDITOR_FONT_SIZE 15"),
            PlannedSetting(.editorLineHeight(1.4), source: "colors/_@user_Monokai Pro _Material_.icls LINE_SPACING 1.4"),
        ])
        #expect(plan.skipped == [SkippedItem("Editor font “Menlo”", "font choice is coming"),
                                 SkippedItem("Colour scheme “Monokai Pro (Material)”", "colour themes come later")])
    }

    @Test func aSchemeWithOnlyColoursUsesTheIDEFont() throws {
        var plan = try self.plan([
            "options/colors.scheme.xml": "<application>\n  <component name=\"EditorColorsManagerImpl\">\n    <global_color_scheme name=\"Islands Dark\" />\n  </component>\n</application>",
            "colors/_@user_Islands Dark.icls": "<scheme name=\"_@user_Islands Dark\" version=\"142\" parent_scheme=\"Darcula\">\n  <colors>\n    <option name=\"FILESTATUS_ADDED\" value=\"C3E887\" />\n  </colors>\n</scheme>",
            "options/editor-font.xml": component("DefaultFont", [("FONT_SIZE", "13")]),
        ])
        #expect(plan.settings.map(\.setting) == [.fontSize(13)])
        #expect(plan.skipped == [SkippedItem("Colour scheme “Islands Dark”", "colour themes come later")])

        // Top-level font options (an older scheme format).
        plan = try self.plan([
            "options/colors.scheme.xml": "<application>\n  <component name=\"EditorColorsManagerImpl\">\n    <global_color_scheme name=\"Monokai Pro\" />\n  </component>\n</application>",
            "colors/Monokai Pro.icls": "<scheme name=\"Monokai Pro\" version=\"142\">\n  <option name=\"LINE_SPACING\" value=\"1.3\" />\n  <option name=\"EDITOR_FONT_SIZE\" value=\"16\" />\n  <option name=\"EDITOR_FONT_NAME\" value=\"JetBrains Mono\" />\n  <option name=\"EDITOR_LIGATURES\" value=\"true\" />\n</scheme>",
        ])
        #expect(plan.settings.map(\.setting) == [.fontSize(16), .editorLineHeight(1.3)])
        #expect(plan.skipped.map(\.item) == ["Editor font “JetBrains Mono”", "Font ligatures", "Colour scheme “Monokai Pro”"])
    }

    func softWrap(_ options: [(String, String)]) throws -> (settings: [PlannedSetting], skipped: [SkippedItem]) {
        let plan = try self.plan(["options/editor.xml": component("EditorSettings", options)])
        return (plan.settings, plan.skipped)
    }

    @Test func softWrap() throws {
        // Missing: JetBrains' default (Markdown and text files only) says nothing about the user.
        var result = try softWrap([("IS_ALL_SOFTWRAPS_SHOWN", "true")])
        #expect(result.settings.isEmpty && result.skipped.isEmpty)

        // Empty: turned off.
        result = try softWrap([("USE_SOFT_WRAPS", "")])
        #expect(result.settings == [PlannedSetting(.softWrap(false), source: "options/editor.xml USE_SOFT_WRAPS \"\"")])
        #expect(result.skipped.isEmpty)

        // On, for the default file types: on, with the file types reported.
        result = try softWrap([("USE_SOFT_WRAPS", "MAIN_EDITOR,CONSOLE")])
        #expect(result.settings == [PlannedSetting(.softWrap(true), source: "options/editor.xml USE_SOFT_WRAPS MAIN_EDITOR,CONSOLE")])
        #expect(result.skipped == [SkippedItem("Soft wrap only for “*.md; *.txt; *.rst; *.adoc”", "Next Term wraps every file or none")])

        // On for every file.
        result = try softWrap([("USE_SOFT_WRAPS", "MAIN_EDITOR,CONSOLE"), ("SOFT_WRAP_FILE_MASKS", "*")])
        #expect(result.settings.map(\.setting) == [.softWrap(true)] && result.skipped.isEmpty)
        result = try softWrap([("SOFT_WRAP_FILE_MASKS", "*")])
        #expect(result.settings == [PlannedSetting(.softWrap(true), source: "options/editor.xml SOFT_WRAP_FILE_MASKS *")])

        // Only the file types changed: no row, the types reported.
        result = try softWrap([("SOFT_WRAP_FILE_MASKS", "*.md; *.php")])
        #expect(result.settings.isEmpty)
        #expect(result.skipped.map(\.item) == ["Soft wrap only for “*.md; *.php”"])

        // On in the console only: off in the editor.
        result = try softWrap([("USE_SOFT_WRAPS", "CONSOLE")])
        #expect(result.settings.map(\.setting) == [.softWrap(false)] && result.skipped.isEmpty)
    }

    @Test func editorSettingsThatComeLater() throws {
        let plan = try self.plan([
            "options/editor.xml": component("EditorSettings", [("STRIP_TRAILING_SPACES", "Whole"), ("IS_ENSURE_NEWLINE_AT_EOF", "true")]),
            "codestyles/Default.xml": "<code_scheme name=\"Default\" version=\"173\" />",
        ])
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped == [SkippedItem("Strip trailing spaces on save", "trimming on save comes later"),
                                 SkippedItem("Ensure a newline at the end of files", "a final newline on save comes later"),
                                 SkippedItem("Code style", "indentation settings come later")])
    }

    @Test func optionAsMeta() throws {
        let on = component("TerminalOptionsProvider", [("useOptionAsMetaKey", "true")])
        var plan = try self.plan(["options/terminal.xml": on])
        #expect(plan.settings == [PlannedSetting(.optionAsMeta(true), source: "options/terminal.xml useOptionAsMetaKey true")])

        // A layout that needs Option for symbols: offered, not ticked.
        plan = try self.plan(["options/terminal.xml": on], usKeyboard: false)
        #expect(plan.settings.map(\.setting) == [.optionAsMeta(true)])
        #expect(plan.settings.first?.ticked == false)
        #expect(plan.settings.first?.note?.contains("@ [ ] { }") == true)

        // Off is always safe.
        plan = try self.plan(["options/terminal.xml": component("TerminalOptionsProvider", [("useOptionAsMetaKey", "false")])], usKeyboard: false)
        #expect(plan.settings == [PlannedSetting(.optionAsMeta(false), source: "options/terminal.xml useOptionAsMetaKey false")])
    }

    @Test func terminalFontSizeOnlyWhenTheEditorHasNone() throws {
        let terminal = component("TerminalFontOptions", [("VERSION", "1"), ("FONT_FAMILY", "MesloLGS NF"), ("FONT_SIZE", "15.0")])
        var plan = try self.plan(["options/terminal-font.xml": terminal])
        #expect(plan.settings == [PlannedSetting(.fontSize(15), source: "options/terminal-font.xml FONT_SIZE 15")])
        #expect(plan.skipped == [SkippedItem("Terminal font “MesloLGS NF”", "font choice is coming")])

        plan = try self.plan(["options/terminal-font.xml": terminal, "options/editor-font.xml": component("DefaultFont", [("FONT_SIZE", "14")])])
        #expect(plan.settings.map(\.setting) == [.fontSize(14)])
        #expect(plan.skipped.first == SkippedItem("Terminal font size 15",
            "Next Term uses one size for the editor and the terminal, so the editor's 14 is used"))

        plan = try self.plan(["options/terminal-font.xml": component("TerminalFontOptions", [("FONT_SIZE", "14")]),
                         "options/editor-font.xml": component("DefaultFont", [("FONT_SIZE", "14")])])
        #expect(plan.settings.map(\.setting) == [.fontSize(14)] && plan.skipped.isEmpty)
    }

    // MARK: Safety

    let token = "ghp_" + String(repeating: "A1b2C3", count: 6)
    let apiKey = "sk-" + String(repeating: "x9Y8", count: 6)

    @Test func secretsAreNeverRead() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = try ide(home, "PhpStorm2026.1")
        try write("""
            <application>
              <component name="TerminalOptionsProvider">
                <option name="useOptionAsMetaKey" value="true" />
                <option name="shellPath" value="/bin/zsh --login -c 'export TOKEN=\(token)'" />
                <option name="envDataOptions">
                  <EnvironmentVariablesData>
                    <envs>
                      <env key="GITHUB_TOKEN" value="\(token)" />
                    </envs>
                  </EnvironmentVariablesData>
                </option>
                <option name="apiToken" value="\(apiKey)" />
              </component>
            </application>
            """, to: config + "/options/terminal.xml")
        try write(component("DefaultFont", [("FONT_SIZE", "13"), ("FONT_FAMILY", apiKey)]), to: config + "/options/editor-font.xml")
        try write(component("EditorSettings", [("SOFT_WRAP_FILE_MASKS", token)]), to: config + "/options/editor.xml")
        // Files that are never opened, holding what they hold in real life.
        try write(token, to: config + "/phpstorm.key")
        try write(token, to: config + "/plugin_PLARAVEL.license")
        try write(component("GithubAccounts", [("token", token)]), to: config + "/options/github.xml")
        try write(component("SshConfigs", [("password", token)]), to: config + "/options/sshConfigs.xml")
        try write(component("x", [("x", token)]), to: config + "/workspace/abc.xml")

        let plan = ImportJetBrains.plan(for: app(config), home: home)
        let everything = String(describing: plan)
        #expect(!everything.contains(token) && !everything.contains(apiKey) && !everything.contains("export"))
        #expect(plan.settings.map(\.setting) == [.fontSize(13), .optionAsMeta(true)])
        #expect(plan.skipped == [
            SkippedItem("Editor font", "looked like a credential"),
            SkippedItem("Soft wrap only for", "looked like a credential"),
            SkippedItem("options/terminal.xml shellPath", "never imported: it runs a program"),
            SkippedItem("options/terminal.xml envDataOptions", "never imported: can hold secrets"),
            SkippedItem("options/terminal.xml apiToken", "never imported: can hold secrets"),
        ])

        // The values never reach the parsed tree, not just the plan.
        func values(_ node: ImportJetBrains.Node?) -> [String] {
            guard let node else { return [] }
            return Array(node.attributes.values) + node.children.flatMap(values)
        }
        let tree = values(ImportJetBrains.read(config, "options/terminal.xml"))
        #expect(!tree.contains { $0.contains(token) || $0.contains(apiKey) })
        #expect(tree.contains("envDataOptions") && tree.contains("apiToken"))
    }

    @Test func onlyAllowlistedFilesOpen() throws {
        for allowed in ["options/editor-font.xml", "options/editor.xml", "options/terminal.xml", "options/terminal-font.xml",
                        "options/keymap.xml", "options/mac/keymap.xml", "options/recentProjects.xml", "options/colors.scheme.xml",
                        "keymaps/macOS - Mishuk.xml", "colors/_@user_Islands Dark.icls"] {
            #expect(ImportJetBrains.mayOpen(allowed), "\(allowed)")
        }
        for denied in ["phpstorm.key", "plugin_PLARAVEL.license", "options/security.xml", "c.kdbx", "options/c.kdbx",
                       "options/github.xml", "options/gitlab.xml", "options/sshConfigs.xml", "options/remote-servers.xml",
                       "options/webServers.xml", "workspace/2g9hnFP1fGCoTG6VFo1caQotQ13.xml", "settingsSync/options/editor.xml",
                       "app-internal-state.db", "options/dataSources.xml", "options/other.xml", "options/terminal-local.xml",
                       "keymaps/../options/github.xml", "keymaps/github.xml", "keymaps/sub/x.xml", "keymaps/x.key",
                       "colors/x.xml", "/etc/passwd", "options//editor.xml", "./options/editor.xml", ""] {
            #expect(!ImportJetBrains.mayOpen(denied), "\(denied)")
        }
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = try ide(home, "PhpStorm2026.1")
        try write(component("GithubAccounts", [("x", "y")]), to: config + "/options/github.xml")
        #expect(ImportJetBrains.read(config, "options/github.xml") == nil)
        try write(component("EditorSettings", [("x", "y")]), to: config + "/options/editor.xml")
        #expect(ImportJetBrains.read(config, "options/editor.xml")?.name == "application")
    }

    @Test func missingOrBrokenFiles() throws {
        // A settings folder that disappeared, an empty one, broken XML, a folder where a file should be, a huge file.
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let gone = ImportJetBrains.plan(for: app(home + "/nowhere"), home: home)
        #expect(gone == ImportPlan(preset: .jetBrains))
        let config = try ide(home, "PhpStorm2026.1")
        #expect(ImportJetBrains.plan(for: app(config), home: home) == ImportPlan(preset: .jetBrains))
        try write("<application><component name=\"DefaultFont\"><option name=\"FONT_SIZE\" value=\"14\" />", to: config + "/options/editor-font.xml")
        try write("", to: config + "/options/terminal.xml")
        try folder(config + "/options/editor.xml")
        try write(component("TerminalFontOptions", [("FONT_SIZE", "15")]) + String(repeating: " ", count: 5 << 20),
                  to: config + "/options/terminal-font.xml")
        try write("\u{0}\u{1}not xml", to: config + "/options/recentProjects.xml")
        #expect(ImportJetBrains.plan(for: app(config), home: home) == ImportPlan(preset: .jetBrains))
    }

    @Test func noNetworkingInTheImporter() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NextTermCore/ImportJetBrains.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for banned in ["URLSession", "import Network", "NSURLConnection", "CFNetwork", "Process(", "FileManager.default.copyItem",
                       "createFile", "write(to", "write(toFile", "removeItem"] {
            #expect(!text.contains(banned), "\(banned)")
        }
    }

    // MARK: Recent projects

    @Test func recentProjectsFromEveryIDE() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        for path in ["Code/a", "Code/b", "Code/real", "Code/hidden", "AndroidStudioProjects/app",
                     "Code/xcloudmigration/wp-content/plugins/wp-xcloud-migration", "Code/" + String(repeating: "Ab12", count: 11)] {
            try folder(home + "/" + path)
        }
        try fm.createSymbolicLink(atPath: home + "/Code/link", withDestinationPath: home + "/Code/real")
        try write("not a folder", to: home + "/Code/file.txt")
        let phpStorm = try ide(home, "PhpStorm2026.1")
        try write(recents([
            Entry(key: "$USER_HOME$/Code/a", activation: 300, opened: 290),
            Entry(key: "$USER_HOME$/Code/b", opened: 500),                       // no activation: the open time
            Entry(key: "$USER_HOME$/Code/hidden", activation: 900, hidden: true),
            Entry(key: "$USER_HOME$/Code/gone", activation: 800),
            Entry(key: "$USER_HOME$/Code/file.txt", activation: 800),
            Entry(key: "ssh://dev@server/var/www", activation: 950),
            Entry(key: "$APPLICATION_HOME_DIR$/samples", activation: 950),
            Entry(key: "//wsl$/Ubuntu/home/me/app", activation: 950),
            Entry(key: "$USER_HOME$/Code/link", activation: 100),
            Entry(key: "$USER_HOME$/Code/xcloudmigration/wp-content/plugins/wp-xcloud-migration", activation: 200),
            Entry(key: "$USER_HOME$/Code/" + String(repeating: "Ab12", count: 11), activation: 990),
        ]), to: phpStorm + "/options/recentProjects.xml")
        let studio = try ide(home, "AndroidStudio2025.3.4", vendor: "Google")
        try write(recents([
            Entry(key: "$USER_HOME$/Code/a", activation: 1000),
            Entry(key: "$USER_HOME$/AndroidStudioProjects/app", activation: 700),
            Entry(key: home + "/Code/real", activation: 50),
        ]), to: studio + "/options/recentProjects.xml")

        let plan = ImportJetBrains.plan(for: app(phpStorm), home: home)
        #expect(plan.recentProjects == ["a", "AndroidStudioProjects/app", "b", "xcloudmigration/wp-content/plugins/wp-xcloud-migration", "real"]
            .map { $0.hasPrefix("Android") ? home + "/" + $0 : home + "/Code/" + $0 })
        #expect(plan.skipped == [SkippedItem("2 recent projects", "the folder no longer exists"),
                                 SkippedItem("3 remote projects", "remote projects aren't supported yet"),
                                 SkippedItem("1 recent project", "looked like a credential")])
        #expect(!String(describing: plan).contains("Ab12Ab12"))
    }

    @Test func atMostTwentyRecentProjects() throws {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        var entries: [Entry] = []
        for n in 1...25 {
            try folder(home + "/Code/p\(n)")
            entries.append(Entry(key: "$USER_HOME$/Code/p\(n)", activation: Int64(n)))
        }
        let config = try ide(home, "PhpStorm2026.1")
        try write(recents(entries), to: config + "/options/recentProjects.xml")
        let plan = ImportJetBrains.plan(for: app(config), home: home)
        #expect(plan.recentProjects == (6...25).reversed().map { home + "/Code/p\($0)" })
        #expect(plan.skipped == [SkippedItem("5 older recent projects", "only the 20 most recent come over")])
    }

    @Test func recentsFromAnIDEThatIsNotDetected() throws {
        // A plan for an unused IDE still reads its own list, beside the detected IDEs'.
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        try folder(home + "/Code/old")
        try folder(home + "/Code/new")
        try ide(home, "PhpStorm2026.1", usedDaysAgo: 1)
        try write(recents([Entry(key: "$USER_HOME$/Code/new", activation: 2)]),
                  to: home + "/Library/Application Support/JetBrains/PhpStorm2026.1/options/recentProjects.xml")
        let old = try ide(home, "WebStorm2023.1", usedDaysAgo: 400)
        try write(recents([Entry(key: "$USER_HOME$/Code/old", activation: 1)]), to: old + "/options/recentProjects.xml")
        try touch(old + "/options/recentProjects.xml", daysAgo: 400)
        #expect(ImportJetBrains.detect(home: home).map(\.name) == ["PhpStorm 2026.1"])
        #expect(ImportJetBrains.plan(for: app(old), home: home).recentProjects == [home + "/Code/new", home + "/Code/old"])
    }

    @Test func expandingPaths() {
        #expect(ImportJetBrains.expand("$USER_HOME$/Code/a", home: "/Users/me") == "/Users/me/Code/a")
        #expect(ImportJetBrains.expand("$USER_HOME$", home: "/Users/me") == "/Users/me")
        #expect(ImportJetBrains.expand("/opt/project", home: "/Users/me") == "/opt/project")
        #expect(ImportJetBrains.expand("$USER_HOME$x/Code", home: "/Users/me") == nil)
        #expect(ImportJetBrains.expand("$PROJECT_DIR$/x", home: "/Users/me") == nil)
        #expect(ImportJetBrains.expand("file:///Users/me/a", home: "/Users/me") == nil)
        #expect(ImportJetBrains.expand("relative/path", home: "/Users/me") == nil)
    }
}
