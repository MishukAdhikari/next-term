import AppKit
import NextTermCore

/// Plan 040 U1–U4 on the stand-in herdr (herdrAgentChecks' own, in the remote part): start_agent beside a pane, waits
/// for a state and for text, rename_tab on an agent the caller started, new_tab beside a herdr pane running a command,
/// that pane read and closed, and the row menu's Rename… and New Agent Beside…. Each is herdr's own command, read back
/// from the stand-in's log of its calls.
extension SelfTest {
    #if DEBUG
    static func herdrParityChecks(tab: TerminalTab, id: String, herdrTabID: String, read: () -> String, clearCalls: () -> Void,
                                  write: (String, String) -> Void) async {
        // start_agent beside one of its panes: herdr splits that pane, then starts the agent in the new one.
        clearCalls()
        let call = Task { await herdrTool("start_agent", ["tab_id": herdrTabID, "kind": "codex", "name": "helper", "split_beside": "w2:p1", "direction": "down"]) }
        _ = await wait(20) { MCPWriteControl.pending?.window != nil }
        let window = MCPWriteControl.pending?.window
        let shown = SelfTest.texts(window?.window?.contentView)
        check(window != nil && shown.contains("herdr pane split w2:p1 --direction down --no-focus") && shown.contains("below w2:p1"),
              "herdr parity: start_agent beside a pane asks first, naming herdr's pane split", shown)
        window?.approveButton.performClick(nil)
        let started = await call.value
        let log = read()
        check(!started.isError && log.contains("pane split w2:p1 --direction down --no-focus|")
              && log.contains("agent start helper --kind codex --pane w2:p7 --timeout 20000|") && started.json?["id"] as? String == herdrTabID + "/w2:p7",
              "herdr parity: start_agent beside a pane splits it, then starts the agent in the new pane", started.text)

        // Waits: herdr's own agent wait --until and pane wait-output.
        clearCalls()
        let until = await herdrTool("wait_for_tab", ["tab_id": id, "until": ["idle", "blocked"], "timeout_seconds": 20])
        check(!until.isError && read().contains("agent wait w2:p1 --until idle --until blocked --timeout 20000|"),
              "herdr parity: wait_for_tab until waits with herdr's agent wait --until", until.text)
        clearCalls()
        let matched = await herdrTool("wait_for_tab", ["tab_id": id, "match": "tests passed", "timeout_seconds": 20])
        check(!matched.isError && read().contains("pane wait-output w2:p1 --match tests passed --source recent --timeout 20000|"),
              "herdr parity: wait_for_tab match waits with herdr's pane wait-output", matched.text)
        let badState = await herdrTool("wait_for_tab", ["tab_id": id, "until": ["asleep"]])
        check(badState.isError && badState.text.contains("asleep"), "herdr parity: wait_for_tab refuses a state herdr has none of", badState.text)

        // rename_tab on an agent the caller started: herdr's agent rename.
        HerdrMCP.recordOpener(id, caller: nil)
        clearCalls()
        let renamed = await herdrTool("rename_tab", ["tab_id": id, "title": "reviewer"])
        check(!renamed.isError && read().contains("agent rename w2:p1 reviewer|"), "herdr parity: rename_tab renames an agent the caller started in herdr", renamed.text)
        let badName = await herdrTool("rename_tab", ["tab_id": id, "title": "Not A Name"])
        check(badName.isError && !read().contains("Not A Name"), "herdr parity: a name herdr would not take is refused before asking herdr", badName.text)

        // new_tab beside a herdr pane with a command: pane split, then pane run, after Approve.
        clearCalls()
        let run = Task { await herdrTool("new_tab", ["directory": "/srv/web", "split_beside": id, "command": "npm test"]) }
        _ = await wait(20) { MCPWriteControl.pending?.window != nil }
        let runWindow = MCPWriteControl.pending?.window
        check(runWindow != nil && SelfTest.texts(runWindow?.window?.contentView).contains("npm test"),
              "herdr parity: new_tab beside a herdr pane asks first, naming the command", SelfTest.texts(runWindow?.window?.contentView))
        runWindow?.approveButton.performClick(nil)
        let ran = await run.value
        let runLog = read()
        let paneID = herdrTabID + "/w2:p7"
        check(!ran.isError && runLog.contains("pane split w2:p1 --direction right --cwd /srv/web --no-focus|") && runLog.contains("pane run w2:p7 npm test|")
              && ran.json?["id"] as? String == paneID,
              "herdr parity: new_tab beside a herdr pane splits it and runs the command with herdr's pane run", ran.text)

        // That pane has no agent: read_tab reads it, close_tab closes it after Approve.
        write("herdr-read", "npm test\n4 passing\n")
        clearCalls()
        let paneRead = await herdrTool("read_tab", ["tab_id": paneID])
        check(!paneRead.isError && (paneRead.json?["screen"] as? String ?? "").contains("4 passing") && read().contains("read w2:p7"),
              "herdr parity: read_tab reads a herdr pane with no agent", paneRead.text)
        write("herdr-panes", #"{"id":"cli:pane:list","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"},{"pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2"},{"pane_id":"w2:p7","tab_id":"w2:t1","workspace_id":"w2"}]}}"#)
        clearCalls()
        let closing = Task { await herdrTool("close_tab", ["tab_id": paneID]) }
        _ = await wait(20) { MCPWriteControl.pending?.window != nil }
        let closeWindow = MCPWriteControl.pending?.window
        check(closeWindow != nil && SelfTest.texts(closeWindow?.window?.contentView).contains("herdr pane close w2:p7"),
              "herdr parity: close_tab on a plain herdr pane asks first", SelfTest.texts(closeWindow?.window?.contentView))
        closeWindow?.approveButton.performClick(nil)
        let closed = await closing.value
        check(!closed.isError && read().contains("pane close w2:p7|"), "herdr parity: close_tab, approved, closes the pane with herdr's pane close", closed.text)

        // The row menu offers herdr's own Rename… and New Agent Beside…, and (U5–U7) its place in herdr.
        let titles: [String] = HerdrAgentMenu.rowMenu(tab: tab, pane: "w2:p1").items.map(\.title)
        check(titles.contains("Rename…") && titles.contains("New Agent Beside…"), "herdr parity: an agent's row menu has Rename… and New Agent Beside…",
              titles.joined(separator: " | "))
        check(["Zoom in herdr", "Move to a New herdr Tab", "Rename herdr Tab…", "Rename herdr Workspace…", "New Worktree Workspace…"].allSatisfy(titles.contains),
              "herdr parity: an agent's row menu has Zoom, Move to a New herdr Tab, Rename herdr Tab and Workspace, New Worktree Workspace",
              titles.joined(separator: " | "))
        await herdrLayoutChecks(tab: tab, id: id, herdrTabID: herdrTabID, read: read, clearCalls: clearCalls, write: write)
    }

    /// U5–U9: zoom and a neighbour's focus, herdr's tabs and workspaces in list_tabs and the tab tools, a worktree for
    /// start_agent and removed by close_tab.
    static func herdrLayoutChecks(tab: TerminalTab, id: String, herdrTabID: String, read: () -> String, clearCalls: () -> Void,
                                  write: (String, String) -> Void) async {
        write("herdr-snapshot", HerdrSnapshotFixture.json)
        func approved(_ tool: String, _ arguments: [String: Any]) async -> (shown: String, result: (json: [String: Any]?, text: String, isError: Bool)) {
            clearCalls()
            let call = Task { await herdrTool(tool, arguments) }
            _ = await wait(20) { MCPWriteControl.pending?.window != nil }
            let window = MCPWriteControl.pending?.window
            let shown = SelfTest.texts(window?.window?.contentView)
            window?.approveButton.performClick(nil)
            return (shown, await call.value)
        }
        // list_tabs with herdr_layout: one api snapshot, workspaces > tabs > panes with ids the tab tools take.
        clearCalls()
        let listed = await herdrTool("list_tabs", ["herdr_layout": true])
        let rows: [[String: Any]] = (listed.json?["windows"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
        let layout: [[String: Any]] = rows.first { $0["id"] as? String == herdrTabID }?["herdr_workspaces"] as? [[String: Any]] ?? []
        check(read().contains("api snapshot|") && layout.map { $0["id"] as? String } == [herdrTabID + "/ws:w1", herdrTabID + "/ws:w2", herdrTabID + "/ws:w3"]
              && (layout.first?["tokens"] as? [String: String]) == ["branch": "main"],
              "herdr parity: list_tabs herdr_layout nests herdr's workspaces, tabs and panes from one api snapshot", "\(layout.first ?? [:])")

        let zoomed = await approved("zoom_pane", ["tab_id": id])
        check(zoomed.shown.contains("herdr pane zoom w2:p1 --on") && !zoomed.result.isError && read().contains("pane zoom w2:p1 --on|"),
              "herdr parity: zoom_pane on a herdr agent asks, then zooms it with herdr's pane zoom", zoomed.result.text)
        let focused = await approved("focus_tab", ["tab_id": id, "direction": "left"])
        check(!focused.result.isError && read().contains("pane focus --direction left --pane w2:p1|"),
              "herdr parity: focus_tab with a direction moves herdr's focus to the neighbour", focused.result.text)
        let closedTab = await approved("close_tab", ["tab_id": herdrTabID + "/tab:w1:t2"])
        check(closedTab.shown.contains("2 panes") && !closedTab.result.isError && read().contains("tab close w1:t2|"),
              "herdr parity: close_tab on a herdr tab asks, naming its panes, then herdr closes it", closedTab.result.text)
        let notLinked = await herdrTool("close_tab", ["tab_id": herdrTabID + "/ws:w2", "remove_worktree": true])
        check(notLinked.isError && notLinked.text.contains("linked worktree"), "herdr parity: remove_worktree is refused for a workspace that is no linked worktree", notLinked.text)
        let removed = await approved("close_tab", ["tab_id": herdrTabID + "/ws:w3", "remove_worktree": true])
        check(removed.shown.contains("deletes the checkout") && !removed.result.isError && read().contains("worktree remove --workspace w3|"),
              "herdr parity: close_tab remove_worktree removes a linked worktree with herdr's worktree remove", removed.result.text)
        let renamedOther = await herdrTool("rename_tab", ["tab_id": herdrTabID + "/ws:w1", "title": "x"])
        check(renamedOther.isError, "herdr parity: rename_tab refuses a herdr workspace the caller did not make", renamedOther.text)

        // start_agent in a new worktree: herdr's worktree create, then agent start in its pane; that workspace is the caller's.
        let worktree = await approved("start_agent", ["tab_id": herdrTabID, "kind": "codex", "name": "fixer", "directory": "/srv/web", "worktree": "fix-login"])
        check(worktree.shown.contains("git worktree") && !worktree.result.isError
              && read().contains("worktree create --cwd /srv/web --branch fix-login --no-focus --trust-repository|")
              && read().contains("agent start fixer --kind codex --pane w9:p1"),
              "herdr parity: start_agent with worktree makes the worktree with herdr, then starts the agent in it", worktree.result.text)
        clearCalls()
        let renamedOwn = await herdrTool("rename_tab", ["tab_id": herdrTabID + "/ws:w9", "title": "login fix"])
        check(!renamedOwn.isError && read().contains("workspace rename w9 login fix|"), "herdr parity: rename_tab renames a workspace start_agent made", renamedOwn.text)
    }
    #endif
}
