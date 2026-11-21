import AppKit
import NextTermCore

/// The light look (plan 049): the palette's contrast, and a live switch between Light and Dark that reaches the window,
/// a layer set once (the sidebar's), and the terminal, with a screenshot of each.
extension SelfTest {
    static func themeChecks(_ c: TerminalWindowController) async {
        let light = ThemePalette.nextLight
        let ratio = ThemePalette.contrast
        let texts: [(String, UInt32)] = [("text", light.text), ("textDim", light.textDim), ("accent", light.accent), ("failed", light.failed)]
        let weak = texts.filter { ratio($0.1, light.background) < 4.5 || ratio($0.1, light.bar) < 4.5 }.map(\.0)
        check(weak.isEmpty, "theme: the light look's text reads 4.5:1 on the window and on the bars", weak.joined(separator: ", "))
        let marks: [(String, UInt32)] = [("done", light.done), ("doneQuiet", light.doneQuiet), ("attention", light.attention),
                                         ("gitModified", light.gitModified), ("gitAdded", light.gitAdded), ("gitUntracked", light.gitUntracked),
                                         ("linesAdded", light.linesAdded), ("linesRemoved", light.linesRemoved)]
        let faint = marks.filter { ratio($0.1, light.bar) < 3 }.map { "\($0.0) \(String(format: "%.1f", ratio($0.1, light.bar)))" }
        check(faint.isEmpty, "theme: the light look's marks and git colours stand 3:1 on the bars", faint.joined(separator: ", "))
        let t = light.terminal
        let ansiWeak = (Array(1...6) + Array(9...14)).filter { ratio(t.ansi[$0], t.background) < 4.5 }
        check(ansiWeak.isEmpty && ratio(t.foreground, t.background) >= 7 && t.background != 0xFFFFFF,
              "theme: the light terminal is soft paper, not glaring white, and its colours read on it, yellow included", "weak slots \(ansiWeak)")
        let codeWeak = light.code.filter { ratio($0.value, light.background) < 3 }.map(\.key)
        check(codeWeak.isEmpty, "theme: the light code colours read on the paper", codeWeak.joined(separator: ", "))

        guard let window = c.window, let tab = c.tabs.first else { return check(false, "theme: a window with a terminal") }
        let saved = Preferences.appearance
        defer { Preferences.appearance = saved }
        func hex(_ cg: CGColor?) -> UInt32? {
            guard let cg, let color = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return nil }
            return UInt32((color.redComponent * 255).rounded()) << 16 | UInt32((color.greenComponent * 255).rounded()) << 8
                | UInt32((color.blueComponent * 255).rounded())
        }
        func sidebarFill() -> UInt32? {
            var queue: [NSView] = [window.contentView].compactMap { $0 }
            while let view = queue.popLast() {
                if view is ProjectSidebarView { return hex(view.layer?.backgroundColor) }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
        func terminalBackground() -> UInt32? { hex(tab.view.nativeBackgroundColor.cgColor) }

        Preferences.appearance = .light
        _ = await wait(3) { Theme.isLight && terminalBackground() == light.terminal.background }
        check(Theme.isLight && !Theme.isDark(window.effectiveAppearance), "theme: Light makes the window light")
        check(terminalBackground() == light.terminal.background, "theme: the terminal takes the light palette at once",
              terminalBackground().map { String($0, radix: 16) } ?? "none")
        let lightSidebar = sidebarFill()
        check(lightSidebar == nil || lightSidebar == light.bar, "theme: a layer set once (the sidebar) takes the light bar",
              lightSidebar.map { String($0, radix: 16) } ?? "no sidebar")
        await screenshot(c, suffix: "-theme-light")

        Preferences.appearance = .dark
        let dark = ThemePalette.nextDark
        _ = await wait(3) { !Theme.isLight && terminalBackground() == dark.terminal.background }
        check(terminalBackground() == dark.terminal.background, "theme: back to Dark, the terminal is dark again",
              terminalBackground().map { String($0, radix: 16) } ?? "none")
        let darkSidebar = sidebarFill()
        check(darkSidebar == nil || darkSidebar == dark.bar, "theme: and the sidebar's layer dark again",
              darkSidebar.map { String($0, radix: 16) } ?? "no sidebar")
        await screenshot(c, suffix: "-theme-dark")
    }
}
