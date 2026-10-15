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
        let agentControl: Bool = AppDelegate.shared.agentControl
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
    /// with no Return. From then on agents can't act on that tab.
    @objc func openInNewTab() {
        guard AppDelegate.shared.agentControl else { return }
        let home: String = NSHomeDirectory()
        let controller: TerminalWindowController = Self.frontWindow() ?? MCPControl.window(for: home).controller
        let tab: TerminalTab = controller.addTab(directory: home, select: true)
        tab.userTitle = preset.tabTitle
        Self.register(tab, preset: preset)
        controller.refresh()
        controller.window?.makeKeyAndOrderFront(nil)
        let preset: SecretImportPreset = self.preset
        let say: (String) -> Void = self.say
        MCPControl.whenReady(tab, until: TerminalTab.now + 5) {
            let shell: String = SecretsMCP.shellName(of: tab)
            guard let line = Self.line(preset, shell: shell) else { return say(Self.untypableLine(shell)) }
            guard MCPControl.canType(tab) else { return say(Self.notTyped) }
            MCPControl.type(line, into: tab, submit: false)
        }
        say(Self.typedLine)
        finish()
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
