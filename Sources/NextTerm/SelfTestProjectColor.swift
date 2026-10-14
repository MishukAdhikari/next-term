import AppKit
import NextTermCore

/// View › Project Color, in a repository of its own with a linked worktree beside it (its folder in another case). The
/// project's window gets a colour on its first open, kept when it opens again (no new pick); its worktree's window has the
/// same one under the same key. Each bar along the top row paints its slice of the glow by where it is in the window,
/// strongest at the corner and gone 320 pt in, whichever bar holds the corner: the sidebar's header, the terminal's bar
/// on the left, the rail of a folded terminal. An inactive window's is dimmed. None for This Project takes it off both
/// windows, Automatic gives one back and a colour chosen is both windows'; Show Project Colors off takes every window's
/// off and on brings them back, with Settings › General's box following. A window with no project has none. The text
/// keeps its colours and reads at 4.5:1 on every colour's peak, and the Welcome window's rows show the colour in their
/// dots, filled for open. The colours kept, the layout and the switch are put back as they were.
extension SelfTest {
    static func projectColorChecks() async {
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else { return note("project colour: skipped, no git") }
        let defaults = UserDefaults.standard
        let saved = (colors: defaults.object(forKey: ProjectColors.key), next: defaults.object(forKey: ProjectColors.nextKey),
                     shown: defaults.object(forKey: ProjectColors.shownKey), position: app.terminalPosition, side: app.sidebarSide)
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-projcolor-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/app", tree = base + "/App-wt-side", plain = base + "/plain"
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: plain, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        sh("worktree", "add", "-q", "-b", "side", tree)
        ProjectColorStore.isShown = true
        var windows: [TerminalWindowController] = []
        defer {
            for window in windows where !window.hasClosed { window.window?.close() }
            sh("worktree", "remove", "--force", tree)
            try? fm.removeItem(atPath: base)
            if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
            app.moveTerminal(to: saved.position)
            restoreDefault(saved.colors, ProjectColors.key)
            restoreDefault(saved.next, ProjectColors.nextKey)
            restoreDefault(saved.shown, ProjectColors.shownKey)
            NotificationCenter.default.post(name: ProjectColorStore.changed, object: nil)
        }
        func open(_ path: String, project: Bool = true) async -> TerminalWindowController {
            let controller = app.openWindow(directory: path, project: project ? path : nil)
            windows.append(controller)
            _ = await wait(5) { controller.window?.isVisible == true }
            return controller
        }
        func close(_ controller: TerminalWindowController) async {
            controller.window?.close()
            _ = await wait(5) { !app.controllers.contains { $0 === controller } }
        }

        // The first open picks a colour and keeps it; the next open finds it kept, and picks nothing.
        var main = await open(repo)
        guard let first = main.projectColor else { return check(false, "project colour: a project's window gets a colour on its first open") }
        let kept = ProjectColorStore.read()
        await close(main)
        main = await open(repo)
        check(main.projectColorKey == repo && main.projectColor == first && ProjectColorStore.read().next == kept.next
              && kept.entry(for: repo)?.chosen == false,
              "project colour: a project's window gets a colour on its first open, and has it again on the next with no new pick",
              "key \(main.projectColorKey ?? "none"), \(first.name) then \(main.projectColor?.name ?? "none"), counter \(kept.next) then \(ProjectColorStore.read().next)")

        // Its worktree's window: the repository's key and colour, though the folder's name has another case.
        let side = app.openWorktreeWindow(tree)
        windows.append(side)
        _ = await wait(5) { side.window?.isVisible == true }
        check(side.projectColorKey == repo && side.projectColor == first,
              "project colour: a linked worktree's window has its repository's colour",
              "key \(side.projectColorKey ?? "none"), colour \(side.projectColor?.name ?? "none")")

        // On the top row's bars, and only there: the text, the bars' own colour and the window's stay as they are.
        main.window?.makeKeyAndOrderFront(nil)
        _ = await wait(2) { main.window?.isKeyWindow == true }
        let bars: [ProjectGlow] = [main.sidebar.header.projectGlow, main.tabBar.projectGlow, main.editorArea.tabBar.projectGlow]
        check(bars.allSatisfy { $0.peak == first.glowColor }, "project colour: the top row's bars have the window's colour")
        let selected: Int = main.tabBar.selectedIndex
        let textKept = main.sidebar.header.titleColor == Theme.text && main.tabBar.titleColor(at: selected) == Theme.text
            && main.tabBar.layer?.backgroundColor == Theme.bar.cgColor && main.sidebar.layer?.backgroundColor == Theme.bar.cgColor
            && main.window?.backgroundColor == Theme.background
        let reads: Bool = ProjectColor.allCases.allSatisfy { (color: ProjectColor) -> Bool in
            let peak: UInt32 = color.glow(on: Theme.bar.rgbHex)
            return ProjectColor.contrast(Theme.text.rgbHex, peak) >= 4.5 && ProjectColor.contrast(Theme.textDim.rgbHex, peak) >= 4.5
        }
        check(textKept && reads, "project colour: the text keeps its colours, and reads at 4.5:1 on every colour's peak",
              "kept \(textKept), reads \(reads)")
        if NSApp.isActive, main.window?.isKeyWindow == true {
            check(!main.tabBar.projectGlow.dimmed && side.tabBar.projectGlow.dimmed,
                  "project colour: the window in use has its glow at full strength, one behind it dimmed")
        } else {
            note("project colour: Next Term is not the active app, so the dimming was not checked")
        }

        // The glow along the top row, whichever bar holds the corner.
        await glowLayoutChecks(main, app: app, repo: repo)

        // None for This Project, Automatic, a colour chosen: the worktree's window follows each.
        func choose(_ id: String) {
            let item = NSMenuItem(title: id, action: #selector(TerminalWindowController.setProjectColor(_:)), keyEquivalent: "")
            item.representedObject = id
            main.setProjectColor(item)
        }
        func state(_ id: String) -> NSControl.StateValue {
            let item: NSMenuItem? = main.projectColorMenu()?.items.first { ($0.representedObject as? String) == id }
            guard let item else { return .mixed }
            _ = main.validateMenuItem(item)
            return item.state
        }
        let glows: [ProjectGlow] = bars + [side.tabBar.projectGlow, side.sidebar.header.projectGlow]
        choose(ProjectColorMenu.noneID)
        check(main.projectColor == nil && side.projectColor == nil && glows.allSatisfy { $0.peak == nil }
              && state(ProjectColorMenu.noneID) == .on && state(first.id) == .off,
              "project colour: None for This Project takes it off the window and its worktree's", "\(main.projectColor?.name ?? "none")")
        choose(ProjectColorMenu.automaticID)
        let back: ProjectColor? = main.projectColor
        check(back != nil && side.projectColor == back && main.projectColorEntry?.chosen == false && state(ProjectColorMenu.automaticID) == .on
              && glows.allSatisfy { $0.peak == back?.glowColor },
              "project colour: Automatic gives both windows a colour again", back?.name ?? "none")
        let chosen: ProjectColor = back == .violet ? .grass : .violet
        choose(chosen.id)
        check(main.projectColor == chosen && side.projectColor == chosen && state(chosen.id) == .on && state(ProjectColorMenu.automaticID) == .off
              && ProjectColorStore.read().entry(for: repo)?.color == chosen && ProjectColorStore.read().entry(for: repo)?.chosen == true,
              "project colour: a colour chosen is the window's and its worktree's, checked in the menu", main.projectColor?.name ?? "none")
        let menuItems: [String] = main.projectColorMenu()?.items.map(\.title) ?? []
        check(menuItems.count == 15 && menuItems.contains("None for This Project") && menuItems.contains("Show Project Colors")
              && ProjectColor.allCases.allSatisfy { menuItems.contains($0.name) },
              "project colour: the top row's right-click lists the nine colours, Automatic, None and Show Project Colors", "\(menuItems)")

        // Show Project Colors, off and on, for every window; the colours stay kept, and Settings › General's box follows.
        app.toggleProjectColors(nil)
        let everyBar: [ProjectGlow] = app.controllers.flatMap { (c: TerminalWindowController) -> [ProjectGlow] in
            [c.tabBar.projectGlow, c.editorArea.tabBar.projectGlow, c.sidebar.header.projectGlow, c.terminalRail.projectGlow]
        }
        let settingsOff: Bool = GeneralSettingsView(frame: .zero).projectColors.state == .off
        check(!ProjectColorStore.isShown && everyBar.allSatisfy { $0.peak == nil } && main.projectColor == chosen && settingsOff,
              "project colour: Show Project Colors off takes every window's colour off, and keeps them")
        app.toggleProjectColors(nil)
        check(ProjectColorStore.isShown && main.tabBar.projectGlow.peak == chosen.glowColor && side.tabBar.projectGlow.peak == chosen.glowColor,
              "project colour: Show Project Colors on brings them back")

        // A window with no project has no colour, and no menu for one.
        let none = await open(plain, project: false)
        check(none.projectColorKey == nil && none.projectColor == nil && none.projectColorMenu() == nil && none.tabBar.projectGlow.peak == nil,
              "project colour: a window with no project has none")
        await close(none)

        await welcomeDotChecks(app, repo: repo, tree: tree, color: chosen)
    }

    /// The glow along the top row in three layouts: the sidebar on the left with the terminal below (the header holds the
    /// corner), the sidebar on the right with a file open and the terminal on the left (the terminal's bar has it, the
    /// editor's runs on from it), and that terminal folded (its rail has it). Each bar, at each point it covers, paints
    /// what the window's place there says, to within a step of 8-bit colour.
    private static func glowLayoutChecks(_ c: TerminalWindowController, app: AppDelegate, repo: String) async {
        guard let peak = c.projectColor?.glowColor.rgbHex else { return check(false, "project colour: the window has a colour to check") }
        let sidebarWas: Bool = c.isSidebarVisible
        defer { if c.isSidebarVisible != sidebarWas { c.toggleProjectSidebar(nil) } }
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        if app.sidebarSide == .right { app.toggleSidebarSide(nil) }
        app.moveTerminal(to: .bottom)
        layOut(c)
        check(cornerBar(c) === c.sidebar.header, "project colour: the sidebar on the left holds the corner")
        glowAlongTheRow(c, peak: peak, layout: "the sidebar on the left")

        app.toggleSidebarSide(nil)
        c.openFile(URL(fileURLWithPath: repo + "/a.txt"))
        _ = await wait(5) { !c.editorArea.isHidden }
        app.moveTerminal(to: .left)
        layOut(c)
        check(cornerBar(c) === c.tabBar, "project colour: the terminal on the left holds the corner, the sidebar on the right",
              "\(cornerBar(c).map { String(describing: type(of: $0)) } ?? "none")")
        glowAlongTheRow(c, peak: peak, layout: "the terminal on the left")

        c.collapseTerminal()
        layOut(c)
        check(c.terminalRailed && cornerBar(c) === c.terminalRail, "project colour: folded on the left, the terminal's rail holds the corner")
        glowAlongTheRow(c, peak: peak, layout: "the terminal folded on the left")
        c.expandTerminal()
        layOut(c)
    }

    private static func layOut(_ c: TerminalWindowController) {
        c.window?.contentView?.layoutSubtreeIfNeeded()
        c.window?.displayIfNeeded()
    }

    /// The bars of the top row that show, with the rail while it shows.
    private static func topRow(_ c: TerminalWindowController) -> [NSView & ProjectGlowing] {
        let all: [NSView & ProjectGlowing] = [c.sidebar.header, c.tabBar, c.editorArea.tabBar, c.terminalRail]
        let top: CGFloat = c.window?.contentView?.bounds.height ?? 0
        return all.filter { (view: NSView & ProjectGlowing) -> Bool in
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0 else { return false }
            return abs(view.convert(view.bounds, to: nil).maxY - top) < 1
        }
    }

    /// The top row's bar at the window's left edge.
    private static func cornerBar(_ c: TerminalWindowController) -> NSView? {
        topRow(c).first { (view: NSView & ProjectGlowing) -> Bool in abs(view.convert(view.bounds, to: nil).minX) < 0.5 }
    }

    private static func glowAlongTheRow(_ c: TerminalWindowController, peak: UInt32, layout: String) {
        var wrong: [String] = []
        var sampled = 0
        for view in topRow(c) {
            let alpha: Double = view.projectGlow.dimmed ? ProjectColor.Glow.inactive : 1
            for x: CGFloat in [2, 40, 100, 200, 300, 330, 600] {
                guard let drawn = painted(view, atWindowX: x) else { continue }
                sampled += 1
                let expected: UInt32 = blend(Theme.bar.rgbHex, peak, alpha * ProjectColor.Glow.strength(at: Double(x)))
                if !close(drawn, expected) {
                    wrong.append("\(type(of: view)) at \(Int(x)): #\(String(drawn, radix: 16)), not #\(String(expected, radix: 16))")
                }
            }
        }
        check(sampled >= 5 && wrong.isEmpty, "project colour: with \(layout), each bar along the top paints its slice of one glow from the corner",
              "\(sampled) points; " + wrong.joined(separator: "; "))
    }

    /// What `view`'s slice of the glow paints `x` points in from the window's left edge, on the bar's colour, drawn into a
    /// pixel as the bar draws it; nil where the view isn't.
    private static func painted(_ view: NSView & ProjectGlowing, atWindowX x: CGFloat) -> UInt32? {
        let local: CGFloat = x - view.convert(NSPoint(x: view.bounds.minX, y: view.bounds.minY), to: nil).x
        guard local >= 0, local < view.bounds.width,
              let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let rep = blank.retagging(with: .sRGB), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let shift = NSAffineTransform()
        shift.translateX(by: -(view.bounds.minX + local), yBy: -view.bounds.minY)
        shift.concat()
        let pixel = NSRect(x: view.bounds.minX + local, y: view.bounds.minY, width: 1, height: 1)
        Theme.bar.setFill()
        pixel.fill()
        view.projectGlow.paint(pixel, in: view)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0)?.rgbHex
    }

    /// `top` over `bottom` at `alpha`, channel by channel, as sRGB compositing does it.
    private static func blend(_ bottom: UInt32, _ top: UInt32, _ alpha: Double) -> UInt32 {
        var result: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let under = Double((bottom >> shift) & 0xFF), over = Double((top >> shift) & 0xFF)
            result |= UInt32((under + (over - under) * alpha).rounded()) << shift
        }
        return result
    }

    private static func close(_ a: UInt32, _ b: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { (shift: UInt32) -> Bool in abs(Int((a >> shift) & 0xFF) - Int((b >> shift) & 0xFF)) <= 2 }
    }

    /// The Welcome window's rows: the project's and its worktree's dots in the colour, filled while open.
    private static func welcomeDotChecks(_ app: AppDelegate, repo: String, tree: String, color: ProjectColor) async {
        app.showWelcome(nil)
        guard let welcome = app.welcomeController else { return check(false, "project colour: the Welcome window shows") }
        defer { welcome.close() }
        let list = welcome.switcherList
        func cell(_ path: String) -> SwitcherProjectCell? {
            list.shown.projects.firstIndex { $0.path == path }.flatMap(list.projectCell(at:))
        }
        // The worktree's key is read off the main thread with its title.
        _ = await wait(5) { cell(tree)?.shownDotColor == color.swatchColor }
        let main = cell(repo), worktree = cell(tree)
        check(main?.shownDotColor == color.swatchColor && main?.showsOpenDot == true
              && worktree?.shownDotColor == color.swatchColor && worktree?.showsOpenDot == true,
              "project colour: the Welcome window's rows have the colour in their dots, filled while open, a worktree's its repository's",
              "project \(main.map { $0.shownDotColor.rgbHex } ?? 0), worktree \(worktree.map { $0.shownDotColor.rgbHex } ?? 0)")
    }
}
