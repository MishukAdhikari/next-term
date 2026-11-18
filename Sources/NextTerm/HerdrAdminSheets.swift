import AppKit
import NextTermCore

/// herdr itself, from an agent row's herdr menu (plan 040 U10–U13), each by herdr's own command and each change
/// confirmed in a sheet first: its sessions (stop, delete), its saved machines (rename, enable or disable, remove), its
/// agent integrations (install, uninstall) and its own state (version, channel, config check, reload, and an update run
/// in a tab the user watches). Never `server stop`, never `machine add` (herdr's own prompts), never `--force`.
@MainActor
enum HerdrAdminSheets {
    /// The sheet shown now, for the self-test.
    static var shown: NSAlert?

    // MARK: sessions (U10)

    static func sessions(tab: TerminalTab) {
        HerdrRunner.run(.sessions, for: tab) { listed in
            MainActor.assumeIsolated {
                guard case .json(let json) = listed, let sessions = HerdrSession.parse(json), !sessions.isEmpty else {
                    return say("herdr listed no sessions", HerdrMCP.problem(listed, pane: "", sent: false) ?? "herdr there gave no sessions.", in: tab)
                }
                let pick = popUp(sessions.map { "\($0.name)\($0.isDefault ? " (default)" : "") — \($0.running ? "running" : "stopped")" })
                let alert = sheet("herdr sessions", "Stop a running session (every pane in it stops), or delete a stopped one's files.",
                                  accessory: pick, buttons: ["Stop…", "Delete…", "Close"])
                present(alert, in: tab) { response in
                    guard response != .alertThirdButtonReturn else { return }
                    let session = sessions[max(0, pick.indexOfSelectedItem)]
                    let deleting: Bool = response == .alertSecondButtonReturn
                    if deleting == session.running {
                        return say("Couldn’t do that", deleting ? "“\(session.name)” is running: stop it first." : "“\(session.name)” is not running.", in: tab)
                    }
                    if !deleting, shownHere(session.name, default: sessions.first(where: \.isDefault)?.name, from: tab) {
                        return say("Close its tab first", "A tab here shows herdr session “\(session.name)”.", in: tab)
                    }
                    confirm(deleting ? "Delete herdr session “\(session.name)”?" : "Stop herdr session “\(session.name)”?",
                            deleting ? "herdr deletes its saved layout." : "Every pane in it, and what runs there, stops.",
                            button: deleting ? "Delete" : "Stop", in: tab) {
                        run(deleting ? .deleteSession(name: session.name) : .stopSession(name: session.name), in: tab, failing: "Couldn’t do that")
                    }
                }
            }
        }
    }

    /// A tab here shows herdr session `name` (its own session, or the default one when it names none).
    static func shownHere(_ name: String, default defaultName: String?, from tab: TerminalTab) -> Bool {
        AppDelegate.shared.controllers.flatMap { $0.tabs }.contains { (other: TerminalTab) -> Bool in
            guard other.followsHerdr else { return false }
            if let remote = other.remote {
                guard let mine = tab.remote, remote.host.id == mine.host.id else { return false }
                return (remote.herdrSession ?? defaultName) == name
            }
            return tab.remote == nil && (other.localHerdr?.session ?? defaultName) == name
        }
    }

    // MARK: machines (U11)

    static func machines(tab: TerminalTab) {
        guard tab.remote == nil else { return say("Machines are this Mac’s herdr’s", "herdr’s saved machines are managed from a herdr that runs on this Mac.", in: tab) }
        HerdrRunner.run(.machines, for: tab) { listed in
            MainActor.assumeIsolated {
                guard case .json(let json) = listed, let machines = HerdrMachines.parse(json), !machines.isEmpty else {
                    return say("herdr has no saved machines", "herdr machine add, in a terminal, saves one (herdr asks there).", in: tab)
                }
                let pick = popUp(machines.map { "\($0.label)\($0.enabled ? "" : " (disabled)")" })
                let alert = sheet("herdr machines", "Rename a saved machine, turn it on or off, or remove its profile (its remote sessions keep running).",
                                  accessory: pick, buttons: ["Rename…", "Enable or Disable", "Remove…", "Close"])
                present(alert, in: tab) { response in
                    let machine = machines[max(0, pick.indexOfSelectedItem)]
                    switch response {
                    case .alertFirstButtonReturn:
                        askText("Rename “\(machine.label)”", initial: machine.label, button: "Rename", in: tab) { label in
                            run(.renameMachine(id: machine.id, label: label), in: tab, failing: "Couldn’t rename it")
                        }
                    case .alertSecondButtonReturn:
                        confirm("\(machine.enabled ? "Disable" : "Enable") “\(machine.label)”?", "herdr \(machine.enabled ? "stops" : "starts") reaching it.",
                                button: machine.enabled ? "Disable" : "Enable", in: tab) {
                            run(.enableMachine(id: machine.id, enabled: !machine.enabled), in: tab, failing: "Couldn’t change it")
                        }
                    case .alertThirdButtonReturn:
                        confirm("Remove “\(machine.label)”?", "herdr forgets its profile; its remote sessions keep running.", button: "Remove", in: tab) {
                            run(.removeMachine(id: machine.id), in: tab, failing: "Couldn’t remove it")
                        }
                    default: break
                    }
                }
            }
        }
    }

    // MARK: integrations (U12)

    static func integrations(tab: TerminalTab) {
        HerdrRunner.run(.integrations, for: tab) { listed in
            MainActor.assumeIsolated {
                guard case .text(let text) = listed, case let found = HerdrIntegration.parse(text), !found.isEmpty else {
                    return say("herdr listed no integrations", HerdrMCP.problem(listed, pane: "", sent: false) ?? "herdr integration status gave none.", in: tab)
                }
                let pick = popUp(found.map { "\($0.kind) — \($0.state.rawValue)" })
                let alert = sheet("herdr integrations", "herdr follows an agent best through its own hook. Installing writes that agent’s hook config.",
                                  accessory: pick, buttons: ["Install…", "Uninstall…", "Close"])
                present(alert, in: tab) { response in
                    guard response != .alertThirdButtonReturn else { return }
                    let kind = found[max(0, pick.indexOfSelectedItem)].kind
                    let install: Bool = response == .alertFirstButtonReturn
                    confirm("\(install ? "Install" : "Uninstall") herdr’s \(kind) integration?", "herdr \(install ? "writes" : "removes") its hook in \(kind)’s config.",
                            button: install ? "Install" : "Uninstall", in: tab) {
                        run(.integration(kind: kind, install: install), in: tab, failing: "Couldn’t change it")
                    }
                }
            }
        }
    }

    // MARK: herdr itself (U13)

    static func status(tab: TerminalTab) {
        HerdrRunner.run(.version, for: tab) { version in
            HerdrRunner.run(.channel, for: tab) { channel in
                HerdrRunner.run(.configCheck, for: tab) { check in
                    MainActor.assumeIsolated {
                        func text(_ result: HerdrResult) -> String {
                            if case .text(let said) = result { return said.trimmingCharacters(in: .whitespacesAndNewlines) }
                            return HerdrMCP.problem(result, pane: "", sent: false) ?? "no answer"
                        }
                        let onPreview: Bool = text(channel) == "preview"
                        let body = "Version: \(text(version))\nChannel: \(text(channel))\nConfig: \(text(check))"
                        let local: Bool = tab.remote == nil
                        let alert = sheet("herdr", body, accessory: nil,
                                          buttons: ["Reload Config…", onPreview ? "Use Stable Channel…" : "Use Preview Channel…"] + (local ? ["Update herdr in a Tab", "Close"] : ["Close"]))
                        present(alert, in: tab) { response in
                            switch response {
                            case .alertFirstButtonReturn:
                                confirm("Reload herdr’s config?", "The running herdr server reads config.toml again.", button: "Reload", in: tab) {
                                    run(.reloadConfig, in: tab, failing: "Couldn’t reload it")
                                }
                            case .alertSecondButtonReturn:
                                confirm("Switch herdr to its \(onPreview ? "stable" : "preview") channel?", "herdr’s next update comes from that channel.",
                                        button: "Switch", in: tab) {
                                    run(.setChannel(preview: !onPreview), in: tab, failing: "Couldn’t switch it")
                                }
                            case .alertThirdButtonReturn where local:
                                updateInTab(from: tab)
                            default: break
                            }
                        }
                    }
                }
            }
        }
    }

    /// herdr's own update, in a new tab of the window, so the user sees and answers it; never run out of sight.
    static func updateInTab(from tab: TerminalTab) {
        guard let controller = MCPControl.controller(of: tab) else { return }
        let fresh = controller.addTab(directory: NSHomeDirectory(), select: true)
        fresh.userTitle = "herdr update"
        MCPControl.whenReady(fresh, until: TerminalTab.now + 3) {
            MCPControl.type("herdr update", into: fresh, submit: true)
        }
    }

    // MARK: sheets

    private static func popUp(_ titles: [String]) -> NSPopUpButton {
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        pick.addItems(withTitles: titles.map { SecretMask.current.mask($0) })
        return pick
    }

    private static func sheet(_ title: String, _ text: String, accessory: NSView?, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.accessoryView = accessory
        for button in buttons { alert.addButton(withTitle: button) }
        return alert
    }

    private static func confirm(_ title: String, _ text: String, button: String, in tab: TerminalTab, then: @escaping () -> Void) {
        let alert = sheet(title, text, accessory: nil, buttons: [button, "Cancel"])
        present(alert, in: tab) { response in if response == .alertFirstButtonReturn { then() } }
    }

    private static func askText(_ title: String, initial: String, button: String, in tab: TerminalTab, then: @escaping (String) -> Void) {
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = sheet(title, "", accessory: field, buttons: [button, "Cancel"])
        present(alert, in: tab) { response in
            if response == .alertFirstButtonReturn { then(field.stringValue.trimmingCharacters(in: .whitespaces)) }
        }
    }

    private static func run(_ command: HerdrCommand, in tab: TerminalTab, failing title: String) {
        if let refusal = command.refusal(session: nil) { return say(title, refusal, in: tab) }
        HerdrRunner.run(command, for: tab) { result in
            guard let problem = HerdrMCP.problem(result, pane: "", sent: false) else { return }
            MainActor.assumeIsolated { say(title, problem, in: tab) }
        }
    }

    private static func present(_ alert: NSAlert, in tab: TerminalTab, then: @escaping (NSApplication.ModalResponse) -> Void) {
        shown = alert
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if shown === alert { shown = nil }
            then(response)
        }
        if let window = tab.view.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    private static func say(_ title: String, _ text: String, in tab: TerminalTab) {
        present(sheet(title, text, accessory: nil, buttons: ["OK"]), in: tab) { _ in }
    }
}
