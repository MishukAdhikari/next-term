import AppKit
import NextTermCore

/// What MCP tells of each restored tab, and the calls a restore or an update's wait holds back (plan 003's U13).
///
/// A restored tab keeps its id (RestoreBuild), so an orchestrator's ids still work after the restart. Until the first
/// command the user or MCP starts in it after the restore, list_tabs, read_tab and wait_for_tab give its `restored`
/// details (MCPRestored). Input into it is refused while its action waits for the shell, and while its prompt holds the
/// line the restore put back and the user has not typed there: that rule plugs into MCPInputLine, the refusal each tool
/// that acts on a tab asks, so no tool can run, edit or close away a put-back line. The gate (`refusal`) holds back every
/// tool but those that read in safe mode, and new work outside the waited tabs while an update waits for them; while it
/// waits, each tab says whether it is waited for (`update_wait`). An automatic resume reads as one only once its start
/// watch settles it (StartWatcher, KTD6): a start that failed reads as its resume command on the line, with the agent's
/// error.
enum MCPRestoredTabs {
    /// Each restored tab's plan, by the id it came back with, until its details end.
    private static var plans: [UUID: PanePlan] = [:]
    /// How many commands had started at a restored tab's prompt when the user first put something in it (`typedByUser`):
    /// a resume ran only when its command started before that (MCPRestored.outcome).
    private static var beforeInput: [UUID: Int] = [:]
    /// What the start watch told of a restored tab's own resume, by its id, once the restore pressed its Return.
    private static var starts: [UUID: StartWatch.Report] = [:]
    /// The put-back rule, added to MCPInputLine's once.
    private static let rule: Void = {
        MCPInputLine.rules.append { (tab: TerminalTab) -> String? in MCPRestoredTabs.inputRefusal(tab) }
    }()

    /// The launch's restore built these panes (SessionRestore): each one's plan is kept for MCP.
    static func restored(_ panes: [RestoredPane]) {
        _ = rule
        for pane in panes { plans[pane.tab.id] = pane.plan }
    }

    /// The restore pressed an automatic resume's Return in the tab, and its start watch began (`watching`) or settled
    /// (RestoreActions): MCP reads the resume from its verdict.
    static func started(_ tab: TerminalTab, _ report: StartWatch.Report) {
        guard plans[tab.id] != nil else { return }
        starts[tab.id] = report
    }

    /// The user put something in the tab (MCPControl.typedByUser): of the commands started at its prompt, those before
    /// now are the restore's, and every one after it is the user's or MCP's.
    static func typedByUser(_ tab: TerminalTab) {
        guard plans[tab.id] != nil, beforeInput[tab.id] == nil else { return }
        beforeInput[tab.id] = tab.status.commandsAtPrompt
    }

    /// The tab's details while they last: nil for a tab no restore brought back, or once a command ran there after it.
    static func details(_ tab: TerminalTab) -> MCPRestored? {
        guard let plan = plans[tab.id], let record = tab.restoredRecord else { return nil }
        let typed = beforeInput[tab.id] ?? (tab.touchedByUser ? 0 : nil)
        let since = MCPRestored.Since(commands: tab.status.commandsAtPrompt, beforeInput: typed)
        guard let details = MCPRestored(plan: plan, record: record, since: since, start: starts[tab.id]) else {
            // Over for good once the count only grows: with the integration reported in, or on a server. A local shell's
            // count can still drop as its integration first reports in, taking back what its startup ran.
            if tab.remote != nil || tab.status.integrated {
                plans[tab.id] = nil
                beforeInput[tab.id] = nil
                starts[tab.id] = nil
            }
            return nil
        }
        return details
    }

    /// `restored`, merged into a tab's result by list_tabs, read_tab and wait_for_tab until the details end, and while an
    /// update waits for busy tabs, whether it waits for this one (KTD16).
    static func fields(_ tab: TerminalTab) -> [String: Any] {
        var fields = MCPRestoreGate.waitFields(tabID: tab.id.uuidString, waitingFor: waited())
        if let details = details(tab) { fields["restored"] = details.fields }
        return fields
    }

    /// Why input into the tab is refused: its restore's action waits, or its put-back line is not the user's yet (R25).
    static func inputRefusal(_ tab: TerminalTab) -> String? {
        guard tab.remote == nil else { return nil }
        return details(tab)?.inputRefusal
    }

    /// Why MCPControl refuses `tool` before it runs, or nil: safe mode runs only the tools that read, and an update's wait
    /// refuses new work outside the tabs it waits for with `update_pending` (MCPRestoreGate).
    static func refusal(_ tool: String, _ arguments: [String: Any]) -> String? {
        let safeMode = MainActor.assumeIsolated { SessionRestore.shared.phase == .safeMode }
        return MCPRestoreGate.refusal(tool: tool, tabID: arguments["tab_id"] as? String, safeMode: safeMode, waitingFor: waited())
    }

    /// The tabs an update waits for, by their ids as MCP gives them; nil while no update waits.
    private static func waited() -> Set<String>? {
        MainActor.assumeIsolated { () -> Set<String>? in
            let update = UpdateKeepSessions.shared
            guard update.isWaiting else { return nil }
            let waitSet: Set<UUID> = update.flow?.waitSet ?? []
            return Set(waitSet.map { (id: UUID) -> String in id.uuidString.lowercased() })
        }
    }

    /// The quit's answer to each MCP call in flight (R26): for an update, that Next Term restarts, and to a wait_for_tab
    /// what the update does to its tab, from the plan the user's consent covers; for any other quit, that it quit. An
    /// update's quit leaves the socket file, so `nxtrm mcp` reads its refusal as the restart and tries reading tools again.
    static func drainAtQuit(update consent: UpdateConsent?) {
        let restart = consent.map(MCPServer.UpdateRestart.init)
        MCPControlServer.shared.drain(keepingSocket: restart != nil) { (request: MCPCalls.Request?, started: Bool) -> MCPServer.CallResult in
            MCPServer.quitAnswer(tool: request?.tool, arguments: request?.arguments ?? [:], started: started, update: restart)
        }
    }
}
