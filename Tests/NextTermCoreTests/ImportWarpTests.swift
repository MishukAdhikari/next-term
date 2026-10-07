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

    func plan(_ settings: String, files: [String: String] = [:], usKeyboard: Bool = true) throws -> ImportPlan {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(settings, to: home + "/.warp/settings.toml")
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
        let palette = TerminalPalette(name: "Warp colours", ansi: ansi, foreground: 0x839496, background: 0x002B36)
        #expect(plan.settings == [
            PlannedSetting(.terminalFontFamily("JetBrains Mono"), source: "font_name JetBrains Mono"),
            PlannedSetting(.fontSize(14), source: "font_size 14", note: "sets the editor too: Next Term has one size for both"),
            PlannedSetting(.optionAsMeta(true), source: "extra_meta_keys left_alt, right_alt"),
            PlannedSetting(.terminalPalette(palette), source: "theme my_theme.yaml", note: "6 of 20 colours; the others stay Next Term's"),
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

    @Test func tomlAndYAMLSubsets() {
        #expect(TOML.string(#""a \"b\" c" # note"#) == #"a "b" c"#)
        #expect(TOML.string("'C:\\path'") == "C:\\path")
        #expect(TOML.string("13") == nil)
        #expect(TOML.number("13.5 # size") == 13.5)
        #expect(TOML.strings(#"["a", 'b']"#) == ["a", "b"])
        #expect(TOML.strings(#"["a", 3]"#) == nil)
        #expect(TOML.depthChange("[ 'a]' , \"b[\" # ]") == 1)
        #expect(TOML.tableName("[appearance.text] # c") == "appearance.text")
        let yaml = YAML("a: 1\nb:\n  c: '#fff'\n  d:\n    e: x\nf: y")
        #expect(yaml.values == ["a": "1", "b.c": "#fff", "b.d.e": "x", "f": "y"])
    }
}
