import AppKit
import NextTermCore

/// continue_in (plan 037 U7, R19): Continue in Chat or Open in Terminal for agents, as ⇧⌘J runs it, asked on the Mac
/// first. A handoff that can't run is refused before the question, with the words the tab would show; a tab that is the
/// kind asked for already is an answer, not a failure. Once approved, it answers when the new tab is open.
extension MCPWriteControl {
    static func continueIn(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        if let raw = arguments["tab_id"] as? String, HerdrTarget.parse(raw) != nil {
            return reply(MCPControl.fail("That is one of herdr's agents: continue_in works on a Next Term tab running Claude Code or Codex on this Mac."))
        }
        var wanted: ConversationHandoff.Kind?
        if let raw = arguments["view"] {
            guard let text = raw as? String, let kind = ConversationHandoff.Kind(rawValue: text) else {
                return reply(MCPControl.fail("view is chat or terminal."))
            }
            wanted = kind
        }
        guard let tab = findTab(arguments["tab_id"]), let controller = MCPControl.controller(of: tab) else {
            return reply(MCPControl.fail("No tab with that id; list_tabs shows them."))
        }
        // The caller's own agent would be ended under it, its answer going nowhere.
        if tab === context.caller { return reply(MCPControl.fail("That is your own tab.")) }
        let id = tab.id.uuidString.lowercased()
        // Planned once without acting: whatever refuses it does so before the user is asked.
        let facts = MainActor.assumeIsolated { HandoffRunner.facts(of: tab, wanted: wanted) }
        let target: ConversationHandoff.Target
        switch ConversationHandoff.plan(facts) {
        case .failure(let refusal):
            let text = refusal.text(agent: facts.offer?.agent)
            if case .isAlready(let kind) = refusal { return reply(MCPControl.ok(["id": id, "kind": kind.rawValue, "note": text])) }
            return reply(MCPControl.fail(text))
        case .success(let planned):
            target = planned
        }
        // Text another feature put on a terminal tab's line is not the handoff's to send keys over.
        if target.kind == .chat, let why = MCPInputLine.refusal(tab) { return reply(MCPControl.fail(why)) }
        let ask = Ask(title: "An agent asks to continue \u{201C}\(MCPTabNames.title(tab))\u{201D} in \(target.kind.title)",
                      details: "In \(place(controller)), \(MCPTabNames.named(tab)): " + continueDetails(target))
        approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            guard MCPControl.controller(of: tab) != nil else { return reply(MCPControl.fail("That tab closed meanwhile; nothing changed.")) }
            // Planned again from what the tab holds now: the same agent and conversation the user approved, or nothing.
            MainActor.assumeIsolated {
                HandoffRunner.start(tab: tab, wanted: target.kind, confirm: false, showsRefusal: false, byAgent: true,
                                    expecting: (target.agent, target.sessionID)) { outcome in
                    switch outcome {
                    case .failure(let failure):
                        reply(MCPControl.fail(failure.text))
                    case .success(let done):
                        var info: [String: Any] = ["id": id, "new_tab_id": done.tab.id.uuidString.lowercased(),
                                                   "kind": done.target.kind.rawValue, "approved": approved]
                        if !done.target.sessionID.isEmpty { info["session_id"] = done.target.sessionID }
                        reply(MCPControl.ok(info))
                    }
                }
            }
        }
    }

    /// What the user is told the handoff does: which program ends, and where the conversation goes on.
    static func continueDetails(_ target: ConversationHandoff.Target) -> String {
        let agent = target.agent.name
        let conversation = "conversation " + String(target.sessionID.prefix(8))
        switch target.kind {
        case .chat:
            return "\(agent) quits in that tab, and this \(conversation) goes on in a new chat tab beside it."
        case .terminal:
            if target.sessionID.isEmpty { return "\(agent) starts in its own terminal interface, in a new tab beside the chat." }
            return "The chat ends, and \(agent) goes on with this \(conversation) in its own terminal interface, in a new tab beside it."
        }
    }
}
