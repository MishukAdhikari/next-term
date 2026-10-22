import AppKit
import NextTermCore

// Connect a Tracker's buttons: Copy, Open in a New Tab, a page link, and which agents are on this Mac.

extension ConnectTrackerSheet {
    /// The agent a row's button belongs to.
    private func agent(of sender: Any?) -> AgentKind? {
        guard let raw = (sender as? NSView)?.identifier?.rawValue else { return nil }
        return AgentKind(rawValue: raw)
    }

    /// The line the chosen tracker gives `agent`, or nil when the pair is held.
    func line(for agent: AgentKind) -> String? {
        if case .line(let text, _) = tracker.cell(for: agent) { return text }
        return nil
    }

    @objc func copyLine(_ sender: Any?) {
        guard let agent = agent(of: sender), let line = line(for: agent) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        say("Copied \(agent.name)\u{2019}s line for \(tracker.name).")
    }

    @objc func openPage(_ sender: Any?) {
        guard let raw = (sender as? NSView)?.identifier?.rawValue, let page = URL(string: raw) else { return NSSound.beep() }
        TaskOpen.openPage(page, from: window)
    }

    /// A new tab in the home folder, in front, titled for the tracker and the agent; the line typed once its shell is at
    /// the prompt, with no Return. zsh says when it reaches its prompt, so the line waits for that, up to 20 s, and is
    /// never typed into a shell still starting; other shells say nothing, so theirs is typed after 5 s. The sheet stays
    /// open for the next agent.
    @objc func openInNewTab(_ sender: Any?) {
        guard let agent = agent(of: sender), let line = line(for: agent), found?.contains(agent) == true else {
            return NSSound.beep()
        }
        let home: String = NSHomeDirectory()
        let front: TerminalWindowController? = SecretManagerImportSheet.homeWindow(home) ?? SecretManagerImportSheet.frontWindow()
        let controller: TerminalWindowController = front ?? MCPControl.window(for: home).controller
        let tab: TerminalTab = controller.addTab(directory: home, select: true)
        tab.userTitle = "Connect \(tracker.name) to \(agent.name)"
        Self.register(tab)
        controller.refresh()
        if window?.sheetParent !== controller.window { controller.window?.makeKeyAndOrderFront(nil) }
        let reports: Bool = SecretManagerImportSheet.newTabShell == "zsh" && AppSupport.zshIntegrationDirectory != nil
        let wait: TimeInterval = reports ? SecretManagerImportSheet.promptWait : 5
        say("")
        MCPControl.whenReady(tab, until: TerminalTab.now + wait) { [weak self] in
            let said: String
            if reports, !tab.status.integrated {
                said = Self.notAtPrompt
            } else if !MCPControl.canType(tab) {
                said = Self.notTyped
            } else {
                MCPControl.type(line, into: tab, submit: false)
                said = Self.typedLine
            }
            self?.say(said)
        }
    }

    /// Which listed agents' programs are on the login shell's PATH: a look for the file in each folder, off the main
    /// thread, running nothing. Folders in a protected place are skipped, so the look never sets off macOS's prompt.
    func lookForAgents() {
        #if DEBUG
        let fake: [String]? = Self.fakePath
        #else
        let fake: [String]? = nil
        #endif
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folders: [String] = fake ?? Self.searchPath()
            let joined: String = folders.joined(separator: ":")
            var found: Set<AgentKind> = []
            for agent in TrackerLines.agents {
                guard let program = TrackerLines.program(agent) else { continue }
                if case .found = SecretWrapper.resolve(program, path: joined) { found.insert(agent) }
            }
            let result: Set<AgentKind> = found
            DispatchQueue.main.async {
                guard let self else { return }
                self.found = result
                self.fillRows()
            }
        }
    }

    /// The login shell's PATH, without folders in protected places.
    nonisolated static func searchPath() -> [String] {
        let protected = ProtectedPlaces.current
        return LoginShell.path.filter { (folder: String) -> Bool in !protected.holds(folder) }
    }

    #if DEBUG
    /// The self-test sets the folders to look in, so a row's answer doesn't depend on this Mac; nil: the login PATH.
    nonisolated(unsafe) static var fakePath: [String]?
    #endif
}
