import Foundation
import Testing
@testable import NextTermCore

/// edit_host's change to a saved host, end_session's look at who is attached, and what a remote connection may not reach
/// (plan 010a U6a, U11).
@Suite struct HostEditTests {
    static let saved = RemoteHost(id: "abc123", name: "web-1", destination: "dev@203.0.113.5", port: 2222, directory: "~/app", keep: .tmux)

    func apply(_ arguments: [String: Any], others: [RemoteHost] = []) -> Result<HostEdit.Applied, HostEditFailure> {
        HostEdit.parse(arguments).flatMap { (edit: HostEdit) in edit.apply(to: Self.saved, others: [Self.saved] + others) }
    }

    /// null counts as not given, as for the other tools.
    @Test func nullIsNotGiven() throws {
        let null = NSNull()
        let applied = try apply(["port": null, "keep": null, "tmux_prefix": null, "tmux_history": null, "clear_port": null,
                                 "name": null, "directory": "/srv/api"]).get()
        #expect(applied.host.port == 2222 && applied.host.keep == .tmux && applied.host.name == "web-1")
        #expect(applied.host.tmuxPrefix == nil && applied.host.tmuxHistory == nil)
        #expect(applied.changes == ["folder: ~/app → /srv/api"])
    }

    @Test func onlyTheFieldsGivenChange() throws {
        let applied = try apply(["directory": "/srv/api", "tmux_prefix": "C-a", "tmux_history": 100_000]).get()
        #expect(applied.host.directory == "/srv/api")
        #expect(applied.host.tmuxPrefix == .ctrlA && applied.host.tmuxHistory == 100_000)
        #expect(applied.host.destination == Self.saved.destination && applied.host.port == 2222 && applied.host.keep == .tmux)
        #expect(!applied.repointed && applied.host.id == Self.saved.id)
        #expect(applied.changes == ["folder: ~/app → /srv/api", "tmux prefix: C-b → C-a", "tmux history: 50000 → 100000 lines"])
        // tmux's own values are saved as none.
        let back = try HostEdit(tmuxPrefix: .ctrlB, tmuxHistory: 50_000).apply(to: applied.host, others: []).get()
        #expect(back.host.tmuxPrefix == nil && back.host.tmuxHistory == nil)
    }

    @Test func aNewDestinationOrPortIsAnotherServerWithANewID() throws {
        let moved = try apply(["destination": "dev@203.0.113.9"]).get()
        #expect(moved.repointed && moved.host.id != Self.saved.id)
        #expect(moved.changes == ["destination: dev@203.0.113.5 → dev@203.0.113.9"])
        let ported = try apply(["clear_port": true]).get()
        #expect(ported.repointed && ported.host.port == nil && ported.changes == ["port: 2222 → ssh’s own"])
        // A rename alone keeps the id.
        let renamed = try apply(["name": "web-main"]).get()
        #expect(!renamed.repointed && renamed.host.id == Self.saved.id)
    }

    @Test func whatTheHostsRulesRefuseIsSaidBeforeAnythingIsAsked() {
        func refusal(_ arguments: [String: Any], others: [RemoteHost] = []) -> String? {
            if case .failure(let failure) = apply(arguments, others: others) { return failure.text }
            return nil
        }
        #expect(refusal([:]) == "Give at least one thing to change.")
        #expect(refusal(["port": 22, "clear_port": true]) == "Give port or clear_port, not both.")
        #expect(refusal(["destination": "-oProxyCommand=touch /tmp/x"]) != nil)
        #expect(refusal(["port": 70_000]) == "The port must be between 1 and 65535.")
        #expect(refusal(["directory": "srv"]) != nil)
        #expect(refusal(["keep": "screen"]) == "keep is off, tmux or herdr.")
        #expect(refusal(["tmux_prefix": "C-q"]) == "tmux_prefix is one of C-b, C-a, C-Space, C-].")
        #expect(refusal(["tmux_history": 999]) == "tmux history must be between 1,000 and 200,000 lines.")
        #expect(refusal(["tmux_history": "lots"]) != nil)
        let other = RemoteHost(id: "def456", name: "web-2", destination: "dev@203.0.113.7")
        #expect(refusal(["name": "WEB-2"], others: [other]) == "Another saved host is named “WEB-2”.")
    }

    @Test func nothingChangedIsNoChange() throws {
        let same = try apply(["directory": "~/app", "keep": "tmux"]).get()
        #expect(same.changes.isEmpty && !same.repointed)
    }

    @Test func theClientsScriptAnswersWhoIsAttachedOrThatTheSessionIsGone() {
        let script = RemoteShell.clientsScript(session: "nt-app-1")
        #expect(script.contains("has-session -t '=nt-app-1'") && script.contains("list-clients -t '=nt-app-1' -F '#{client_tty}'"))
        let marker = RemoteShell.marker
        #expect(RemoteShell.parseClients("\n\(marker)\n/dev/pts/3\n/dev/ttys004\n") == .attached(["/dev/pts/3", "/dev/ttys004"]))
        #expect(RemoteShell.parseClients("\n\(marker)\n") == .attached([]))
        #expect(RemoteShell.parseClients("\n\(marker)\nnone\n") == .gone)
        #expect(RemoteShell.parseClients("ssh: connect to host web-1 port 22: Connection refused") == .unread)
    }

    @Test func aRemoteConnectionReachesNoHerdrAgentNorTheNewChanges() {
        for tool in ["edit_host", "end_session", "rename_tab"] {
            #expect(MCPRemoteReach.refusal(tool, ["host": "web-1"]) == MCPRemoteReach.text, "\(tool)")
        }
        let tab = "6f1c2a7e-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
        #expect(MCPRemoteReach.refusal("read_tab", ["tab_id": tab + "/w1:p3"]) == MCPRemoteReach.text)
        #expect(MCPRemoteReach.refusal("read_tab", ["tab_id": tab + "/@m1/w1:p3"]) == MCPRemoteReach.text)
        #expect(MCPRemoteReach.refusal("read_tab", ["tab_id": tab]) == nil)
        #expect(MCPRemoteReach.refusal("list_tabs", [:]) == nil)
        #expect(MCPRemoteReach.refusal("add_host", ["name": "web-1"]) == nil)
    }
}
