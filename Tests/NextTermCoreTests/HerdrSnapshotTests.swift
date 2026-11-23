import Foundation
import Testing
@testable import NextTermCore

/// herdr's `api snapshot` read into workspaces > tabs > panes (plan 040 U6, U8, U9), from a scratch herdr 0.9.1 session:
/// two tabs in one workspace (one split down), a repository's workspace and a linked worktree's, and the metadata an
/// integration reported (a workspace token, a pane's title and state label). No one's real session.
@Suite struct HerdrSnapshotTests {
    static let snapshot = #"{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[],"focused_pane_id":"w1:p1","focused_tab_id":"w1:t1","focused_workspace_id":"w1","layouts":[{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w1:p1","panes":[{"focused":true,"pane_id":"w1:p1","rect":{"height":40,"width":120,"x":0,"y":0}}],"splits":[],"tab_id":"w1:t1","workspace_id":"w1","zoomed":false},{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w1:p2","panes":[{"focused":true,"pane_id":"w1:p2","rect":{"height":20,"width":120,"x":0,"y":0}},{"focused":false,"pane_id":"w1:p3","rect":{"height":20,"width":120,"x":0,"y":20}}],"splits":[{"direction":"down","id":"split_0_root","ratio":0.5,"rect":{"height":40,"width":120,"x":0,"y":0}}],"tab_id":"w1:t2","workspace_id":"w1","zoomed":true},{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w2:p1","panes":[{"focused":true,"pane_id":"w2:p1","rect":{"height":40,"width":120,"x":0,"y":0}}],"splits":[],"tab_id":"w2:t1","workspace_id":"w2","zoomed":false},{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w3:p1","panes":[{"focused":true,"pane_id":"w3:p1","rect":{"height":40,"width":120,"x":0,"y":0}}],"splits":[],"tab_id":"w3:t1","workspace_id":"w3","zoomed":false}],"panes":[{"agent_status":"unknown","cwd":"/private/tmp/nth","focused":true,"foreground_cwd":"/private/tmp/nth","label":"left","pane_id":"w1:p1","state_labels":{"working":"Thinking"},"tab_id":"w1:t1","title":"Fix login","workspace_id":"w1"},{"agent_status":"unknown","cwd":"/private/tmp/nth","focused":false,"foreground_cwd":"/private/tmp/nth","pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"},{"agent_status":"unknown","cwd":"/private/tmp/nth","focused":false,"foreground_cwd":"/private/tmp/nth","pane_id":"w1:p3","tab_id":"w1:t2","workspace_id":"w1"},{"agent_status":"unknown","cwd":"/private/tmp/nth/repo","focused":false,"foreground_cwd":"/private/tmp/nth/repo","pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2"},{"agent_status":"unknown","cwd":"/private/tmp/nth/.herdr/worktrees/repo/feat-x","focused":false,"foreground_cwd":"/private/tmp/nth/.herdr/worktrees/repo/feat-x","pane_id":"w3:p1","tab_id":"w3:t1","workspace_id":"w3"}],"protocol":22,"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"},{"agent_status":"unknown","focused":false,"label":"builds","number":2,"pane_count":2,"tab_id":"w1:t2","workspace_id":"w1"},{"agent_status":"unknown","focused":false,"label":"1","number":1,"pane_count":1,"tab_id":"w2:t1","workspace_id":"w2"},{"agent_status":"unknown","focused":false,"label":"1","number":1,"pane_count":1,"tab_id":"w3:t1","workspace_id":"w3"}],"version":"0.9.1","workspaces":[{"active_tab_id":"w1:t1","agent_status":"unknown","focused":true,"label":"main","number":1,"pane_count":3,"tab_count":2,"tokens":{"branch":"main"},"workspace_id":"w1"},{"active_tab_id":"w2:t1","agent_status":"unknown","focused":false,"label":"repo","number":2,"pane_count":1,"tab_count":1,"workspace_id":"w2","worktree":{"checkout_path":"/tmp/nth/repo","is_linked_worktree":false,"repo_key":"/private/tmp/nth/repo/.git","repo_name":"repo","repo_root":"/tmp/nth/repo"}},{"active_tab_id":"w3:t1","agent_status":"unknown","focused":false,"label":"feat-x","number":3,"pane_count":1,"tab_count":1,"workspace_id":"w3","worktree":{"checkout_path":"/tmp/nth/.herdr/worktrees/repo/feat-x","is_linked_worktree":true,"repo_key":"/private/tmp/nth/repo/.git","repo_name":"repo","repo_root":"/tmp/nth/repo"}}]},"type":"session_snapshot"}}"#

    @Test func workspacesHoldTheirTabsAndPanes() throws {
        let read = try #require(HerdrSnapshot.parse(Self.snapshot))
        #expect(read.version == "0.9.1" && read.workspaces.map(\.id) == ["w1", "w2", "w3"] && read.paneCount == 5)
        let main = try #require(read.workspace("w1"))
        #expect(main.label == "main" && main.focused && main.tokens == ["branch": "main"] && main.checkout == nil)
        #expect(main.tabs.map(\.id) == ["w1:t1", "w1:t2"] && main.tabs[1].label == "builds" && main.tabs[1].zoomed)
        #expect(main.tabs[1].panes.map(\.id) == ["w1:p2", "w1:p3"] && main.tabs[1].panes[1].rect?.y == 20)
        let left = main.tabs[0].panes[0]
        #expect(left.label == "left" && left.title == "Fix login" && left.stateLabels == ["working": "Thinking"] && left.focused)
        #expect(read.workspace("w3")?.linkedWorktree == true && read.workspace("w3")?.checkout == "/tmp/nth/.herdr/worktrees/repo/feat-x")
        #expect(read.workspace("w2")?.linkedWorktree == false && read.tab("w1:t2")?.workspace.id == "w1")
        #expect(HerdrSnapshot.parse("{}") == nil && HerdrSnapshot.parse("nope") == nil)
    }

    @Test func listTabsNamesThemWithIdsTheTabToolsTake() throws {
        let read = try #require(HerdrSnapshot.parse(Self.snapshot))
        let listed = read.listing(tabID: "ABC")
        #expect(listed.first?["id"] as? String == "abc/ws:w1")
        let tabs = try #require(listed.first?["tabs"] as? [[String: Any]])
        #expect(tabs.map { $0["id"] as? String } == ["abc/tab:w1:t1", "abc/tab:w1:t2"] && tabs[1]["zoomed"] as? Bool == true)
        let panes = try #require(tabs[0]["panes"] as? [[String: Any]])
        #expect(panes.first?["id"] as? String == "abc/w1:p1" && panes.first?["title"] as? String == "Fix login")
        #expect(HerdrTarget.parse("abc/tab:w1:t2")?.containerKind?.kind == .tab && HerdrTarget.parse("abc/tab:w1:t2")?.containerKind?.id == "w1:t2")
        #expect(HerdrTarget.parse("abc/ws:w3")?.containerKind?.kind == .workspace && HerdrTarget.parse("abc/w1:p1")?.containerKind == nil)
    }

    @Test func layoutTabsWorkspacesAndWorktreesAreHerdrsOwnVerbs() {
        let exe = "/x/herdr"
        func argv(_ command: HerdrCommand) -> [String]? { command.argv(executable: exe, session: nil, text: nil)?.first?.first.map { Array($0.dropFirst()) } }
        #expect(argv(.zoom(pane: "w1:p1", on: true)) == ["pane", "zoom", "w1:p1", "--on"])
        #expect(argv(.zoom(pane: "w1:p1", on: nil)) == ["pane", "zoom", "w1:p1", "--toggle"])
        #expect(argv(.focusNeighbor(pane: "w1:p1", direction: .left)) == ["pane", "focus", "--direction", "left", "--pane", "w1:p1"])
        #expect(argv(.move(pane: "w1:p3", toTab: nil)) == ["pane", "move", "w1:p3", "--new-tab", "--no-focus"])
        #expect(argv(.move(pane: "w1:p3", toTab: "w1:t1")) == ["pane", "move", "w1:p3", "--tab", "w1:t1", "--split", "right", "--no-focus"])
        #expect(argv(.snapshot) == ["api", "snapshot"])
        #expect(argv(.renameTab(tab: "w1:t2", label: "builds")) == ["tab", "rename", "w1:t2", "builds"])
        #expect(argv(.closeWorkspace(workspace: "w2")) == ["workspace", "close", "w2"])
        #expect(argv(.newWorkspace(directory: "/srv/app", label: "app")) == ["workspace", "create", "--cwd", "/srv/app", "--label", "app", "--no-focus"])
        #expect(argv(.newWorktree(directory: "/srv/app", branch: "fix/login"))
            == ["worktree", "create", "--cwd", "/srv/app", "--branch", "fix/login", "--no-focus", "--trust-repository"])
        #expect(argv(.removeWorktree(workspace: "w3")) == ["worktree", "remove", "--workspace", "w3"])
        // Never --force, never a group close.
        #expect(!(argv(.removeWorktree(workspace: "w3")) ?? []).contains("--force") && !(argv(.closeWorkspace(workspace: "w2")) ?? []).contains("--group"))
    }

    @Test func namesHerdrWouldMisreadAreRefused() {
        #expect(HerdrCommand.renameTab(tab: "w1:t2", label: "--clear").refusal(session: nil) != nil)
        #expect(HerdrCommand.renameTab(tab: "w1:t2", label: String(repeating: "a", count: 61)).refusal(session: nil) != nil)
        #expect(HerdrCommand.newWorktree(directory: "/srv/app", branch: "-x").refusal(session: nil) != nil)
        #expect(HerdrCommand.newWorktree(directory: "/srv/app", branch: "a..b").refusal(session: nil) != nil)
        #expect(HerdrCommand.newWorktree(directory: "/srv/app", branch: "fix login").refusal(session: nil) != nil)
        #expect(HerdrCommand.newWorktree(directory: "/srv/app", branch: "fix/login-2").refusal(session: nil) == nil)
        #expect(HerdrCommand.move(pane: "w1:p1", toTab: "w1 t1").refusal(session: nil) != nil)
        #expect(HerdrCommand.createdWorkspace(#"{"result":{"workspace":{"workspace_id":"w3"},"root_pane":{"pane_id":"w3:p1"}}}"#) == "w3")
    }
}
