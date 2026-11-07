import AppKit
import NextTermCore

/// Agents › New Agent Session… and `new_tab`'s `agent_session` (plan 030): a tab that runs `nxtrm agent ID`, an agent
/// over ACP whose turns, tool calls and permission requests Next Term follows exactly (AgentSessionCLI).
enum ACPSessionTabs {
    /// The agents that speak ACP themselves whose program is on the login shell's PATH.
    static var installed: [ACPAgent] {
        ACPAgent.installed(path: LoginShell.path.joined(separator: ":")) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// How a tab's shell starts `nxtrm`: by its name when the PATH's `nxtrm` is this app's, else the bundle's script by
    /// its path, else (a build run from its folder) this binary with `--cli`.
    static var launcher: String {
        let bundle = (Bundle.main.bundlePath as NSString).resolvingSymlinksInPath
        if let found = AgentSessionCLI.locate("nxtrm", path: LoginShell.path.joined(separator: ":")),
           (found as NSString).resolvingSymlinksInPath.hasPrefix(bundle + "/") {
            return "nxtrm"
        }
        if let resources = Bundle.main.resourcePath {
            let script = (resources as NSString).appendingPathComponent("bin/nxtrm")
            if FileManager.default.isExecutableFile(atPath: script) { return ShellQuote.quote(script) }
        }
        return ShellQuote.quote(Bundle.main.executablePath ?? "nxtrm") + " --cli"
    }

    /// `new_tab`'s check of an `agent_session` name: the agent, or the refusal naming the ones that would run.
    static func agent(named name: String) -> Result<ACPAgent, MCPRefusal> {
        let here = installed
        guard let agent = ACPAgent.named(name) else {
            return .failure(MCPRefusal("\(name) isn't an agent Next Term runs as a session. Installed here: \(ACPAgent.listed(here))."))
        }
        guard here.contains(agent) else {
            return .failure(MCPRefusal("\(agent.name) (\(agent.program)) isn't on the PATH. Installed here: \(ACPAgent.listed(here))."))
        }
        return .success(agent)
    }
}

/// A refusal's words, for MCP.
struct MCPRefusal: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

extension TerminalWindowController {
    /// Agents › New Agent Session…: which agent, the first prompt, and Start, in the window's project.
    @objc func newAgentSession(_ sender: Any?) {
        let agents = ACPSessionTabs.installed
        let alert = NSAlert()
        alert.messageText = "New Agent Session"
        let folder = project ?? searchRoot
        guard !agents.isEmpty else {
            alert.informativeText = "None of the agents that speak the Agent Client Protocol is installed here: "
                + ACPAgent.known.prefix(6).map(\.name).joined(separator: ", ") + " and others. Install one, then try again."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        alert.informativeText = "Runs the agent in a tab, in \((folder as NSString).abbreviatingWithTildeInPath). Next Term follows "
            + "its turns, tool calls and permission requests exactly, and agents in other tabs can steer it."
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: agents.map(\.name))
        picker.setAccessibilityLabel("Agent")
        let prompt = NSTextField(string: "")
        prompt.placeholderString = "First prompt (optional)"
        prompt.setAccessibilityLabel("First prompt")
        let stack = NSStackView(views: [picker, prompt])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        prompt.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        DialogFit.fitAccessory(stack, width: 320, in: alert)
        alert.window.initialFirstResponder = prompt
        let start: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let agent = agents[max(picker.indexOfSelectedItem, 0)]
            let line = agent.sessionLine(launcher: ACPSessionTabs.launcher, prompt: prompt.stringValue)
            self.runInNewTab(directory: folder, command: line, title: agent.name)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: start) } else { start(alert.runModal()) }
    }
}
