import Foundation
import Testing
@testable import NextTermCore

/// Fixtures are written into a fresh temporary home per test; the real home is never read.
@Suite struct ImportGhosttyTests {
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-import-gh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, to path: String, date: Date? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    let xdg = "/.config/ghostty/config"
    let appSupport = "/Library/Application Support/com.mitchellh.ghostty/config.ghostty"

    func plan(_ config: String, files: [String: String] = [:], usKeyboard: Bool = true) throws -> ImportPlan {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(config, to: home + appSupport)
        for (path, text) in files { try write(text, to: home + path) }
        let app = try #require(ImportGhostty.detect(home: home).first)
        return ImportGhostty.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts, applications: [home + "/Applications"])
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func detection() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ImportGhostty.detect(home: home).isEmpty)
        try FileManager.default.createDirectory(atPath: home + xdg, withIntermediateDirectories: true)
        #expect(ImportGhostty.detect(home: home).isEmpty, "a folder is not a config file")
        try FileManager.default.removeItem(atPath: home + xdg)

        let older = Date(timeIntervalSince1970: 1_790_000_000), newer = Date(timeIntervalSince1970: 1_791_000_000)
        try write("font-size = 13", to: home + xdg, date: newer)
        try write("# empty", to: home + appSupport, date: older)
        let app = try #require(ImportGhostty.detect(home: home).first)
        #expect(app == DetectedApp(kind: .ghostty, name: "Ghostty", configPath: home + appSupport, lastUsed: newer))
        #expect(app.preset == .nextTerm)
    }

    @Test func fontSizeAndOption() throws {
        let plan = try self.plan("""
            # my config
            font-family = "Operator Mono"
            font-family = JetBrains Mono
            font-size = 14.5
            macos-option-as-alt = true
            """)
        #expect(plan.settings == [
            PlannedSetting(.terminalFontFamily("JetBrains Mono"), source: "font-family Operator Mono, JetBrains Mono",
                           note: "the first font in the list that this Mac has"),
            PlannedSetting(.fontSize(15), source: "font-size 14.5", note: "sets the editor too: Next Term has one size for both"),
            PlannedSetting(.optionAsMeta(true), source: "macos-option-as-alt true"),
        ])
        #expect(plan.skipped == [SkippedItem("Terminal font “Operator Mono”", "not installed on this Mac")])

        // An empty font-family starts the list again; later files win.
        let reset = try self.plan("font-family = Hack\nfont-family =\nfont-family = Menlo")
        #expect(reset.settings.first?.setting == .terminalFontFamily("Menlo"))

        // One side only, or a layout that needs Option: offered, not ticked.
        let left = try self.plan("macos-option-as-alt = left")
        #expect(left.settings.first?.ticked == false)
        #expect(left.settings.first?.note == "on in Ghostty for Left Option only; Next Term can't set one side yet")
        #expect(try self.plan("macos-option-as-alt = true", usKeyboard: false).settings.first?.ticked == false)
        #expect(try self.plan("macos-option-as-alt = false").settings == [PlannedSetting(.optionAsMeta(false), source: "macos-option-as-alt false")])
        #expect(reasons(try self.plan("font-size = big"))["font-size"] == "not a font size Next Term can use")
    }

    @Test func coloursFromAThemeAndTheConfig() throws {
        let theme = """
            palette = 0=#1d1f21
            palette = 1=#cc6666
            background = 1d1f21
            foreground = #c5c8c6
            cursor-color = #aeafad
            selection-background = #373b41
            font-size = 30
            """
        let plan = try self.plan("""
            theme = light:Paper,dark:Tomorrow Night
            palette = 1=#ff0000
            palette = 200=#123456
            foreground = white
            """, files: ["/.config/ghostty/themes/Tomorrow Night": theme])
        var ansi: [UInt32?] = Array(repeating: nil, count: 16)
        ansi[0] = 0x1D1F21
        ansi[1] = 0xFF0000 // the config's own colour wins over the theme's
        let palette = TerminalPalette(name: "Ghostty colours", ansi: ansi, foreground: nil, background: 0x1D1F21, cursor: 0xAEAFAD, selection: 0x373B41)
        #expect(plan.settings == [PlannedSetting(.terminalPalette(palette), source: "theme Tomorrow Night and your colour settings",
                                                 note: "5 of 20 colours; the others stay Next Term's")])
        #expect(plan.skipped == [SkippedItem("foreground", "only #rrggbb colours are read, not colour names"),
                                 SkippedItem("palette colours 16–255", "Next Term sets the first 16 colours only")])

        // A bundled theme, from Ghostty.app; a missing one; a path.
        let bundled = try self.plan("theme = Dracula", files: ["/Applications/Ghostty.app/Contents/Resources/ghostty/themes/Dracula": "background = #282a36"])
        #expect(bundled.settings.first?.source == "theme Dracula")
        #expect(reasons(try self.plan("theme = Nowhere"))["theme Nowhere"] == "not found in Ghostty's themes folders")
        #expect(reasons(try self.plan("theme = /etc/passwd"))["theme"] == "only a theme given by name is read")
        #expect(reasons(try self.plan("theme = ../../secret"))["theme"] == "only a theme given by name is read")
    }

    @Test func keybinds() throws {
        let plan = try self.plan("""
            keybind = super+d=new_split:right
            keybind = cmd+shift+bracket_left=previous_tab
            keybind = ctrl+a>n=new_tab
            keybind = global:cmd+grave_accent=toggle_quick_terminal
            keybind = cmd+k=text:\\x15ghp_abcdefghijklmnopqrstuvwxyz0123
            keybind = ctrl+t=new_tab
            """)
        #expect(plan.shortcuts.map(\.command) == ["splitRight:", "showPreviousTab:", "newTab:"])
        #expect(plan.shortcuts[0].chord == KeyChord(key: "d", command: true))
        #expect(plan.shortcuts[0].source == "keybind super+d → new_split:right")
        #expect(plan.shortcuts[1].chord == KeyChord(key: "[", command: true, shift: true))
        #expect(plan.shortcuts[2].allowed == false, "a Control key without ⌘ stays with the shell")
        #expect(reasons(plan)["keybind ctrl+a>n → new_tab"] == "two-step keys aren't supported yet")
        #expect(reasons(plan)["2 keybinds"] == "no matching Next Term command, or they send text to the terminal")
        #expect(!"\(plan)".contains("ghp_"), "text a keybind sends is never shown")

        // A later line for the same key replaces an earlier one, however it spells the key; `unbind` leaves
        // the key without a command.
        let replaced = try self.plan("""
            keybind = super+d=new_split:right
            keybind = cmd+d=unbind
            keybind = super+shift+t=new_tab
            keybind = performable:shift+super+t=ignore
            keybind = cmd+t=new_tab
            keybind = command+t=new_window
            """)
        #expect(replaced.shortcuts.map(\.command) == ["newWindow:"])
        #expect(replaced.shortcuts.first?.source == "keybind command+t → new_window")
        #expect(reasons(replaced)["2 keybinds"] == "no matching Next Term command, or they send text to the terminal")
        // The = key: Ghostty's first "=" that isn't followed by "+" or "=" ends the trigger.
        let equals = try self.plan("keybind = super+==increase_font_size:1\nkeybind = super+-=text:=-")
        #expect(equals.shortcuts.map(\.command) == ["increaseFontSize:"])
        #expect(equals.shortcuts.first?.chord == KeyChord(key: "=", command: true))
        #expect(ImportGhostty.triggerID("global:Shift+Super+bracket_left") == "cmd+shift+[bracketleft]")

        // `keybind = clear` drops the ones before it.
        #expect(try self.plan("keybind = cmd+d=new_split:right\nkeybind = clear").shortcuts.isEmpty)
        // Every action lands on a command an import may set (the self-test checks those are in the menus).
        for (action, command) in ImportGhostty.actions { #expect(ImportShortcuts.titles[command] != nil, "\(action)") }
    }

    /// Ghostty keeps a key given by its place (`bracket_left`, `equal`, `key_d`) apart from the character it
    /// types (`[`, `=`, `d`), and looks a key press up by its place first.
    @Test func keysByPlaceAndByCharacter() throws {
        // Unbinding the character leaves the key by its place bound, and the other way round.
        let unbound = try self.plan("keybind = super+bracket_left=previous_tab\nkeybind = super+[=unbind")
        #expect(unbound.shortcuts.map(\.command) == ["showPreviousTab:"])
        #expect(unbound.shortcuts.first?.chord == KeyChord(key: "[", command: true))
        let quote = try self.plan("keybind = super+quote=next_tab\nkeybind = super+apostrophe=unbind")
        #expect(quote.shortcuts.map(\.command) == ["showNextTab:"])
        let letter = try self.plan("keybind = super+d=new_split:right\nkeybind = super+key_d=unbind")
        #expect(letter.shortcuts.map(\.command) == ["splitRight:"])

        // Both bound: the key by its place wins, whichever line comes later, and even when what it does has no
        // Next Term command.
        for config in ["keybind = super+equal=reset_font_size\nkeybind = super+==increase_font_size:1",
                       "keybind = super+==increase_font_size:1\nkeybind = super+equal=reset_font_size"] {
            let both = try self.plan(config)
            #expect(both.shortcuts.map(\.command) == ["resetFontSize:"], "\(config)")
            #expect(both.shortcuts.first?.chord == KeyChord(key: "=", command: true))
        }
        let text = try self.plan("keybind = super+key_d=text:hi\nkeybind = super+d=new_split:right")
        #expect(text.shortcuts.isEmpty)
        #expect(reasons(text)["1 keybind"] == "no matching Next Term command, or they send text to the terminal")

        // Ghostty 1.1's names are the same keys as today's: left_bracket is bracket_left, apostrophe is '.
        let old = try self.plan("""
            keybind = super+left_bracket=previous_tab
            keybind = super+bracket_left=unbind
            keybind = super+apostrophe=next_tab
            keybind = super+'=unbind
            """)
        #expect(old.shortcuts.isEmpty)

        // On another layout the key by its place types something else, so only the character's binding comes over.
        let layout = try self.plan("keybind = super+bracket_left=previous_tab\nkeybind = super+[=next_tab", usKeyboard: false)
        #expect(layout.shortcuts.map(\.command) == ["showNextTab:"])
        #expect(reasons(layout)["keybind super+bracket_left → previous_tab"]
                == "given by its place on the keyboard, which types something else on your layout")

        #expect(ImportGhostty.triggerID("super+left_bracket") == ImportGhostty.triggerID("cmd+bracket_left"))
        #expect(ImportGhostty.triggerID("super+[") != ImportGhostty.triggerID("cmd+bracket_left"))
        #expect(ImportGhostty.triggerID("ctrl++") == ImportGhostty.triggerID("control+plus"))
    }

    /// Ghostty reads a trigger's key before its modifiers too, and turns down one with a modifier twice or two keys.
    @Test func triggerOrder() throws {
        // `=+super` is super+=, so the later line wins.
        let equals = try self.plan("keybind = super+==increase_font_size:1\nkeybind = =+super=reset_font_size")
        #expect(equals.shortcuts.map(\.command) == ["resetFontSize:"])
        #expect(equals.shortcuts.first?.chord == KeyChord(key: "=", command: true))
        let keyFirst = try self.plan("keybind = d+shift+super=new_split:down")
        #expect(keyFirst.shortcuts.first?.chord == KeyChord(key: "d", command: true, shift: true))

        // A line Ghostty turns down replaces nothing.
        let refused = try self.plan("""
            keybind = super+d=new_split:right
            keybind = super+cmd+d=unbind
            keybind = super+d+e=unbind
            keybind = super+t=new_tab
            keybind = super+super+t=new_window
            """)
        #expect(refused.shortcuts.map(\.command) == ["splitRight:", "newTab:"])
        #expect(reasons(refused)["keybind super+super+t → new_window"] == "key not recognised")
        #expect(ImportGhostty.triggerID("a+shift") == ImportGhostty.triggerID("shift+a"))
        #expect(ImportGhostty.triggerID("shift+shift+a") == nil)

        // Ghostty reads each step of a two-step key on its own, so a later line for the same steps replaces it.
        #expect(ImportGhostty.triggerID("ctrl+a>ctrl+n") == ImportGhostty.triggerID("control+a>control+n"))
        #expect(ImportGhostty.triggerID("ctrl+a>ctrl+n") != ImportGhostty.triggerID("ctrl+a>shift+n"))
        #expect(ImportGhostty.triggerID("ctrl+a>") == nil)
        let steps = try self.plan("keybind = ctrl+a>ctrl+n=new_tab\nkeybind = control+a>control+n=unbind")
        #expect(reasons(steps)["keybind ctrl+a>ctrl+n → new_tab"] == nil)
        #expect(reasons(steps)["1 keybind"] != nil)
    }

    @Test func safety() throws {
        let plan = try self.plan("""
            command = /bin/zsh -c 'export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123'
            initial-command = ssh prod-db.internal.example
            env = OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx
            working-directory = /Users/someone/private-folder
            window-padding-x = 4
            config-file = ?extra.conf
            config-file = /etc/hosts
            config-file = ../../outside
            """, files: ["/Library/Application Support/com.mitchellh.ghostty/extra.conf": "font-size = 16\nconfig-file = config.ghostty"])
        let shown = "\(plan)"
        for value in ["ghp_", "prod-db", "sk-proj", "private-folder", "/etc/hosts", "outside"] {
            #expect(!shown.contains(value), "\(value) reached the plan")
        }
        // The include inside Ghostty's folder is read (and a loop of includes stops).
        #expect(plan.settings.map(\.setting) == [.fontSize(16)])
        #expect(reasons(plan)["command"] == "never imported: runs commands or can hold secrets")
        #expect(reasons(plan)["env"] == "never imported: runs commands or can hold secrets")
        #expect(reasons(plan)["working-directory"] == "a start folder setting comes later")
        #expect(reasons(plan)["config-file"] == "only files in Ghostty's own folders are read")
        #expect(reasons(plan)["other settings: window-padding-x"] == "no matching Next Term setting yet")

        // No networking or process launching in the importer.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NextTermCore/ImportGhostty.swift"), encoding: .utf8)
        for word in ["URLSession", "import Network", "NWConnection", "URLRequest", "Process(", "NSTask"] {
            #expect(!source.contains(word), "\(word)")
        }
    }

    /// A plan from files alone (paths under the temporary home); `links` are symlinks, path → target.
    func plan(files: [String: String], links: [String: String] = [:]) throws -> ImportPlan {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for (path, text) in files { try write(text, to: home + path) }
        for (path, target) in links {
            try FileManager.default.createDirectory(atPath: (home + path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: home + path, withDestinationPath: home + target)
        }
        let app = try #require(ImportGhostty.detect(home: home).first)
        return ImportGhostty.plan(for: app, home: home, fonts: testFonts, applications: [home + "/Applications"])
    }

    /// Ghostty reads its own files first and the includes after them, in the order they are listed.
    @Test func includesComeAfterGhosttysOwnFiles() throws {
        let later = try plan(files: [xdg: "config-file = local.conf\nfont-size = 10", "/.config/ghostty/local.conf": "font-size = 14",
                                     appSupport: "font-size = 12"])
        #expect(later.settings.map(\.setting) == [.fontSize(14)])

        let breadthFirst = try plan(files: [
            xdg: "config-file = a.conf\nconfig-file = b.conf",
            "/.config/ghostty/a.conf": "config-file = c.conf", "/.config/ghostty/b.conf": "font-size = 15",
            "/.config/ghostty/c.conf": "font-size = 17",
        ])
        #expect(breadthFirst.settings.map(\.setting) == [.fontSize(17)])
    }

    @Test func includePaths() throws {
        // `~/` is the home folder.
        let tilde = try plan(files: [xdg: "config-file = ~/.config/ghostty/local.conf", "/.config/ghostty/local.conf": "font-size = 14"])
        #expect(tilde.settings.map(\.setting) == [.fontSize(14)])
        #expect(tilde.skipped.isEmpty)

        // A symlinked config (stow, chezmoi): an include is relative to where the config was opened from.
        let linked = try plan(files: ["/dotfiles/ghostty/config": "config-file = theme.conf", "/.config/ghostty/theme.conf": "font-size = 18",
                                      "/dotfiles/ghostty/theme.conf": "font-size = 20"],
                              links: [xdg: "/dotfiles/ghostty/config"])
        #expect(linked.settings.map(\.setting) == [.fontSize(18)])
        #expect(linked.skipped.isEmpty)

        // A missing include is reported unless it is marked optional.
        let missing = try plan(files: [xdg: "config-file = gone.conf\nconfig-file = ?maybe.conf"])
        #expect(missing.skipped == [SkippedItem("config-file gone.conf", "file not found")])

        // `~/` elsewhere in the home folder is still outside Ghostty's folders.
        let outside = try plan(files: [xdg: "config-file = ~/secrets.conf", "/secrets.conf": "font-size = 30"])
        #expect(outside.settings.isEmpty)
        #expect(reasons(outside)["config-file"] == "only files in Ghostty's own folders are read")
    }

    @Test func parsing() {
        #expect(ImportGhostty.parse("# c\n a = b \nkeybind = cmd+d=new_split:right\nx = \"quoted\"\nnovalue\n= y") == [
            ImportGhostty.Entry(key: "a", value: "b"), ImportGhostty.Entry(key: "keybind", value: "cmd+d=new_split:right"),
            ImportGhostty.Entry(key: "x", value: "quoted"),
        ])
        #expect(ImportGhostty.themeName("light:A,dark:B") == "B")
        #expect(ImportGhostty.themeName("light:A") == nil)
        #expect(ImportGhostty.themeName(".hidden") == nil)
    }
}
