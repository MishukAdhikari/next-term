import Foundation

/// What the restore decides for an agent's pane: a plain agent tab's resume or put-back line, and an agent session's
/// (`nxtrm agent NAME --resume ID`, plan 035 U7). Kept apart from the rest of the planner for its size.
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

    /// An agent session's tab (`nxtrm agent NAME`, plan 035 U7), still running at the save with the id its session
    /// reported: the session resumes as a plain agent tab's does, by `nxtrm agent NAME --resume ID` in the folder it ran
    /// in, on an update restore or a consented quit restore, never after a crash or in safe mode, where that line goes back
    /// unrun. In a shell without the integration, a note names it. Nil for anything else: its line is a command's.
    static func decide(agentSession input: PaneInput, integrated: Bool) -> Decision? {
        let pane = input.pane
        guard let record = pane.agentSession, pane.command?.running == true, let agent = ACPAgent.named(record.agent),
              agent.id == record.agent, agent.resumesSessions, AgentSessionVersion.isSessionID(record.sessionID),
              let kind = restoreAgent(agent) else { return nil }
        let line = agent.resumeLine(launcher: input.agentLauncher, sessionID: record.sessionID)
        let session = NamedSession(agent: kind, id: record.sessionID, naming: .exact)
        let folder = input.sessionFolder
        guard integrated else {
            return Decision(outcome: .agentNote, noteLine: line, session: session, folder: folder, sessionAgent: kind)
        }
        let resumes: Bool = mayResume(input.kind, consent: input.quitConsent, safeMode: input.safeMode) && folder != nil
        let outcome: RestoreOutcome = resumes ? .resume : .agentOnTheLine
        return Decision(outcome: outcome, line: line, noteLine: line, session: session, folder: folder, sessionAgent: kind)
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
