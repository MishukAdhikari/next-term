import Foundation
import Testing
@testable import NextTermCore

/// Fixtures are written into a fresh temporary home per test; the real home is never read.
@Suite struct ImportWarpTests {
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-import-warp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, to path: String, date: Date? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    /// `$HOME` in the settings stands for the temporary home.
    func plan(_ settings: String, files: [String: String] = [:], usKeyboard: Bool = true) throws -> ImportPlan {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(settings.replacingOccurrences(of: "$HOME", with: home), to: home + "/.warp/settings.toml")
        for (path, text) in files { try write(text, to: home + "/.warp/" + path) }
        let app = try #require(ImportWarp.detect(home: home, applications: []).first)
        return ImportWarp.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts)
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    /// A settings file shaped like Warp's own: agent profiles with multi-line lists, API keys, the
    /// redaction list, and the few appearance values the import reads.
    let settings = """
        [cloud_platform]

        [cloud_platform.third_party_api_keys]
        openai = "sk-proj-abcdefghijklmnopqrstuvwxyz"

        [agents.execution_profiles.default]
        command_denylist = [
          'bash(\\s.*)?',
          'rm(\\s.*)? [ ] { }',
        ]
        name = "font_size = 99"

        [appearance.themes]
        theme = "My Theme"

        [appearance.text]
        font_name = "JetBrains Mono" # the one I like
        font_size = 14.0
        ligature_rendering_enabled = true

        [terminal.input]
        extra_meta_keys = ["left_alt", "right_alt"]

        [privacy]
        custom_secret_regex_list = [
          { name = "token", pattern = 'ghp_[A-Za-z0-9]{36}' },
          {
            name = "key",
            pattern = "AKIA[0-9A-Z]{16}"
          },
        ]

        [warpify.ssh]
        ssh_hosts_denylist = ["prod-db.internal.example"]
        """

    let theme = """
        name: My Theme
        accent: '#268bd2'
        background: '#002b36' # dark
        foreground: "#839496"
        details: darker
        terminal_colors:
          normal:
            black: '#073642'
            red: '#dc322f'
          bright:
            black: '#002b36'
            white: '#fdf6e3'
            blue: blue
        """

    @Test func detection() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ImportWarp.detect(home: home, applications: []).isEmpty)
        let used = Date(timeIntervalSince1970: 1_790_000_000)
        try write("", to: home + "/.warp/settings.toml", date: used)
        #expect(ImportWarp.detect(home: home, applications: []) == [DetectedApp(kind: .warp, name: "Warp", configPath: home + "/.warp", lastUsed: used)])
        #expect(ImportWarp.detect(home: home, applications: []).first?.appRemoved == true)

        // The app and its version, from the folders given.
        let plist = #"<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.2025.10.01</string></dict></plist>"#
        try write(plist, to: home + "/Applications/Warp.app/Contents/Info.plist", date: used)
        let found = try #require(ImportWarp.detect(home: home, applications: [home + "/Applications"]).first)
        #expect(found.appPath == home + "/Applications/Warp.app" && found.version == "0.2025.10.01" && !found.appRemoved)
    }

    @Test func settingsAndACustomTheme() throws {
        let plan = try plan(settings, files: ["themes/my_theme.yaml": theme, "keybindings.yaml": "x: y"])
        var ansi: [UInt32?] = Array(repeating: nil, count: 16)
        ansi[0] = 0x073642
        ansi[1] = 0xDC322F
        ansi[8] = 0x002B36
        ansi[15] = 0xFDF6E3
        // No cursor colour: Warp draws the cursor in the accent.
        let palette = TerminalPalette(name: "Warp colours", ansi: ansi, foreground: 0x839496, background: 0x002B36, cursor: 0x268BD2)
        #expect(plan.settings == [
            PlannedSetting(.terminalFontFamily("JetBrains Mono"), source: "font_name JetBrains Mono"),
            PlannedSetting(.terminalFontSize(14), source: "font_size 14"),
            PlannedSetting(.optionAsMeta(true), source: "extra_meta_keys left_alt, right_alt"),
            PlannedSetting(.terminalPalette(palette), source: "theme my_theme.yaml", note: "7 of 20 colours; the others stay Next Term's"),
        ])
        #expect(plan.skipped == [
            SkippedItem("theme terminal_colors.bright.blue", "only #rrggbb colours are read"),
            SkippedItem("[cloud_platform.third_party_api_keys]", "never imported: can hold secrets or configures agents"),
            SkippedItem("[agents.execution_profiles.default]", "never imported: can hold secrets or configures agents"),
            SkippedItem("[privacy]", "never imported: can hold secrets or configures agents"),
            SkippedItem("2 other settings", "no matching Next Term setting yet"),
            SkippedItem("keybindings.yaml", "Warp's own shortcuts aren't brought over yet"),
        ])
        let shown = "\(plan)"
        for value in ["sk-proj", "ghp_", "AKIA", "prod-db", "bash(", "99"] {
            #expect(!shown.contains(value), "\(value) reached the plan")
        }
    }

    @Test func builtInThemesOneSidedMetaAndOddValues() throws {
        let plan = try plan("""
            [appearance.themes]
            theme = "gruvbox_light"
            [appearance.text]
            font_size = "big"
            font_name = "Comic Code"
            [terminal.input]
            extra_meta_keys = ["left_alt"]
            """, usKeyboard: true)
        #expect(plan.settings.map(\.setting) == [.optionAsMeta(true)])
        #expect(plan.settings.first?.ticked == false)
        #expect(plan.settings.first?.note == "on in Warp for Left Option only; Next Term can't set one side yet")
        #expect(reasons(plan)["theme gruvbox_light"] == "Warp's built-in themes are inside Warp, so they can't be read")
        #expect(reasons(plan)["font_size"] == "not a font size Next Term can use")
        #expect(reasons(plan)["Terminal font “Comic Code”"] == "not installed on this Mac")

        // A custom theme named by path inside the themes folder; nothing outside it is opened.
        let byPath = try self.plan(#"[appearance.themes]"# + "\n" + #"theme = { Custom = { name = "Solar", path = "/x/.warp/themes/solar.yaml" } }"#,
                                   files: ["themes/solar.yaml": "background: '#000000'"])
        #expect(byPath.settings.first?.source == "theme solar.yaml")
        let outside = try self.plan("[appearance.themes]\ntheme = \"../../../etc/passwd\"")
        #expect(outside.settings.isEmpty)
    }

    /// With "match the system's light and dark" on, Warp shows the dark one of its two system themes.
    @Test func systemLightAndDarkThemes() throws {
        let files = ["themes/my_dark.yaml": "background: '#002b36'", "themes/my_light.yaml": "background: '#fdf6e3'",
                     "themes/standard/night.yaml": "background: '#101010'\ncursor: '#ffffff'"]
        let note = "1 of 20 colours; the others stay Next Term's; Warp follows the system's light and dark; Next Term is dark"
        let strings = try plan("""
            [appearance.themes]
            system_theme = true
            theme = "my_light"
            selected_system_themes = { dark = "my_dark", light = "my_light" }
            """, files: files)
        #expect(strings.settings == [PlannedSetting(.terminalPalette(TerminalPalette(name: "Warp colours", background: 0x002B36)),
                                                    source: "dark theme my_dark.yaml", note: note)])

        // The dark one as a custom theme of its own, over several lines, with its file in a subfolder.
        let custom = try plan("""
            [appearance.themes]
            system_theme = true # follow macOS
            theme = "my_light"
            selected_system_themes = {
              light = "my_light",
              dark = { Custom = { name = "Night, Mine", path = "$HOME/.warp/themes/standard/night.yaml" } },
            }
            """, files: files)
        #expect(custom.settings.map(\.source) == ["dark theme night.yaml"])

        // Off, or not set: `theme` is the one in use.
        let off = try plan("[appearance.themes]\nsystem_theme = false\ntheme = \"my_light\"\nselected_system_themes = { dark = \"my_dark\" }",
                           files: files)
        #expect(off.settings.map(\.source) == ["theme my_light.yaml"])
        #expect(try plan("[appearance.themes]\ntheme = \"my_light\"", files: files).settings.map(\.source) == ["theme my_light.yaml"])

        // Warp's own dark themes can't be read.
        let builtIn = try plan("[appearance.themes]\nsystem_theme = true\nselected_system_themes = { dark = \"dark\", light = \"my_light\" }",
                               files: files)
        #expect(builtIn.settings.isEmpty)
        #expect(reasons(builtIn)["dark theme dark"] == "Warp's built-in themes are inside Warp, so they can't be read")
        let unset = try plan("[appearance.themes]\nsystem_theme = true\ntheme = \"my_light\"", files: files)
        #expect(unset.settings.isEmpty)
        #expect(reasons(unset)["system_theme"] == "Warp's own dark theme is inside Warp, so it can't be read")
    }

    /// Warp's themes repository cloned into ~/.warp/themes keeps its themes in subfolders.
    @Test func customThemesInSubfolders() throws {
        let files = ["themes/standard/solarized_dark.yaml": "background: '#002b36'", "themes/base16/ocean.yml": "background: '#2b303b'",
                     "secret.yaml": "background: '#000000'"]
        func source(_ value: String) throws -> [String] {
            try plan("[appearance.themes]\ntheme = " + value, files: files).settings.map(\.source)
        }
        // By the path Warp saves, or by name when the path is elsewhere.
        #expect(try source(#"{ Custom = { name = "Solarized Dark", path = "$HOME/.warp/themes/standard/solarized_dark.yaml" } }"#)
                == ["theme solarized_dark.yaml"])
        #expect(try source(#"{ Custom = { name = "Solarized Dark", path = "/elsewhere/x.yaml" } }"#) == ["theme solarized_dark.yaml"])
        #expect(try source(#""ocean""#) == ["theme ocean.yml"])
        // A path outside the themes folder is never opened, even when the file is there.
        #expect(try source(#"{ Custom = { name = "x", path = "$HOME/.warp/secret.yaml" } }"#).isEmpty)
        #expect(try source(#"{ Custom = { name = "x", path = "$HOME/.warp/themes/../secret.yaml" } }"#).isEmpty)

        let missing = try plan(#"[appearance.themes]"# + "\n" + #"theme = { Custom = { name = "Gone", path = "$HOME/.warp/themes/gone.yaml" } }"#)
        #expect(reasons(missing)["theme Gone"] == "custom theme file not found in ~/.warp/themes")
    }

    // MARK: the vertical tab panel

    /// A font size, then the vertical tab panel's table with `lines` in it.
    func panel(_ lines: String) -> String {
        "[appearance.text]\nfont_size = 14.0\n\n[appearance.vertical_tabs]\n" + lines
    }

    func otherSettings(_ plan: ImportPlan) -> String? {
        plan.skipped.first { $0.reason == "no matching Next Term setting yet" }?.item
    }

    /// The panel on: the list on the left with the project files on the right, ticked, and the first setting row,
    /// since it is why someone moves.
    @Test func thePanelOnIsTheListOnTheLeftWithTheFilesOnTheRight() throws {
        let plan = try plan(panel("enabled = true # on\ndisplay_granularity = \"panes\""))
        let row = PlannedSetting(.tabList(TabListImport(tabs: "left", sidebarSide: "right")), source: "vertical_tabs.enabled true")
        let settings: [ImportedSetting] = [.tabList(TabListImport(tabs: "left", sidebarSide: "right")), .terminalFontSize(14)]
        #expect(plan.settings.first == row)
        #expect(plan.settings.first?.ticked == true && plan.settings.first?.note == nil)
        #expect(plan.settings.map(\.setting) == settings)
        // The values it doesn't read are counted, as before.
        #expect(otherSettings(plan) == "1 other setting")
    }

    /// Expanded view shows details under each tab: Show Folders too, and the note says why. Compact view is the list's
    /// own one line.
    @Test func expandedViewAlsoShowsEachTabsFolder() throws {
        let expanded = try plan(panel("enabled = true\nview_mode = \"expanded\""))
        let folders = TabListImport(tabs: "left", sidebarSide: "right", showsFolders: true)
        #expect(expanded.settings.first == PlannedSetting(.tabList(folders), source: "vertical_tabs.enabled true",
                                                          note: "with each tab’s folder under it, as expanded view had it"))
        let compact = try plan(panel("view_mode = 'compact'\nenabled = true"))
        #expect(compact.settings.first == PlannedSetting(.tabList(TabListImport(tabs: "left", sidebarSide: "right")),
                                                         source: "vertical_tabs.enabled true"))
        // Both were read, so neither is among the other settings.
        #expect(otherSettings(expanded) == nil && otherSettings(compact) == nil)
    }

    /// A side the settings name: on the right, the list on the right and the files on the left; on the left, or a
    /// side the list can't take, the panel's own left.
    @Test func aPanelOnTheRightIsTheListOnTheRightWithTheFilesOnTheLeft() throws {
        let right = try plan(panel("enabled = true\nside = \"right\""))
        #expect(right.settings.first == PlannedSetting(.tabList(TabListImport(tabs: "right", sidebarSide: "left")),
                                                       source: "vertical_tabs.enabled true, side right"))
        let position = try plan(panel("position = \"Right\"\nenabled = true\nview_mode = \"expanded\""))
        let mirrored = TabListImport(tabs: "right", sidebarSide: "left", showsFolders: true)
        #expect(position.settings.first?.setting == .tabList(mirrored))
        #expect(position.settings.first?.source == "vertical_tabs.enabled true, position right")
        for side in ["left", "bottom", "3"] {
            let other = try plan(panel("enabled = true\nside = \"\(side)\""))
            #expect(other.settings.first?.setting == .tabList(TabListImport(tabs: "left", sidebarSide: "right")), "\(side)")
            #expect(otherSettings(other) == nil, "\(side)")
        }
        #expect(try plan(panel("enabled = true\nside = \"left\"")).settings.first?.source == "vertical_tabs.enabled true, side left")
    }

    /// Off, missing or not a yes or no: no row, and nothing else moves. The panel's values read with it off count
    /// among the other settings, as they would have unread.
    @Test func thePanelOffOrMissingPlansNoRow() throws {
        func hasRow(_ plan: ImportPlan) -> Bool {
            plan.settings.contains { if case .tabList = $0.setting { return true } else { return false } }
        }
        let off = try plan(panel("enabled = false"))
        #expect(!hasRow(off) && off.settings.map(\.setting) == [.terminalFontSize(14)])
        #expect(otherSettings(off) == nil)
        let offCompact = try plan(panel("enabled = false\nview_mode = \"compact\""))
        #expect(!hasRow(offCompact) && otherSettings(offCompact) == "1 other setting")
        let offBoth = try plan(panel("enabled = false\nview_mode = \"expanded\"\nside = \"right\"\nshow_close = true"))
        #expect(!hasRow(offBoth) && otherSettings(offBoth) == "3 other settings")
        let missing = try plan("[appearance.text]\nfont_size = 14.0")
        #expect(!hasRow(missing) && otherSettings(missing) == nil)
        let alone = try plan(panel("view_mode = \"expanded\""))
        #expect(!hasRow(alone) && otherSettings(alone) == "1 other setting")
        let odd = try plan(panel("enabled = \"yes\""))
        #expect(!hasRow(odd))
        #expect(reasons(odd)["vertical_tabs.enabled"] == "value not recognised")
    }

    /// The panel read beside the secrets the file holds: the never-read tables stay unread and the other counts stay
    /// as they were. A table under the panel's whose name says it can hold secrets is never read either.
    @Test func thePanelBesideSecretsReadsNothingMore() throws {
        let text = settings + "\n\n[appearance.vertical_tabs]\nenabled = true\n\n[appearance.vertical_tabs.auth]\nside = \"right\"\n"
            + "token = \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\"\n"
        let plan = try plan(text, files: ["themes/my_theme.yaml": theme])
        #expect(plan.settings.first?.setting == .tabList(TabListImport(tabs: "left", sidebarSide: "right")))
        #expect(plan.settings.count == 5)
        #expect(otherSettings(plan) == "2 other settings")
        #expect(reasons(plan)["[appearance.vertical_tabs.auth]"] == "never imported: can hold secrets or configures agents")
        let shown = "\(plan)"
        for value in ["sk-proj", "ghp_", "AKIA", "prod-db"] { #expect(!shown.contains(value), "\(value) reached the plan") }
    }

    /// How the preview and a one-click import word the row.
    @Test func theRowSaysWhereTheTabsAndFilesGo() {
        let left = TabListImport(tabs: "left", sidebarSide: "right", showsFolders: true)
        #expect(left.title == "Tabs on the left, project files on the right")
        #expect(left.movedLine == "Tabs moved to the left, project files to the right.")
        let right = TabListImport(tabs: "right", sidebarSide: "left")
        #expect(right.title == "Tabs on the right, project files on the left")
        #expect(right.movedLine == "Tabs moved to the right, project files to the left.")
        let alone = TabListImport(tabs: "left")
        #expect(alone.title == "Tabs on the left" && alone.movedLine == "Tabs moved to the left.")
    }

    @Test func tomlAndYAMLSubsets() {
        #expect(TOML.string(#""a \"b\" c" # note"#) == #"a "b" c"#)
        #expect(TOML.string("'C:\\path'") == "C:\\path")
        #expect(TOML.string("13") == nil)
        #expect(TOML.number("13.5 # size") == 13.5)
        #expect(TOML.strings(#"["a", 'b']"#) == ["a", "b"])
        #expect(TOML.strings(#"["a", 3]"#) == nil)
        #expect(TOML.depthChange("[ 'a]' , \"b[\" # ]") == 1)
        #expect(TOML.tableName("[appearance.text] # c") == "appearance.text")
        #expect(TOML.bool("true # yes") == true)
        #expect(TOML.bool("false") == false)
        #expect(TOML.bool("\"true\"") == nil)
        let table = #"{ light = "a, b", dark = { Custom = { name = "x}", path = "/p" } }, other = [1, 2] }"#
        #expect(TOML.inlineValue(table, key: "dark") == #"{ Custom = { name = "x}", path = "/p" } }"#)
        #expect(TOML.inlineValue(table, key: "light") == #""a, b""#)
        #expect(TOML.inlineValue(table, key: "other") == "[1, 2]")
        #expect(TOML.inlineValue(#"{ light = "dark = 1" }"#, key: "dark") == nil)
        #expect(TOML.inlineValue("{ 'dark' = 'd' } # c", key: "dark") == "'d'")
        #expect(TOML.inlineValue(#""dark""#, key: "dark") == nil)
        let yaml = YAML("a: 1\nb:\n  c: '#fff'\n  d:\n    e: x\nf: y")
        #expect(yaml.values == ["a": "1", "b.c": "#fff", "b.d.e": "x", "f": "y"])
    }
}
