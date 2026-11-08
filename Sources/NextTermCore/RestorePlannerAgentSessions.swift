import Foundation

/// What the restore decides for an agent's pane: a plain agent tab's resume or put-back line, and a chat tab's (plan 037
/// U5), which an agent session's tab (`nxtrm agent NAME`, plan 035 U7) comes back as. Kept apart from the rest of the
/// planner for its size.
extension RestorePlanner {
    static func decide(agent evidence: SessionSnapshot.Evidence, _ input: PaneInput, integrated: Bool) -> Decision {
        // The user's launch with the resume form (KTD7): the launcher replayed, or the program and argv's options.
        guard let putBack = evidence.putBack(id: input.session?.id, folder: evidence.sessionFolder) else {
            // Aider's note names the permission options it ran with (R7): argv's, or the typed line's without them.
            let cli = evidence.agent.cli
            let named = (evidence.options ?? evidence.confirmed)
                .filter { cli.options[$0.name]?.kind == .permission }
                .map { $0.words.joined(separator: " ") }
            return Decision(outcome: .agentHint, permissions: named)
        }
        let line = putBack.line
        // The note names the session the line names, and none when the line has no id.
        let session = putBack.namesSession ? input.session : nil
        // Most agents find a session by the folder they run in, so the line waits in the session's own.
        guard integrated else {
            return Decision(outcome: .agentNote, noteLine: line, session: session, folder: input.sessionFolder, leftOff: putBack.leftOff)
        }
        if let command = resumeCommand(input, evidence: evidence, session: session) {
            // Its note names each permission option it carries, so a bypass is never silent (R5).
            let permissions = evidence.launch.permissions.map { (words: [String]) -> String in words.joined(separator: " ") }
            return Decision(outcome: .resume, line: command, noteLine: line, session: session, folder: evidence.sessionFolder,
                            leftOff: putBack.leftOff, permissions: permissions)
        }
        return Decision(outcome: .agentOnTheLine, line: line, noteLine: line, session: session, folder: input.sessionFolder,
                        leftOff: putBack.leftOff)
    }

    /// The command an automatic resume runs, when it may run: an update restore or a consented quit restore, the gate
    /// passed, the pane selected last of those on its session, in its own folder, with the exact id its evidence holds.
    /// Only the command the gate builds from this pane's own evidence runs.
    private static func resumeCommand(_ input: PaneInput, evidence: SessionSnapshot.Evidence, session: NamedSession?) -> String? {
        guard case .resume(let command)? = input.verdict, mayResume(input.kind, consent: input.quitConsent, safeMode: input.safeMode),
              !input.selectedEarlier else {
            return nil
        }
        guard input.folder?.movedFrom == nil, let session, session.naming == .exact, session.id == evidence.sessionID else { return nil }
        return command == evidence.resumeCommand ? command : nil
    }

    // MARK: chat tabs (plan 037 U5)

    /// The chat a pane comes back as: a chat tab's own record, or an agent session's tab (`nxtrm agent NAME`, plan 035
    /// U7) still running at the save with the id its session reported, which comes back as a chat tab of that agent, id
    /// and folder. Nil for any other pane, and for an agent session that ended or that Next Term can't resume (its line
    /// is then a command's, as before).
    static func chatRecord(of pane: SessionSnapshot.Pane) -> SessionSnapshot.ChatTabRecord? {
        if let chat = pane.chat { return chat }
        guard let record = pane.agentSession, pane.command?.running == true, let agent = ACPAgent.named(record.agent),
              agent.id == record.agent, agent.resumesSessions, AgentSessionVersion.isSessionID(record.sessionID),
              restoreAgent(agent) != nil else { return nil }
        return SessionSnapshot.ChatTabRecord(agent: record.agent, sessionID: record.sessionID, folder: record.folder)
    }

    /// The conversation a chat pane goes on with: its agent's, by the exact id its session reported, when that agent
    /// resumes conversations and the id is a plain one. Nil for a chat that named none, or an ACP agent's.
    static func chatSession(of pane: SessionSnapshot.Pane) -> NamedSession? {
        guard let record = chatRecord(of: pane), let agent = ACPAgent.named(record.agent), agent.id == record.agent,
              agent.resumesSessions, let kind = restoreAgent(agent), let id = record.sessionID,
              AgentSessionVersion.isSessionID(id) else { return nil }
        return NamedSession(agent: kind, id: id, naming: .exact)
    }

    /// A chat tab's restore: its host goes on with its conversation by itself on an update restore or a consented quit
    /// restore, with the conversation's exact id, its folder still there, and no tab selected after it holding the same
    /// conversation (KTD11). Otherwise, after a crash, in safe mode, or with no conversation named, it comes back idle with
    /// a Resume button. Nothing is typed anywhere: the pane has no shell. Nil for a pane that isn't a chat.
    static func decide(chat input: PaneInput) -> Decision? {
        let pane = input.pane
        guard let record = chatRecord(of: pane) else { return nil }
        let session = chatSession(of: pane)
        let agent = ACPAgent.named(record.agent)
        let kind = agent.flatMap(restoreAgent)
        // The conversation's own folder when it is still there, as both agents find a conversation by its folder; else
        // the folder the tab opens in.
        let folder: String? = input.sessionFolder ?? input.folder?.path
        let resumes: Bool = session != nil && input.sessionFolder != nil && !input.selectedEarlier
            && mayResume(input.kind, consent: input.quitConsent, safeMode: input.safeMode)
        let start = ChatStart(agentID: record.agent, folder: folder, resumeID: session?.id, resumeOnly: session != nil,
                              title: pane.userTitle)
        let chat = ChatRestore(start: start, resumes: resumes, draft: record.draft)
        return Decision(outcome: resumes ? .resume : .agentNote, session: session, folder: folder, sessionAgent: kind, chat: chat)
    }

    /// The restore's agent for a session's catalog agent.
    private static func restoreAgent(_ agent: ACPAgent) -> RestoreAgent? {
        switch agent.protocolKind {
        case .claudeStream: return .claude
        case .codexAppServer: return .codex
        case .acp: return nil
        }
    }
}

/// How a chat tab comes back (plan 037 U5). It never types into a shell: its host starts the agent, going on with the
/// conversation it had, or waits idle with a Resume button.
public struct ChatRestore: Equatable, Sendable {
    /// The chat its host starts: the agent, the folder, and the conversation it goes on with (never a new one in its
    /// place: `resumeOnly`).
    public var start: ChatStart
    /// The agent starts at once: an update restore or a consented quit restore, with the conversation's exact id and
    /// its folder still there, in the tab selected last of those that held it. Otherwise the tab waits idle.
    public var resumes: Bool
    /// The input box's draft, as the save kept it.
    public var draft: String?

    public init(start: ChatStart, resumes: Bool, draft: String? = nil) {
        self.start = start
        self.resumes = resumes
        self.draft = draft
    }
}

/// A chat tab's note wording (plan 037 U5), kept with the chat's decision rather than in the planner's generic note.
extension RestoreNote {
    /// A chat tab's note: it resumed its conversation, or waits with a Resume button. Nothing is typed, so whether the
    /// shell is ready never matters.
    func chatSentences(_ dates: (Date) -> String) -> [String] {
        let name = agent?.name ?? "The agent"
        if outcome == .resume, !safeMode {
            var said = ["Resumed \(name) session \(session?.id ?? "")."]
            if interrupted { said.append("Its last turn was cut off by \(afterQuit ? "the quit" : "the update") and did not continue.") }
            return said
        }
        guard let session else {
            return ["\(name) was running. Next Term can\u{2019}t tell which conversation it was, so Resume starts a new one."]
        }
        var said = ["\(name) was running. Resume goes on with session \(session.id)."]
        if interrupted { said.append("Its last turn was cut off by \(afterQuit ? "the quit" : "the update").") }
        said += sharedText
        return said
    }

    /// The keep-sessions sheet's words for a chat tab: it resumes in its own view, or waits for Resume.
    func chatListWords(_ name: String) -> String {
        outcome == .resume ? "\(name) resumes in its chat" : "\(name) waits for Resume"
    }
}
