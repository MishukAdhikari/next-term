import AppKit
import NextTermCore

/// The terminals 0.11 adds to the import window (kitty, Alacritty, WezTerm, cmux) and iTerm2's dynamic default
/// profile: each is listed under its own name, its preview shows what comes over and what doesn't (WezTerm's Lua is
/// never run, only named), and with nothing found the window names them. The apps come from a made-up home in a temp
/// folder (the readers never look at yours); no key is typed, so these run whether or not the app is in front. The
/// detectors, the planner and the shortcut set are put back as they were.
extension SelfTest {
    static func importTerminalChecks() async {
        guard AppDelegate.shared != nil else { return note("import of kitty, Alacritty, WezTerm and cmux: skipped, no app") }
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-import-terminals-\(getpid())")
        let home = (root as NSString).appendingPathComponent("home")
        guard makeTerminalHome(home) else {
            try? FileManager.default.removeItem(atPath: root)
            return check(false, "import of the terminals: a made-up home to read", home)
        }
        let applications = [(home as NSString).appendingPathComponent("Applications")]
        let detectors = ImportSources.detectors
        let planner = ImportSources.planner
        let shortcuts = KeyboardShortcuts.shared
        let presetBefore = shortcuts.preset
        let window = ImportWindowController.shared
        defer {
            window.window?.close()
            ImportSources.detectors = detectors
            ImportSources.planner = planner
            shortcuts.preset = presetBefore
            try? FileManager.default.removeItem(atPath: root)
        }
        shortcuts.preset = .nextTerm
        ImportSources.detectors = [
            { ImportKitty.detect(home: home, applications: applications) },
            { ImportAlacritty.detect(home: home, applications: applications) },
            { ImportWezTerm.detect(home: home, applications: applications) },
            { ImportCmux.detect(home: home, applications: applications) },
            { ImportITerm2.detect(home: home, applications: applications) },
        ]
        ImportSources.planner = { app, usKeyboard in
            switch app.kind {
            case .kitty: return ImportKitty.plan(for: app, home: home, usKeyboard: usKeyboard)
            case .alacritty: return ImportAlacritty.plan(for: app, home: home, usKeyboard: usKeyboard)
            case .wezTerm, .kaku: return ImportWezTerm.plan(for: app, home: home, usKeyboard: usKeyboard)
            case .cmux: return ImportCmux.plan(for: app, home: home, usKeyboard: usKeyboard, applications: applications)
            case .iTerm2: return ImportITerm2.plan(for: app, home: home, usKeyboard: usKeyboard)
            default: return nil
            }
        }

        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        let chooser = importWindowTexts(window)
        for name in ["kitty", "Alacritty", "WezTerm", "cmux", "iTerm2"] {
            check(chooser.contains { $0.hasPrefix(name) }, "the import window lists \(name)", chooser.joined(separator: " | "))
        }
        let found = ImportSources.detect()
        check(found.first { $0.kind == .cmux }?.version == "9.9.9", "cmux is detected with its app's version",
              found.map { "\($0.name) \($0.version ?? "none")" }.joined(separator: ", "))
        // A terminal has no file tree: its import leaves the sidebar's click as it is.
        let clicking = found.filter { ImportSources.planner($0, true)?.singleClick != nil }.map(\.name)
        check(!found.isEmpty && clicking.isEmpty, "a terminal's import has no row for the sidebar's click", clicking.joined(separator: ", "))

        if let wezTerm = found.first(where: { $0.kind == .wezTerm }) {
            window.showPreview(for: wezTerm)
            await pause(0.3)
            let all = importWindowTexts(window).joined(separator: "\n")
            check(all.contains("font_size 15"), "WezTerm's written-out font size comes over", all)
            check(all.contains("set by Lua code: line_height") && !all.contains(selfTestSecret),
                  "a value its Lua works out is only named, and nothing from it is shown", all)
            window.window?.close()
        } else {
            check(false, "WezTerm is detected", found.map(\.name).joined(separator: ", "))
        }

        if let kitty = found.first(where: { $0.kind == .kitty }) {
            window.showPreview(for: kitty)
            await pause(0.3)
            let all = importWindowTexts(window).joined(separator: "\n")
            check(all.contains("map cmd+shift+e → launch --location=vsplit") && all.contains("font_size 13"),
                  "kitty's map and font size come over", all)
            check(!all.contains("with a single click") && !all.contains("with a double click"), "and its preview says nothing of the sidebar's click", all)
            window.window?.close()
        }

        if let iTerm = found.first(where: { $0.kind == .iTerm2 }) {
            window.showPreview(for: iTerm)
            await pause(0.3)
            let all = importWindowTexts(window).joined(separator: "\n")
            check(all.contains("Normal Font Menlo 17"), "iTerm2's default profile is found among its dynamic profiles", all)
            window.window?.close()
        }

        ImportSources.detectors = []
        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        let none = importWindowTexts(window).joined(separator: "\n")
        check(none.contains("kitty") && none.contains("Alacritty") && none.contains("WezTerm") && none.contains("cmux"),
              "with nothing found, the window names the terminals it looks for", none)
    }

    /// Never shown: in a value the made-up WezTerm config sets that must not be read (`default_prog`).
    private static let selfTestSecret = "nt-self-test-never-shown-7731"

    /// A home with kitty, Alacritty, WezTerm and cmux configs, cmux's app (Info.plist only) and iTerm2 preferences
    /// whose default profile is a dynamic one.
    private static func makeTerminalHome(_ home: String) -> Bool {
        let files: [String: String] = [
            ".config/kitty/kitty.conf": "font_size 13\nmap cmd+shift+e launch --location=vsplit\n",
            ".config/alacritty/alacritty.toml": "[font]\nsize = 16\n",
            ".config/wezterm/wezterm.lua": """
                local config = {}
                local base = 10
                config.font_size = 15
                config.line_height = base / 8
                config.default_prog = { 'zsh', '-c', 'export T=\(selfTestSecret)' }
                return config
                """,
            ".config/cmux/cmux.json": #"{ "shortcuts": { "bindings": { "newSurface": "cmd+shift+t" } } }"#,
            "Applications/cmux.app/Contents/Info.plist": """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>9.9.9</string></dict></plist>
                """,
            "Library/Preferences/com.googlecode.iterm2.plist": """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                <key>Default Bookmark Guid</key><string>NT-DYN</string>
                <key>New Bookmarks</key><array><dict><key>Guid</key><string>NT-REG</string><key>Normal Font</key><string>Monaco 12</string></dict></array>
                </dict></plist>
                """,
            "Library/Application Support/iTerm2/DynamicProfiles/nt.json":
                #"{ "Profiles": [ { "Guid": "NT-DYN", "Name": "Self-Test", "Normal Font": "Menlo 17" } ] }"#,
        ]
        do {
            for (path, text) in files {
                let full = (home as NSString).appendingPathComponent(path)
                try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try text.write(toFile: full, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }
}
