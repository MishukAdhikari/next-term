import AppKit
import NextTermCore

// Import From › a password manager's sheet: its layout, and Open in a New Tab.

extension SecretManagerImportSheet {
    func build() {
        guard let view = window?.contentView else { return }
        let title = SecretApprovalPanel.label(preset.tabTitle, size: 14, weight: .semibold)
        let explanation = SecretApprovalPanel.label(Self.explanation(preset), size: 12)
        let shell: String = Self.newTabShell
        let line: String? = Self.line(preset, shell: shell)
        commandField.stringValue = line ?? Self.untypableLine(shell)
        commandField.font = line == nil ? .systemFont(ofSize: 12) : .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.isSelectable = line != nil
        commandField.setAccessibilityLabel("The line the new tab gets")
        commandField.preferredMaxLayoutWidth = 524
        var views: [NSView] = [title, explanation, commandField]
        if let note = Self.note(preset) { views.append(Self.small(note)) }
        downloadButton.title = "Get \(preset.program): \(Self.shown(preset.download))"
        downloadButton.bezelStyle = .inline
        downloadButton.target = self
        downloadButton.action = #selector(openDownload)
        downloadButton.setAccessibilityLabel("Open \(preset.program)\u{2019}s download page in the browser")
        views.append(downloadButton)
        let agentControl: Bool = SecretsView.agentControlIsOn()
        offLabel.stringValue = Self.agentControlOff
        offLabel.font = .systemFont(ofSize: 12)
        offLabel.textColor = .systemOrange
        offLabel.setAccessibilityLabel("Warning: " + Self.agentControlOff)
        offLabel.isHidden = agentControl
        views.append(offLabel)
        openButton.target = self
        openButton.action = #selector(openInNewTab)
        openButton.keyEquivalent = "\r"
        openButton.isHidden = !agentControl || line == nil
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = openButton.isHidden ? "\r" : "\u{1b}"
        for button in [openButton, cancelButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [NSView(), cancelButton, openButton])
        buttons.spacing = 8
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 560),
        ]
        let wide: [NSView] = [explanation, commandField, offLabel, buttons]
        for item in wide { constraints.append(item.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)) }
        NSLayoutConstraint.activate(constraints)
    }

    /// The shell a new tab starts, by its name: the account's login shell, as a tab picks it.
    static var newTabShell: String {
        var path: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let login: String = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: login) { path = login }
        }
        return (path as NSString).lastPathComponent
    }

    static func untypableLine(_ shell: String) -> String {
        "This line is written for zsh, bash or fish, and new tabs start \(shell). Run it from a zsh or bash tab."
    }

    /// A page as the button names it: its host and path, with no scheme.
    static func shown(_ url: URL) -> String {
        let text: String = (url.host ?? "") + url.path
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    static func small(_ text: String) -> NSTextField {
        let label = SecretApprovalPanel.label(text, size: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc func openDownload() {
        ServiceLinks.open(preset.download, from: window)
    }

    @objc func cancel() { finish() }

    /// A new tab in the home folder, in front, titled for the import; its line typed once its shell is at the prompt,
    /// with no Return, and the list says so only then. From now on agents can't act on that tab.
    /// zsh says when it reaches its prompt (Next Term's integration): its line waits for that, up to `promptWait`, and
    /// is never typed into a shell still starting, where a prompt of the user's own startup files could take it. Other
    /// shells say nothing, so theirs is typed after 5 s, as new_tab types a command.
    @objc func openInNewTab() {
        guard SecretsView.agentControlIsOn() else { return }
        let home: String = NSHomeDirectory()
        let window: TerminalWindowController? = Self.homeWindow(home) ?? Self.frontWindow()
        let controller: TerminalWindowController = window ?? MCPControl.window(for: home).controller
        let tab: TerminalTab = controller.addTab(directory: home, select: true)
        tab.userTitle = preset.tabTitle
        Self.register(tab, preset: preset)
        opened?(tab)
        controller.refresh()
        controller.window?.makeKeyAndOrderFront(nil)
        let preset: SecretImportPreset = self.preset
        let say: (String) -> Void = self.say
        let reports: Bool = Self.newTabShell == "zsh" && AppSupport.zshIntegrationDirectory != nil
        let wait: TimeInterval = reports ? Self.promptWait : 5
        MCPControl.whenReady(tab, until: TerminalTab.now + wait) {
            if reports, !tab.status.integrated { return say(Self.notAtPrompt) }
            let shell: String = SecretsMCP.shellName(of: tab)
            guard let line = Self.line(preset, shell: shell) else { return say(Self.untypableLine(shell)) }
            guard MCPControl.canType(tab) else { return say(Self.notTyped) }
            MCPControl.type(line, into: tab, submit: false)
            say(Self.typedLine)
        }
        finish()
    }

    /// The longest zsh's first prompt is waited for.
    static let promptWait: TimeInterval = 20
    static let notAtPrompt = "The new tab\u{2019}s shell didn\u{2019}t reach its prompt, so Next Term didn\u{2019}t type "
        + "the line. Open the import again once it has."

    /// The window whose project holds the home folder, as new_tab picks one; else nil, and the window in front takes
    /// the tab, so no project window opens on the whole home folder (joining Recent projects) for one tab.
    static func homeWindow(_ home: String) -> TerminalWindowController? {
        let owners: [TerminalWindowController] = AppDelegate.shared.controllers.filter {
            (controller: TerminalWindowController) -> Bool in
            guard !controller.hasClosed, let project = controller.project else { return false }
            return home == project || home.hasPrefix(project + "/")
        }
        return owners.max { (first: TerminalWindowController, second: TerminalWindowController) -> Bool in
            (first.project?.count ?? 0) < (second.project?.count ?? 0)
        }
    }

    /// The terminal window in front, as the user last saw it.
    static func frontWindow() -> TerminalWindowController? {
        let ordered: [TerminalWindowController] = NSApp.orderedWindows.compactMap { (window: NSWindow) -> TerminalWindowController? in
            window.windowController as? TerminalWindowController
        }
        return ordered.first { (controller: TerminalWindowController) -> Bool in !controller.hasClosed }
    }

    private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        done()
    }
}
