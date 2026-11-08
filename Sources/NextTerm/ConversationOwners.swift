import AppKit
import NextTermCore

/// One place per conversation (plan 037 KTD11), read from the open tabs: chat hosts first, by the ids their sessions
/// reported (cheap), with restored chats that resume once their tabs start, then terminal tabs running the same agent,
/// by the agent's own record of the conversation it has open (`ProcessInspector.agentEvidence`, read only here: when a
/// handoff, a Resume or a restore asks). The rule itself is `ConversationOwnership`'s. Main thread.
@MainActor
enum ConversationOwners {
    /// The tab where `agent`'s conversation `sessionID` is live now, other than `excluding`, or nil.
    static func owner(agent: String, sessionID: String, excluding: TerminalTab? = nil) -> TerminalTab? {
        let tabs: [TerminalTab] = AppDelegate.shared?.controllers.flatMap(\.tabs) ?? []
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chats: [ConversationOwnership.Holder] = ChatTabs.hosts.values.compactMap { (host: ChatTabHost) -> ConversationOwnership.Holder? in
            guard let tab = host.tab else { return nil }
            return ConversationOwnership.Holder(tab: tab.id, title: tab.title, agent: host.start.agentID, sessionID: host.sessionID,
                                                exact: true, live: host.holdsConversation)
        }
        // A restored chat that resumes holds its conversation before its tab starts (it isn't in the window yet).
        var waiting: [UUID: TerminalTab] = [:]
        for (tab, start) in ChatTabs.registeredResuming {
            waiting[tab.id] = tab
            chats.append(ConversationOwnership.Holder(tab: tab.id, title: tab.title, agent: start.agentID, sessionID: start.resumeID,
                                                      exact: true, live: true))
        }
        if let found = ConversationOwnership.owner(agent: agent, sessionID: sessionID, excluding: excluding?.id, among: chats) {
            return byID[found.tab] ?? ChatTabs.hosts[found.tab]?.tab ?? waiting[found.tab]
        }
        // Only tabs running that agent are read: the evidence costs a look at the process and its files.
        var terminals: [ConversationOwnership.Holder] = []
        for tab in tabs where tab !== excluding && !ChatTabs.isChat(tab) {
            let status = tab.status
            guard let offer = ConversationHandoff.offer(chatAgentID: nil, program: status.program, expandedCommand: status.expandedCommand,
                                                        kind: status.kind, running: status.running && !tab.exited,
                                                        remote: tab.remote != nil, herdr: status.hostsAgents),
                  offer.agent.rawValue == agent else { continue }
            let evidence = ProcessInspector.agentEvidence(ptyFileDescriptor: tab.view.process.childfd, shellPid: tab.view.process.shellPid,
                                                          status: status, home: RestorePlanning.agentHome)
            terminals.append(ConversationOwnership.Holder(tab: tab.id, title: tab.title, agent: agent, sessionID: evidence?.sessionID,
                                                          exact: ConversationOwnership.isExact(evidence?.source), live: true))
        }
        return ConversationOwnership.owner(agent: agent, sessionID: sessionID, among: terminals).flatMap { byID[$0.tab] }
    }
}
