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
        _ = await wait(3) { Theme.isLight && terminalBackground() == light.terminal.background && [nil, light.bar].contains(sidebarFill()) }
        check(Theme.isLight && !Theme.isDark(window.effectiveAppearance), "theme: Light makes the window light")
        check(terminalBackground() == light.terminal.background, "theme: the terminal takes the light palette at once",
              terminalBackground().map { String($0, radix: 16) } ?? "none")
        let lightSidebar = sidebarFill()
        check(lightSidebar == nil || lightSidebar == light.bar, "theme: a layer set once (the sidebar) takes the light bar",
              lightSidebar.map { String($0, radix: 16) } ?? "no sidebar")
        await screenshot(c, suffix: "-theme-light")

        Preferences.appearance = .dark
        let dark = ThemePalette.nextDark
        _ = await wait(3) { !Theme.isLight && terminalBackground() == dark.terminal.background && [nil, dark.bar].contains(sidebarFill()) }
        check(terminalBackground() == dark.terminal.background, "theme: back to Dark, the terminal is dark again",
              terminalBackground().map { String($0, radix: 16) } ?? "none")
        let darkSidebar = sidebarFill()
        check(darkSidebar == nil || darkSidebar == dark.bar, "theme: and the sidebar's layer dark again",
              darkSidebar.map { String($0, radix: 16) } ?? "no sidebar")
        await screenshot(c, suffix: "-theme-dark")
        await themeSwitchChecks(c)
    }

    /// Light and Dark switched live, both ways, the way the owner switched: every part of every window takes the look, a
    /// window merged behind another as a macOS tab and a tab not in front included. Each part is checked by its fill as
    /// drawn (a layer's colour, the terminal's palette, the glow's gradient), so a part left in the other look shows.
    static func themeSwitchChecks(_ c: TerminalWindowController) async {
        guard let host = c.window else { return }
        let saved = Preferences.appearance
        // Windows merge in this check only (SelfTest.run pins it off for the others).
        WindowTabbing.suppressed = false
        NSWindow.allowsAutomaticWindowTabbing = true
        let wasShown = ProjectColorStore.isShown
        ProjectColorStore.isShown = true
        // The window column too, unfolded, as the owner has it: it is in the screenshots, and in the look like the rest.
        let app: AppDelegate = AppDelegate.shared
        let column: (shown: Bool, expanded: Bool) = (app.showsWindowColumn, app.windowColumnExpanded)
        WindowColumns.suppressed = false
        app.showsWindowColumn = true
        app.windowColumnExpanded = true
        app.windowColumns.rebuild()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-theme-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let back = c.addTab(directory: nil, select: false) // a tab not in front
        let other = AppDelegate.shared.openWindow(directory: root.path, project: root.path)
        let apartFolder = root.appendingPathComponent("apart")
        try? FileManager.default.createDirectory(at: apartFolder, withIntermediateDirectories: true)
        let apart = AppDelegate.shared.openWindow(directory: apartFolder.path, project: apartFolder.path) // a window of its own, behind
        defer {
            if host.tabGroup?.windows.count ?? 0 > 1 { other.window?.moveTabToNewWindow(nil) }
            for tab in other.tabs { other.remove(tab) }
            for tab in apart.tabs { apart.remove(tab) }
            c.remove(back)
            WindowTabbing.suppressed = true
            NSWindow.allowsAutomaticWindowTabbing = false
            ProjectColorStore.isShown = wasShown
            app.showsWindowColumn = column.shown
            app.windowColumnExpanded = column.expanded
            WindowColumns.suppressed = true
            app.windowColumns.rebuild()
            Preferences.appearance = saved
            try? FileManager.default.removeItem(at: root)
        }
        _ = await wait(20) { other.tabs.first?.status.integrated == true && apart.tabs.first?.status.integrated == true }
        var merged = false
        if let second = other.window, await bringToFront(host) {
            host.tabbingMode = .automatic
            host.tabbingIdentifier = WindowTabbing.projectIdentifier
            host.addTabbedWindow(second, ordered: .above)
            host.makeKeyAndOrderFront(nil) // the second behind, as the owner's was
            merged = await wait(3) { host.tabGroup?.windows.count == 2 && second.isBackgroundTab }
        }
        if !merged { note("theme: the second window isn't merged as a tab (Next Term not in front); it is checked as a window of its own") }

        // The window apart off screen, as a window in another Space or minimized is: AppKit brings its views' look up to
        // date only when it shows again, so what is set from that look in one pass meanwhile would be the old one.
        apart.window?.miniaturize(nil)
        _ = await wait(3) { apart.window?.isMiniaturized == true }
        // As the owner switches: in Settings › General, its window in front and the project windows behind it.
        AppDelegate.shared.showSettings(tab: "general")
        defer { general()?.window?.close() }
        func general() -> GeneralSettingsView? {
            var queue: [NSView] = NSApp.windows.compactMap(\.contentView)
            while let view = queue.popLast() {
                if let found = view as? GeneralSettingsView { return found }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
        _ = await wait(3) { general() != nil }
        for (name, appearance) in [("Light", AppAppearance.light), ("Dark", .dark), ("Light", .light), ("Dark", .dark)] {
            if let view = general(), let index = AppAppearance.allCases.firstIndex(of: appearance) {
                view.appearanceChoice.selectedSegment = index
                view.appearanceChoice.sendAction(view.appearanceChoice.action, to: view.appearanceChoice.target)
            } else {
                note("theme: Settings › General isn't there; the look is set directly")
                Preferences.appearance = appearance
            }
            let palette: ThemePalette = appearance == .light ? .nextLight : .nextDark
            await pause(0.6) // a moment, not a wait until it comes right: a part left in the old look must show
            let misses = themeMisses([c, other, apart], palette)
            check(misses.isEmpty, "theme: switched to \(name), every part of every window (one merged behind, one apart, a tab not in front) takes it",
                  misses.joined(separator: "; "))
            if let window = apart.window, window.isMiniaturized {
                window.deminiaturize(nil) // shown again: what it shows is checked at once, then it goes off screen again
                _ = await wait(3) { !window.isMiniaturized }
                await pause(0.6)
                let shown = themeMisses([apart], palette)
                check(shown.isEmpty, "theme: switched to \(name) while a window was off screen, it shows the new look when it comes back",
                      shown.joined(separator: "; "))
                window.miniaturize(nil)
                _ = await wait(3) { window.isMiniaturized }
            }
            if appearance == .light {
                await screenshot(c, suffix: "-theme-switched-light")
                await screenshotParts(c, suffix: "-theme-light")
            } else {
                await screenshot(c, suffix: "-theme-switched-dark")
            }
        }
    }

    /// The parts of `controllers`' windows not drawn in `palette`, each named with what it shows.
    static func themeMisses(_ controllers: [TerminalWindowController], _ palette: ThemePalette) -> [String] {
        var misses: [String] = []
        func want(_ what: String, _ shown: UInt32?, _ wanted: UInt32) {
            guard let shown, shown != wanted else { return }
            misses.append("\(what) \(String(shown, radix: 16)) not \(String(wanted, radix: 16))")
        }
        for (index, c) in controllers.enumerated() {
            guard let window = c.window else { continue }
            window.displayIfNeeded() // the glow's gradient is made as its bar draws
            let w = "window \(index + 1)"
            if Theme.isDark(window.effectiveAppearance) != palette.isDark { misses.append("\(w) looks \(palette.isDark ? "light" : "dark")") }
            for (tabIndex, tab) in c.tabs.enumerated() {
                want("\(w) terminal \(tabIndex + 1)", layerHex(tab.view.nativeBackgroundColor.cgColor), palette.terminal.background)
            }
            want("\(w) tab bar", layerHex(c.tabBar.layer?.backgroundColor), palette.bar)
            want("\(w) selected tab", layerHex(c.tabBar.tabView(at: c.tabBar.selectedIndex)?.layer?.backgroundColor), palette.background)
            if c.isSidebarVisible { want("\(w) sidebar", layerHex(c.sidebar.layer?.backgroundColor), palette.bar) }
            // The window column's dots: none in the other look's colours (a light dot is a darker shade than a dark one).
            let light = ThemePalette.nextLight
            let others: Set<UInt32> = Set(ProjectColor.allCases.map {
                palette.isDark ? $0.swatch(onLight: [light.bar, light.background, light.tabHover]) : $0.swatch
            })
            var queue: [NSView] = [c.windowColumn]
            while let view = queue.popLast() {
                if let button = view as? WindowColumnButton, let dot = layerHex(button.dotColorForTest), others.contains(dot) {
                    misses.append("\(w) column dot \(String(dot, radix: 16)) in the other look")
                }
                queue.append(contentsOf: view.subviews)
            }
            if let color = c.projectColor, let drawn = c.tabBar.projectGlow.drawnPeak {
                want("\(w) glow", drawn, color.glow(on: palette.bar))
            }
        }
        return misses
    }

    /// A layer's colour as 0xRRGGBB.
    static func layerHex(_ cg: CGColor?) -> UInt32? {
        guard let cg, let color = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return nil }
        return UInt32((color.redComponent * 255).rounded()) << 16 | UInt32((color.greenComponent * 255).rounded()) << 8
            | UInt32((color.blueComponent * 255).rounded())
    }

    /// The sidebar, the terminal's tab bar and the window column, each on its own, beside the whole window's.
    static func screenshotParts(_ c: TerminalWindowController, suffix: String) async {
        guard let base = reportPath else { return }
        let parts: [(String, NSView)] = [("sidebar", c.sidebar), ("tab-bar", c.tabBar), ("column", c.windowColumn)]
        for (name, view) in parts where view.window != nil && !view.isHidden && view.bounds.width > 0 {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let path = (base as NSString).deletingPathExtension + suffix + "-" + name + ".png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            note("screenshot: \(path)")
        }
    }
}
