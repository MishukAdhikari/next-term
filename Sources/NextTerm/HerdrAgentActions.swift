import AppKit
import NextTermCore

/// What the user does to one of herdr's agents from its row's menu (plan 040 U1, U3), by herdr's own commands: Rename…
/// (`agent rename`) and New Agent Beside… (`pane split`, then `agent start` in the new pane, with a kind herdr there
/// lists). The user's click is the yes, so nothing asks again; an agent over MCP asks on the Mac instead (HerdrMCP).
@MainActor
enum HerdrAgentActions {
    /// The sheet shown now, for the self-test; nil when none.
    static var shown: NSAlert?

    /// Rename…: a field with herdr's name for it; empty clears it.
    static func rename(tab: TerminalTab, pane: String) {
        let agent = tab.herdrTracker.agents.first { $0.paneID == pane }
        let field = NSTextField(string: agent?.customName ?? "")
        field.placeholderString = "Lower-case letters, digits, _ and -"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename the agent in herdr"
        alert.informativeText = "herdr's name for the agent in pane \(pane). Leave it empty to clear the name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: tab, focus: field) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name: String = field.stringValue.trimmingCharacters(in: .whitespaces)
            HerdrMCP.renameForUser(HerdrAgentRef(tab: tab, pane: pane), pane: pane, to: name.isEmpty ? nil : name) { problem in
                guard let problem else { return }
                MainActor.assumeIsolated { say("Couldn’t rename the agent", problem, in: tab) }
            }
        }
    }

    /// New Agent Beside…: the kinds herdr there lists, a name and a side; herdr splits the pane, then starts the agent.
    static func newAgent(tab: TerminalTab, beside pane: String) {
        HerdrRunner.run(.startKinds, for: tab) { result in
            MainActor.assumeIsolated {
                guard case .text(let help) = result, case let kinds = HerdrCommand.kinds(fromHelp: help), !kinds.isEmpty else {
                    return say("herdr listed no agent kinds", "Next Term asks herdr which agents it starts (agent start --help); it answered none.", in: tab)
                }
                askForAgent(tab: tab, beside: pane, kinds: kinds)
            }
        }
    }

    private static func askForAgent(tab: TerminalTab, beside pane: String, kinds: [String]) {
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: kinds)
        let side = NSPopUpButton(frame: .zero, pullsDown: false)
        side.addItems(withTitles: ["Beside it", "Below it"])
        let name = NSTextField(string: "")
        name.placeholderString = "Name (default: the kind)"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Agent:"), kind], [NSTextField(labelWithString: "Name:"), name],
                                      [NSTextField(labelWithString: "Place:"), side]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 90)
        let alert = NSAlert()
        alert.messageText = "Start an agent in herdr"
        alert.informativeText = "herdr splits pane \(pane) and starts the agent in the new pane. It runs there until it ends."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: tab, focus: name) { response in
            guard response == .alertFirstButtonReturn, let chosen = kind.titleOfSelectedItem else { return }
            let typed: String = name.stringValue.trimmingCharacters(in: .whitespaces)
            start(tab: tab, beside: pane, kind: chosen, name: typed.isEmpty ? chosen : typed, down: side.indexOfSelectedItem == 1)
        }
    }

    private static func start(tab: TerminalTab, beside pane: String, kind: String, name: String, down: Bool) {
        let split = HerdrCommand.split(pane: pane, direction: down ? .down : .right, directory: nil)
        let check = HerdrCommand.startAgent(name: name, kind: kind, pane: pane, words: [])
        if let refusal = split.refusal(session: nil) ?? check.refusal(session: nil) { return say("Couldn’t start the agent", refusal, in: tab) }
        HerdrRunner.run(split, for: tab) { made in
            MainActor.assumeIsolated {
                guard case .json(let json) = made, let newPane = HerdrCommand.splitPane(json) else {
                    return say("herdr made no new pane", HerdrMCP.problem(made, pane: pane, sent: false) ?? "herdr's answer named no pane.", in: tab)
                }
                let start = HerdrCommand.startAgent(name: name, kind: kind, pane: newPane, words: [])
                HerdrRunner.run(start, for: tab, timeout: Double(HerdrCommand.startWait) / 1000 + 10) { started in
                    guard let problem = HerdrMCP.problem(started, pane: newPane) else { return }
                    MainActor.assumeIsolated { say("\(kind) did not start", problem, in: tab) }
                }
            }
        }
    }

    private static func present(_ alert: NSAlert, in tab: TerminalTab, focus: NSView, then: @escaping (NSApplication.ModalResponse) -> Void) {
        shown = alert
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if shown === alert { shown = nil }
            then(response)
        }
        if let window = tab.view.window {
            alert.beginSheetModal(for: window, completionHandler: done)
            alert.window.initialFirstResponder = focus
        } else {
            done(alert.runModal())
        }
    }

    private static func say(_ title: String, _ text: String, in tab: TerminalTab) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window = tab.view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
