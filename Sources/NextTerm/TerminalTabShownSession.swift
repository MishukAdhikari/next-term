import Foundation
import NextTermCore

/// The session OpenCode shows, kept for the restore (OpencodeShownSession). OpenCode titles the tab "OC | <session
/// title>", and names the session nowhere else after `opencode -c` or a switch inside it. Matching that title reads
/// OpenCode's store, so a local OpenCode tab looks it up off the main thread when the title changes, and the save, which
/// captures every tab on the main thread, reads only the id the tab kept.
extension TerminalTab {
    private static let shownLookups = DispatchQueue(label: "nextterm.opencode-shown", qos: .utility)

    /// When the OpenCode in front started, by the wall clock (as the session list has it), while a local one runs.
    private var opencodeStart: Date? {
        guard remote == nil, !exited, status.running, status.kind == .agent, let since = status.runningSince else { return nil }
        let agent = AgentKind(program: status.program) ?? AgentKind(program: CommandClassifier.programName(status.expandedCommand))
        guard agent == .opencode else { return nil }
        return SessionStore.startDate(of: self, since: since)
    }

    /// Looks the tab's title up when it changed, or when a lookup that found nothing is due again
    /// (OpencodeShownSession.retryAfter), and keeps the id found.
    func matchShownSession() {
        guard let start = opencodeStart, let ask = shownSession.ask(title: programTitle, start: start, at: Self.now) else { return }
        // OpenCode records the folder it runs in, which leads the tab's foreground group (`cd web && opencode`).
        let pgid = tcgetpgrp(view.process.childfd)
        let folder = (pgid > 0 ? ProcessInspector.currentDirectory(of: pgid) : nil) ?? currentDirectory()
        let home = RestorePlanning.agentHome
        Self.shownLookups.async { [weak self] in
            let id = OpencodeShownSession.lookUp(ask, in: folder, home: home)
            DispatchQueue.main.async {
                guard let self else { return }
                self.shownSession.found(id, for: ask)
                guard id == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + OpencodeShownSession.retryAfter) { [weak self] in
                    self?.matchShownSession()
                }
            }
        }
    }

    /// The id of the session OpenCode shows now, as last looked up: nil when none was found, or the title or the agent
    /// changed since.
    var shownSessionID: String? {
        guard let start = opencodeStart else { return nil }
        return shownSession.id(title: programTitle, start: start)
    }
}
