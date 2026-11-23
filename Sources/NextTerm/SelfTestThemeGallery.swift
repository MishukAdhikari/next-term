import AppKit
import NextTermCore

/// Every theme Next Term ships, one by one: its colours checked against its own paper and bars, then the theme chosen as
/// Settings › General chooses it, every part of the window taking it at once, and a screenshot of the window with code
/// in the editor and every terminal colour on screen, for the owner's eye.
extension SelfTest {
    static func themeGalleryChecks(_ c: TerminalWindowController) async {
        // Next Term's own pair keep their own checks (themeChecks); every theme added since is held to these.
        for palette in ThemePalette.builtIn where ![ThemePalette.nextDark.id, ThemePalette.nextLight.id].contains(palette.id) {
            paletteChecks(palette)
        }
        check(Set(ThemePalette.builtIn.map(\.id)).count == ThemePalette.builtIn.count
              && Set(ThemePalette.builtIn.map(\.name)).count == ThemePalette.builtIn.count, "themes: each has its own id and name")

        guard c.window != nil else { return check(false, "themes: a window") }
        let saved = (Preferences.appearance, Preferences.lightTheme, Preferences.darkTheme)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-themes-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Preferences.lightTheme = saved.1
            Preferences.darkTheme = saved.2
            Preferences.appearance = saved.0
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("Sample.swift")
        try? sampleCode.write(to: file, atomically: true, encoding: .utf8)
        c.openFile(file)
        if let tab = c.activeTab ?? c.tabs.first {
            _ = await wait(10) { tab.status.integrated }
            tab.view.feed(text: ansiSample)
        }
        for palette in ThemePalette.builtIn {
            if palette.isDark { Preferences.darkTheme = palette.id } else { Preferences.lightTheme = palette.id }
            Preferences.appearance = palette.isDark ? .dark : .light
            await pause(0.8)
            let misses = themeMisses([c], palette)
            check(misses.isEmpty, "themes: \(palette.name) chosen, every part of the window takes it at once", misses.joined(separator: "; "))
            await screenshot(c, suffix: "-themes-\(palette.id)")
            await screenshotParts(c, suffix: "-themes-\(palette.id)")
        }
        await themedSelectionChecks(c, root: root)
    }

    /// Selected rows in every theme: a database's grid and its record list, one focused and one not. Both are drawn
    /// in the theme's selection tint with the text keeping its colour, never AppKit's saturated accent fill (dark
    /// text on a strong blue was unreadable in light themes).
    static func themedSelectionChecks(_ c: TerminalWindowController, root: URL) async {
        guard let window = c.window else { return }
        let store = CellStore(in: root.appendingPathComponent("store"))
        let area = c.editorArea
        area.openDatabase(store.path)
        guard let pane = area.activeDatabase else { return check(false, "themes: a database opens for the selection screenshots") }
        defer { area.closeAll() }
        _ = await wait(5) { pane.isSettled && pane.page != nil }
        pane.select(table: "messages")
        _ = await wait(5) { pane.isSettled && pane.page?.table == "messages" }
        guard let content = pane.page?.columns.firstIndex(of: "content") else { return check(false, "themes: messages' columns") }
        CellHand(window: window, byHand: false).click(pane.grid, row: 62, column: content)
        _ = await wait(3) { pane.isDetailShown && pane.detail.detail?.body == "message 63" }
        pane.detail.rowList.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window.makeFirstResponder(pane.detail.rowList)
        for palette in ThemePalette.builtIn {
            if palette.isDark { Preferences.darkTheme = palette.id } else { Preferences.lightTheme = palette.id }
            Preferences.appearance = palette.isDark ? .dark : .light
            await pause(0.6)
            let lists: [NSTableView] = [pane.grid, pane.detail.rowList]
            let plain = lists.compactMap { list -> String? in
                let row = list.selectedRow
                guard row >= 0, let view = list.rowView(atRow: row, makeIfNecessary: false) else { return nil }
                return view is ThemedRowView ? nil : "\(type(of: list))'s row \(row + 1) is \(type(of: view))"
            }
            check(plain.isEmpty, "themes: \(palette.name) draws selected rows in its own selection tint", plain.joined(separator: "; "))
            await screenshot(c, suffix: "-themes-selection-\(palette.id)")
        }
    }

    /// One theme's colours against its own paper and bars: text 4.5:1, quiet marks 3:1, the terminal's and the code's.
    static func paletteChecks(_ p: ThemePalette) {
        let ratio = ThemePalette.contrast
        let texts: [(String, UInt32)] = [("text", p.text), ("textDim", p.textDim), ("accent", p.accent), ("working", p.working),
                                         ("done", p.done), ("failed", p.failed), ("attention", p.attention),
                                         ("gitModified", p.gitModified), ("gitAdded", p.gitAdded), ("gitUntracked", p.gitUntracked),
                                         ("gitConflicted", p.gitConflicted), ("linesAdded", p.linesAdded), ("linesRemoved", p.linesRemoved),
                                         ("blameText", p.blameText), ("blameRecent", p.blameRecent)]
        let weak = texts.filter { ratio($0.1, p.background) < 4.5 || ratio($0.1, p.bar) < 4.5 }.map(\.0)
        check(weak.isEmpty, "themes: \(p.name)'s text and marks read 4.5:1 on its paper and bars", weak.joined(separator: ", "))
        let quiet: [(String, UInt32)] = [("doneQuiet", p.doneQuiet), ("gitIgnored", p.gitIgnored), ("blameHash", p.blameHash),
                                         ("blameNote", p.blameNote), ("lineNumber", p.lineNumber), ("lineNumberCurrent", p.lineNumberCurrent),
                                         ("gutterAdded", p.gutterAdded), ("gutterModified", p.gutterModified), ("gutterDeleted", p.gutterDeleted)]
        let faint = quiet.filter { ratio($0.1, p.background) < 3 || ratio($0.1, p.bar) < 3 }.map(\.0)
        check(faint.isEmpty, "themes: \(p.name)'s quiet marks stand 3:1", faint.joined(separator: ", "))
        let t = p.terminal
        let slots = p.isDark ? Array(1...7) + Array(9...15) : Array(0...15)
        let ansiWeak = slots.filter { ratio(t.ansi[$0], t.background) < 4.5 }
        check(t.ansi.count == 16 && ansiWeak.isEmpty && ratio(t.foreground, t.background) >= 7 && ratio(t.ansi[8], t.background) >= (p.isDark ? 2.5 : 4.5),
              "themes: \(p.name)'s terminal colours read on its terminal", "weak slots \(ansiWeak)")
        let codeWeak = p.code.filter { ratio($0.value, p.background) < 4.5 }.map(\.key)
        check(codeWeak.isEmpty, "themes: \(p.name)'s code colours read on its paper", codeWeak.joined(separator: ", "))
        let distinct: [(String, UInt32, UInt32)] = [("working/done", p.working, p.done), ("done/failed", p.done, p.failed),
                                                     ("attention/failed", p.attention, p.failed), ("modified/added", p.gitModified, p.gitAdded)]
        let alike = distinct.filter { hueGap($0.1, $0.2) < 35 }.map(\.0)
        check(alike.isEmpty, "themes: \(p.name)'s marks are told apart by hue", alike.joined(separator: ", "))
    }

    /// The gap between two colours' hues, in degrees (HSB).
    static func hueGap(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (NSColor(hex: a).usingColorSpace(.sRGB)!.hueComponent, NSColor(hex: b).usingColorSpace(.sRGB)!.hueComponent)
        let d = abs(x - y) * 360
        return min(d, 360 - d)
    }

    static let ansiSample: String = {
        var s = "\r\n"
        for row in [0, 8] {
            for i in 0..<8 { s += "\u{1B}[\(row == 0 ? 30 + i : 90 + i)m ansi\(row + i) " }
            s += "\u{1B}[0m\r\n"
        }
        s += "\u{1B}[32m✓ done\u{1B}[0m  \u{1B}[31m✗ failed\u{1B}[0m  \u{1B}[33m! warning\u{1B}[0m  \u{1B}[34mhttps://example.com\u{1B}[0m  \u{1B}[1mbold\u{1B}[0m  \u{1B}[2mdim\u{1B}[0m\r\n"
        return s
    }()

    static let sampleCode = """
    import Foundation

    /// A greeting, said once per name.
    @MainActor
    struct Greeter: Sendable {
        let names: [String]
        var count = 3 // how many times

        func greet(_ name: String) -> String {
            guard !name.isEmpty else { return "Hello, nobody" }
            let pi = 3.14159, hex = 0xFF
            return "Hello, \\(name)! \\(pi) \\(hex)"
        }
    }

    for name in ["Ada", "Linus"] where name.count > 2 {
        print(Greeter(names: []).greet(name))
    }

    """
}
