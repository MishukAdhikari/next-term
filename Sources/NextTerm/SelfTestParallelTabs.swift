import AppKit
import NextTermCore

/// Parallel work in tabs, Next Term's part: a tab an agent opens with new_tab knows which tab opened it (list_tabs'
/// opened_by, and its tooltip), the worker's own row tells its agent to open no tabs; settings_get and settings_set know
/// agents_offer_tabs and agent_spinner, and Settings › Editor's box follows. The skill itself is the app's alone: the
/// self-test never writes to the user's agent folders (BuiltInSkillTests write one in a home of their own).
extension SelfTest {
    static func parallelTabsChecks(_ c: TerminalWindowController, proj: URL) async {
        let lead = c.addTab(directory: proj.path, select: false)
        var opener: TerminalTab?
        defer {
            // The worker opens in the window of its folder's project, which may be another one than this.
            if let opener, let owner = AppDelegate.shared.controllers.first(where: { $0.tabs.contains { $0 === opener } }) { owner.remove(opener) }
            c.remove(lead)
        }
        guard await wait(20, { lead.status.integrated }) else { return check(false, "parallel tabs: the lead tab's shell starts") }

        // The lead's agent opens a worker.
        var opened = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("new_tab", ["directory": proj.path, "title": "login-test"], caller: lead.view.process.shellPid) { opened = $0 }
        _ = await wait(10) { !opened.text.isEmpty }
        let id = (try? JSONSerialization.jsonObject(with: Data(opened.text.utf8)) as? [String: Any])?["id"] as? String
        opener = AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == id }
        guard let worker = opener else { return check(false, "parallel tabs: new_tab opens a worker tab", opened.text) }
        check(worker.openedBy == lead.id && worker.title == "login-test" && worker.tooltip.contains("Started by “\(lead.title)”"),
              "parallel tabs: a tab an agent opens knows its opener, and its tooltip says so", worker.tooltip)

        // list_tabs, as the worker's agent sees it.
        guard await wait(20, { worker.status.integrated }) else { return check(false, "parallel tabs: the worker's shell starts") }
        var listed = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("list_tabs", [:], caller: worker.view.process.shellPid) { listed = $0 }
        _ = await wait(10) { !listed.text.isEmpty }
        let rows = ((try? JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])?["windows"] as? [[String: Any]] ?? [])
            .flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
        let own = rows.first { $0["you"] as? Bool == true }
        let leadRow = rows.first { $0["id"] as? String == lead.id.uuidString.lowercased() }
        check(own?["opened_by"] as? String == lead.id.uuidString.lowercased() && (own?["note"] as? String)?.contains("open no tabs") == true
              && leadRow != nil && leadRow?["opened_by"] == nil,
              "parallel tabs: list_tabs gives the worker opened_by and tells its agent to open no tabs; the lead has none",
              String(listed.text.prefix(400)))

        // The switch, through MCP (approved by a grant here), followed by Settings › Editor.
        let app = AppDelegate.shared!
        let offerBefore = app.agentsOfferTabs, spinnerBefore = AgentSpinner.current
        defer {
            app.agentsOfferTabs = offerBefore
            AgentSpinner.current = spinnerBefore
        }
        let editor = EditorSettingsView()
        var set = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("settings_set", ["values": ["agents_offer_tabs": !offerBefore, "agent_spinner": "still"]], caller: nil,
                        approval: .preApprovedByGrant("g-selftest")) { set = $0 }
        _ = await wait(10) { !set.text.isEmpty }
        check(app.agentsOfferTabs == !offerBefore && AgentSpinner.current == .still && editor.offerTabs.state == (offerBefore ? .off : .on),
              "parallel tabs: settings_set changes agents_offer_tabs and agent_spinner, and Settings › Editor follows", set.text)
        var got = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("settings_get", [:], caller: nil) { got = $0 }
        _ = await wait(10) { !got.text.isEmpty }
        check(got.text.contains("agents_offer_tabs") && got.text.contains("agent_spinner") && got.text.contains("notify_commands"),
              "parallel tabs: settings_get lists them", String(got.text.prefix(300)))
    }
}
