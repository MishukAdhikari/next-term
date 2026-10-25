import AppKit
import NextTermCore

/// Through your agent: the agent tabs of a window the request may go to, and the typing. Only a tab AgentReadiness
/// says is ready is typed into, checked again at the moment of typing. The request goes in as a paste with its line
/// breaks only when the program has bracketed paste on; otherwise it is one line joined with " / ". Return is never
/// pressed: the user reads the request in the tab and sends it. The tab is not marked driven by an agent, since the
/// user chose to send it, as with Send to Agent; its run_with_secrets grants end, as for any typed input.
@MainActor
enum TaskAgentRequest {
    /// One agent tab of the window, as the Agent tab popup lists it.
    @MainActor struct Choice {
        let tab: TerminalTab
        let agent: AgentKind
        let verdict: AgentReadiness.Verdict

        var isReady: Bool { verdict == .ready }

        var reason: AgentReadiness.Reason? {
            if case .notReady(let reason) = verdict { return reason }
            return nil
        }

        /// "“api” (Claude Code)", or "“web” (Codex) · working". The tab's title is masked.
        var title: String {
            let name = "“\(SecretMask.current.mask(tab.title))” (\(agent.name))"
            return reason.map { name + " · " + $0.text } ?? name
        }

        /// What the plan needs to know of it.
        var facts: DestinationFacts.AgentTab {
            DestinationFacts.AgentTab(title: tab.title, agent: agent, bracketedPaste: TaskAgentRequest.takesLines(tab),
                                      notReady: reason)
        }
    }

    /// The window's tabs that run an agent, each with whether it is ready now.
    static func choices(in controller: TerminalWindowController) -> [Choice] {
        controller.tabs.compactMap { tab -> Choice? in
            let status = tab.status
            guard status.running, status.kind == .agent else { return nil }
            let program = CommandClassifier.programName(status.expandedCommand)
            guard let agent = AgentKind(program: status.program) ?? AgentKind(program: program) else { return nil }
            return Choice(tab: tab, agent: agent, verdict: AgentReadiness.shared.check(tab))
        }
    }

    /// The tab picked first: the one Send to Agent would use when it is ready, else the first ready one.
    static func preferred(_ choices: [Choice], in controller: TerminalWindowController) -> Choice? {
        if let agentTab = controller.agentTab, let choice = choices.first(where: { $0.tab === agentTab }),
           choice.isReady {
            return choice
        }
        return choices.first { $0.isReady }
    }

    /// The program takes a paste with its line breaks kept inside it.
    static func takesLines(_ tab: TerminalTab) -> Bool {
        tab.view.getTerminal().bracketedPasteMode
    }

    /// Why the tab can't take a request holding `tasks` tasks at this moment; nil when it can. A tab with no bracketed
    /// paste takes one task at a time, as the plan said, even if the program turned the paste off since.
    static func refusal(_ tab: TerminalTab, tasks: Int) -> String? {
        let title = SecretMask.current.mask(tab.title)
        if case .notReady(let reason) = AgentReadiness.shared.check(tab) {
            return "“\(title)” isn’t ready: \(reason.text). Nothing was typed."
        }
        if !MCPControl.canType(tab) || MCPInputLine.refusal(tab) != nil {
            return "“\(title)” can’t be typed into now. Nothing was typed."
        }
        if tasks > 1 && !takesLines(tab) { return DestinationPlan.oneAtATime(title) + " Nothing was typed." }
        return nil
    }

    /// Types `request`, which holds `tasks` tasks, into `tab` with no Return and brings the tab to the front; nil once
    /// typed, else why not. `request` is the plan's, already on one line when the tab had no bracketed paste; it is
    /// joined again here if the program turned bracketed paste off since, so no line break reaches the tab outside a
    /// paste.
    static func type(_ request: String, tasks: Int, into tab: TerminalTab,
                     in controller: TerminalWindowController) -> String? {
        if let why = refusal(tab, tasks: tasks) { return why }
        let text: String = takesLines(tab) ? request : DestinationPlan.oneLineRequest(request)
        controller.show(tab)
        controller.window?.makeFirstResponder(tab.view)
        tab.view.typeText(text)
        SecretRequests.shared.tabGotInput(tab.id)
        return nil
    }
}
