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
        let app = try #require(ImportWarp.detect(home: home).first)
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
        #expect(ImportWarp.detect(home: home).isEmpty)
        let used = Date(timeIntervalSince1970: 1_790_000_000)
        try write("", to: home + "/.warp/settings.toml", date: used)
        #expect(ImportWarp.detect(home: home) == [DetectedApp(kind: .warp, name: "Warp", configPath: home + "/.warp", lastUsed: used)])
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
            PlannedSetting(.fontSize(14), source: "font_size 14", note: "sets the editor too: Next Term has one size for both"),
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
