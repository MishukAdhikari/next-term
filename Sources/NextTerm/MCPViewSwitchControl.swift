import AppKit
import NextTermCore

/// switch_view (plan 036 U6, R12): the terminal and chat switch for agents, as ⇧⌘J runs it, asked on the Mac first. A
/// switch that can't run is refused before the question, with the words the tab would show; a tab that shows the view
/// asked for already is an answer, not a failure. Once approved, it answers when the resume line is typed.
extension MCPWriteControl {
    static func switchView(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        if let raw = arguments["tab_id"] as? String, HerdrTarget.parse(raw) != nil {
            return reply(MCPControl.fail("That is one of herdr's agents: the switch works on a Next Term tab running Claude Code or Codex on this Mac."))
        }
        var wanted: ViewSwitch.View?
        if let raw = arguments["view"] {
            guard let text = raw as? String, let view = ViewSwitch.View(rawValue: text) else {
                return reply(MCPControl.fail("view is chat or terminal."))
            }
            wanted = view
        }
        guard let tab = findTab(arguments["tab_id"]), let controller = MCPControl.controller(of: tab) else {
            return reply(MCPControl.fail("No tab with that id; list_tabs shows them."))
        }
        // The caller's own agent would be quit under it, its answer going nowhere.
        if tab === context.caller { return reply(MCPControl.fail("That is your own tab.")) }
        let id = tab.id.uuidString.lowercased()
        // Planned once without acting: whatever refuses it does so before the user is asked.
        let facts = ViewSwitchRunner.facts(of: tab, wanted: wanted)
        let plan: ViewSwitch.Plan
        switch ViewSwitch.plan(facts) {
        case .failure(let refusal):
            if case .showsAlready(let view) = refusal {
                return reply(MCPControl.ok(["id": id, "view": view.rawValue, "note": refusal.text(agent: facts.offer?.agent)]))
            }
            return reply(MCPControl.fail(refusal.text(agent: facts.offer?.agent)))
        case .success(let planned):
            plan = planned
        }
        // Text another feature put on the tab's line is not the switch's to replace (MCPInputLine's other rules).
        if let why = MCPInputLine.refusal(tab) { return reply(MCPControl.fail(why)) }
        let ask = Ask(title: "An agent asks to switch \u{201C}\(MCPTabNames.title(tab))\u{201D} to \(plan.to.title)",
                      details: "In \(place(controller)), \(MCPTabNames.named(tab)): " + askDetails(plan))
        approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            guard MCPControl.controller(of: tab) != nil else { return reply(MCPControl.fail("That tab closed meanwhile; nothing changed.")) }
            if let why = MCPInputLine.refusal(tab) { return reply(MCPControl.fail(why)) }
            // Planned again from what the tab holds now: the same agent and conversation the user approved, or nothing.
            ViewSwitchRunner.start(tab: tab, wanted: wanted ?? plan.to, showsRefusal: false,
                                   expecting: (plan.agent, plan.sessionID)) { outcome in
                switch outcome {
                case .failure(let failure):
                    reply(MCPControl.fail(failure.text))
                case .success(let switched):
                    var info: [String: Any] = ["id": id, "view": switched.view.rawValue, "approved": approved]
                    if !switched.sessionID.isEmpty { info["session_id"] = switched.sessionID }
                    reply(MCPControl.ok(info))
                }
            }
        }
    }

    /// What the user is told the switch does: which program quits, and where the conversation goes on.
    static func askDetails(_ plan: ViewSwitch.Plan) -> String {
        let agent = plan.agent.name
        let conversation = "conversation " + String(plan.sessionID.prefix(8))
        switch plan.to {
        case .chat:
            return "\(agent) quits and resumes this \(conversation) in Next Term\u{2019}s chat view, in the same tab."
        case .terminal:
            if plan.sessionID.isEmpty { return "\(agent) starts in its own terminal interface, in the same tab." }
            return "Next Term\u{2019}s chat view ends and \(agent) resumes this \(conversation) in its own terminal interface, in the same tab."
        }
    }
}
