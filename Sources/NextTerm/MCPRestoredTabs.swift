import AppKit
import NextTermCore

/// What MCP tells of each restored tab, and the calls a restore or an update's wait holds back (plan 003's U13).
///
/// A restored tab keeps its id (RestoreBuild), so an orchestrator's ids still work after the restart. Until the first
/// command the user or MCP starts in it after the restore, list_tabs, read_tab and wait_for_tab give its `restored`
/// details (MCPRestored). Input into it is refused while its action waits for the shell, and while its prompt holds the
/// line the restore put back and the user has not typed there: that rule plugs into MCPInputLine, the refusal each tool
/// that acts on a tab asks, so no tool can run, edit or close away a put-back line. The gate (`refusal`) holds back every
/// tool but those that read in safe mode, and new work outside the waited tabs while an update waits for them.
enum MCPRestoredTabs {
    /// Each restored tab's plan, by the id it came back with, until its details end.
    private static var plans: [UUID: PanePlan] = [:]
    /// The put-back rule, added to MCPInputLine's once.
    private static let rule: Void = {
        MCPInputLine.rules.append { (tab: TerminalTab) -> String? in MCPRestoredTabs.inputRefusal(tab) }
    }()

    /// The launch's restore built these panes (SessionRestore): each one's plan is kept for MCP.
    static func restored(_ panes: [RestoredPane]) {
        _ = rule
        for pane in panes { plans[pane.tab.id] = pane.plan }
    }

    /// The tab's details while they last: nil for a tab no restore brought back, or once a command ran there after it.
    static func details(_ tab: TerminalTab) -> MCPRestored? {
        guard let plan = plans[tab.id], let record = tab.restoredRecord, let pending = record.pending else { return nil }
        let run = tab.status.commandsRun
        let held = tab.remote == nil
            && MCPRestored.lineHeld(action: pending.action, state: pending.state, userTyped: tab.touchedByUser, commandsRun: run)
        let details = MCPRestored(reason: plan.reason, outcome: plan.outcome, action: pending.state, stateBefore: record.stateBefore,
                                  interrupted: record.interrupted, note: plan.note.text(), lineHeld: held)
        guard details.shows(commandsRun: run) else {
            plans[tab.id] = nil
            return nil
        }
        return details
    }

    /// `restored`, merged into a tab's result by list_tabs, read_tab and wait_for_tab; empty once the details end.
    static func fields(_ tab: TerminalTab) -> [String: Any] {
        guard let details = details(tab) else { return [:] }
        return ["restored": details.fields]
    }

    /// Why input into the tab is refused: its restore's action waits, or its put-back line is not the user's yet (R25).
    static func inputRefusal(_ tab: TerminalTab) -> String? {
        guard tab.remote == nil else { return nil }
        return details(tab)?.inputRefusal
    }

    /// Why MCPControl refuses `tool` before it runs, or nil: safe mode runs only the tools that read, and an update's wait
    /// refuses new work outside the tabs it waits for with `update_pending` (MCPRestoreGate).
    static func refusal(_ tool: String, _ arguments: [String: Any]) -> String? {
        MainActor.assumeIsolated {
            let safeMode = SessionRestore.shared.phase == .safeMode
            let update = UpdateKeepSessions.shared
            let waitSet: Set<UUID> = update.isWaiting ? update.flow?.waitSet ?? [] : []
            let waited: Set<String>? = update.isWaiting ? Set(waitSet.map { $0.uuidString.lowercased() }) : nil
            return MCPRestoreGate.refusal(tool: tool, tabID: arguments["tab_id"] as? String, safeMode: safeMode, waitingFor: waited)
        }
    }

    /// The quit's answer to each MCP call in flight (R26): for an update, that Next Term restarts, and to a wait_for_tab
    /// what the update does to its tab, from the plan the user's consent covers; for any other quit, that it quit. An
    /// update's quit leaves the socket file, so `nxtrm mcp` reads its refusal as the restart and tries reading tools again.
    static func drainAtQuit(update consent: UpdateConsent?) {
        let planned: [String: MCPServer.PlannedTab] = consent.map(MCPServer.planned) ?? [:]
        let update = consent != nil
        MCPControlServer.shared.drain(keepingSocket: update) { (request: MCPCalls.Request?, started: Bool) -> MCPServer.CallResult in
            MCPServer.quitAnswer(tool: request?.tool, arguments: request?.arguments ?? [:], started: started, update: update,
                                 planned: planned)
        }
    }
}
