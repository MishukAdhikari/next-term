import AppKit
import NextTermCore

#if DEBUG
/// What a first run shows of agent setup, drawn and screenshot: the Welcome window's card that says Next Term added its
/// tools to the agents, the card that sets Next Term up with one of them, and the window an agent's apply_setup asks in.
/// Part of NEXTTERM_SELFTEST_ONLY=firstRun.
extension SelfTest {
    static func firstRunChecks() async {
        let app: AppDelegate = AppDelegate.shared
        let statuses: [String: MCPRegistrar.Status] = ["claude": .registered, "codex": .registered, "commandcode": .registered]

        // The card on the Welcome window.
        app.showWelcome(nil)
        guard let welcome = app.welcomeController, let window = welcome.window,
              let notice = MCPRegistrationNotice.due(statuses, shown: []) else { return check(false, "first run: the Welcome window and a notice") }
        welcome.showRegistrationNotice(notice)
        window.layoutIfNeeded()
        await screenshot(window, suffix: "-registration-card")
        let text: String = welcome.registrationNoticeText ?? ""
        check(text.contains("Claude Code") && text.contains("Codex") && text.contains("Command Code"),
              "first run: the Welcome window says which agents Next Term added its tools to", text)
        welcome.close()

        // The card that starts an agent with the setup prompt, in a window of its own to look at.
        let agents: [SetupAgent] = SetupAgent.offered(programs: ["claude": "/usr/local/bin/claude", "codex": "/usr/local/bin/codex",
                                                                  "commandcode": "/usr/local/bin/commandcode"], statuses: statuses)
        let card = SetupAgentCard()
        card.show(agents)
        let frame = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        frame.keepsItsOwnFrame()
        frame.isReleasedWhenClosed = false
        frame.appearance = NSAppearance(named: .darkAqua)
        frame.backgroundColor = Theme.background
        let holder = NSView()
        frame.contentView = holder
        card.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(card)
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 20),
                                     card.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -20),
                                     card.topAnchor.constraint(equalTo: holder.topAnchor, constant: 20)])
        frame.center()
        frame.orderFront(nil)
        frame.layoutIfNeeded()
        await screenshot(frame, suffix: "-agent-card")
        check(agents.map(\.name).prefix(3) == ["Claude Code", "Codex", "Command Code"]
              && card.chips.allSatisfy { $0.frame.width > $0.attributedTitle.size().width },
              "first run: Set up with your agent offers Claude Code, Codex and Command Code first", "\(agents.map(\.name))")
        frame.close()

        // The window apply_setup asks in: a row per change, the count on its one button following the ticks.
        let rows: [AgentSetup.Row] = [AgentSetup.Row(id: "font", title: "Terminal font size 13 → 14"),
                                      AgentSetup.Row(id: "layout", title: "Terminal on the right"),
                                      AgentSetup.Row(id: "keys", title: "Shortcuts: VS Code set"),
                                      AgentSetup.Row(id: "import", title: "Keys and colours from Cursor", detail: "3 have no equivalent", count: 12)]
        let request = AgentSetupWindow.Request(requester: "Claude Code in “~”", agentWords: "Setting Next Term up the way you had Cursor.",
                                               rows: rows, ticked: Set(rows.map(\.id)), notes: [])
        var cancelled = false
        let ask = AgentSetupWindow(request, apply: { _, window in window.finish() }, cancel: { cancelled = true })
        ask.present()
        guard let asking = ask.window else { return check(false, "first run: the setup window opens") }
        asking.layoutIfNeeded()
        await screenshot(asking, suffix: "-apply-setup")
        let title: String = ask.applyButton.title
        asking.cancelOperation(nil)
        _ = await wait(2) { cancelled }
        check(title == AgentSetup.applyTitle(AgentSetup.count(rows, ticked: Set(rows.map(\.id)))) && cancelled,
              "first run: apply_setup asks in one window whose button counts the changes, and Escape cancels it",
              "button “\(title)”, cancelled \(cancelled)")
        ask.finish()
    }

    /// A tab whose name is cut short in the title strip, where AppKit shows no tooltip: resting the real pointer on it
    /// shows its whole name under it, and moving away puts it away.
    static func tabHoverChecks(_ c: TerminalWindowController) async {
        guard let window = c.window, await bringToFront(window), let tab = c.activeTab else { return note("tab hover skipped: no window in front") }
        let long = "A tab with a name far too long to fit in its place in the tab bar, so it is cut short"
        tab.userTitle = long
        c.refresh()
        defer { tab.userTitle = nil; c.refresh(); HoverTip.shared.hide() }
        let index: Int = c.groups.firstIndex { $0.contains(tab) } ?? 0
        await pause(0.3)
        window.layoutIfNeeded()
        guard let frame = c.tabBar.screenFrame(at: index), frame.width > 0 else { return check(false, "tab hover: the tab is in the bar") }
        let point = CGPoint(x: frame.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - frame.midY)
        // In from below, a step at a time, as a hand moves it: one jump is sometimes not heard as coming in.
        for step in 0...10 {
            let at = CGPoint(x: point.x, y: point.y + CGFloat(10 - step) * 12)
            CGWarpMouseCursorPosition(at)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
            await pause(0.04)
        }
        let shown: Bool = await wait(3) { HoverTip.shared.shownText == long }
        note("tab hover: " + c.tabBar.hoverState(at: index) + ", pointer \(NSEvent.mouseLocation) in \(frame), window key \(window.isKeyWindow), app active \(NSApp.isActive)")
        if let base = reportPath, let screenHeight = NSScreen.screens.first?.frame.height {
            // The tab and the label under it, as the screen shows them: the label is a window of its own.
            let area = CGRect(x: frame.minX - 20, y: screenHeight - frame.maxY - 10, width: max(frame.width + 360, 600), height: 90)
            if let image = CGWindowListCreateImage(area, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
                let path = (base as NSString).deletingPathExtension + "-tab-hover.png"
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        // Off it, down into the terminal, a step at a time.
        for step in 1...10 {
            let at = CGPoint(x: point.x, y: point.y + CGFloat(step) * 14)
            CGWarpMouseCursorPosition(at)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
            await pause(0.04)
        }
        let gone: Bool = await wait(HoverTip.shownFor + 1) { HoverTip.shared.shownText == nil }
        note("tab hover, after: " + c.tabBar.hoverState(at: index).components(separatedBy: ", label").first! + ", pointer \(NSEvent.mouseLocation)")
        check(shown && gone, "tab hover: a tab's name cut short shows whole under it while the pointer rests there, and goes once it leaves, in seconds at most",
              "shown \(shown) (“\(HoverTip.shared.shownText ?? "")”), gone \(gone)")
    }
}
#endif
