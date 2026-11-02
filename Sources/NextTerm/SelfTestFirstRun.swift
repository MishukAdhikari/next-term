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
        check(agents.map(\.name).prefix(3) == ["Claude Code", "Codex", "Command Code"],
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
}
#endif
