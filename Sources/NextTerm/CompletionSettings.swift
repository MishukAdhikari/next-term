import AppKit
import NextTermCore

/// Settings › Terminal › Tab completion: Auto, Next Term or Off, a note on what each means, and the choices
/// remembered where a plugin owns Tab, each with Ask Again. Its own row (TerminalSettingsView's `row` is local
/// to it), with the same 110 pt right-aligned label.
final class CompletionSettingsView: NSStackView {
    private let mode = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let choices = NSStackView()
    /// The servers where the user allowed the hook (RemoteCompletionConsent).
    private let servers = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let label = NSTextField(labelWithString: "Tab completion:")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        for item in TabCompletionMode.allCases {
            mode.addItem(withTitle: item.title)
            mode.lastItem?.representedObject = item.rawValue
        }
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Tab completion")
        let line = NSStackView(views: [label, mode])
        line.spacing = 10
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 330
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 2
        servers.textColor = .secondaryLabelColor
        servers.font = .systemFont(ofSize: 11)
        servers.preferredMaxLayoutWidth = 330
        let indented = NSStackView(views: [note, choices, servers])
        indented.orientation = .vertical
        indented.alignment = .leading
        indented.spacing = 4
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 120, bottom: 0, right: 0)
        addArrangedSubview(line)
        addArrangedSubview(indented)
        addArrangedSubview(CommandSuggestionSettingsView())
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: CompletionPreferences.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: RemoteCompletionConsent.changed, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc func refresh() {
        let current = CompletionPreferences.mode
        mode.selectItem(at: TabCompletionMode.allCases.firstIndex(of: current) ?? 0)
        note.stringValue = Self.note(current)
        choices.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in CompletionPreferences.remembered {
            let label = NSTextField(labelWithString: Self.choiceText(item.plugin, item.choice, byDismissal: item.byDismissal))
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let again = NSButton(title: "Ask Again", target: self, action: #selector(askAgain(_:)))
            again.controlSize = .small
            again.font = .systemFont(ofSize: 11)
            again.bezelStyle = .rounded
            again.identifier = NSUserInterfaceItemIdentifier(item.plugin.id)
            again.setAccessibilityLabel("Ask again about \(item.plugin.name)")
            let row = NSStackView(views: [label, again])
            row.spacing = 8
            choices.addArrangedSubview(row)
        }
        servers.stringValue = Self.serversText(RemoteCompletionConsent.allowedHosts.map(\.name))
        servers.isHidden = servers.stringValue.isEmpty
    }

    /// "The hook is on at web-1 and db-2: zsh’s own completions there. New Remote Tab… removes it."
    static func serversText(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "The hook is on at \(list): zsh’s own completions there. File › New Remote Tab… removes it."
    }

    static func note(_ mode: TabCompletionMode) -> String {
        switch mode {
        case .auto: return "Next Term’s list at a zsh prompt; where a plugin owns Tab, it asks once. New tabs get it."
        case .nextTerm: return "Next Term’s list at every zsh prompt, plugins or not. New tabs get it."
        case .off: return "Tab is the shell’s own, as in any terminal."
        }
    }

    static func choiceText(_ plugin: CompletionOwner.Plugin, _ choice: PluginChoice, byDismissal: Bool) -> String {
        switch choice {
        case .nextTerm: return "\(plugin.name): Next Term’s list answers Tab"
        case .plugin: return byDismissal ? "\(plugin.name) keeps Tab (the question was closed twice)" : "\(plugin.name) keeps Tab"
        }
    }

    @objc private func askAgain(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        CompletionPreferences.choose(nil, for: CompletionOwner.Plugin(id: id))
        CompletionSession.syncAll()
    }

    @objc private func modeChanged() {
        guard let raw = mode.selectedItem?.representedObject as? String, let chosen = TabCompletionMode(rawValue: raw) else { return }
        CompletionPreferences.set(chosen)
        note.stringValue = Self.note(chosen)
    }
}

extension CompletionPreferences {
    /// Sets the mode for every window: lists open now close, zsh-autocomplete follows, and the tabs' tooltips
    /// say who answers Tab.
    static func set(_ chosen: TabCompletionMode) {
        mode = chosen
        for controller in AppDelegate.shared?.controllers ?? [] { controller.completions.closeShown() }
        CompletionSession.syncAll()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Settings › Terminal › Suggest a command: Off (the default), an agent of the user's that Next Term can run with no
/// tools (CommandSuggestion.adapters, those found on the login shell's PATH), or Apple's on-device model on macOS 26.
/// Next Term has no AI of its own; this only says whose to ask, and only when the user asks.
final class CommandSuggestionSettingsView: NSStackView {
    private let choice = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let label = NSTextField(labelWithString: "Suggest a command:")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        label.lineBreakMode = .byTruncatingTail
        choice.target = self
        choice.action = #selector(chosen)
        choice.setAccessibilityLabel("Suggest a command")
        let line = NSStackView(views: [label, choice])
        line.spacing = 10
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 330
        let indented = NSStackView(views: [note])
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 120, bottom: 0, right: 0)
        addArrangedSubview(line)
        addArrangedSubview(indented)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: CompletionPreferences.changed, object: nil)
        refresh()
        // The agents are looked for on the login shell's PATH, read once per launch off the main thread.
        if !LoginShell.isProbed {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = LoginShell.programs
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The choices: Off, the agents found (all of them until the login shell's PATH is read), the on-device model.
    static var offered: [(id: String?, title: String)] {
        var items: [(id: String?, title: String)] = [(nil, "Off")]
        for adapter in CommandSuggestion.adapters where !LoginShell.isProbed || LoginShell.programs[adapter.program] != nil
            || CompletionPreferences.suggestion == adapter.id {
            items.append((adapter.id, adapter.name))
        }
        if OnDeviceSuggestion.isOffered || CompletionPreferences.suggestion == CompletionPreferences.onDevice {
            items.append((CompletionPreferences.onDevice, "Apple’s On-Device Model"))
        }
        return items
    }

    @objc func refresh() {
        choice.removeAllItems()
        let current = CompletionPreferences.suggestion
        for item in Self.offered {
            choice.addItem(withTitle: item.title)
            choice.lastItem?.representedObject = item.id
            if item.id == current { choice.select(choice.lastItem) }
        }
        note.stringValue = Self.note(current)
    }

    static func note(_ current: String?) -> String {
        guard let current else {
            return "Off: nothing is ever sent. On, File › Suggest a Command… turns a sentence into one command, put on the line and never run."
        }
        if current == CompletionPreferences.onDevice {
            let model = "Apple’s on-device model answers File › Suggest a Command…; nothing leaves this Mac. The command goes on the line and never runs."
            return OnDeviceSuggestion.unavailable.map { "\($0) " + model } ?? model
        }
        let name = CompletionPreferences.suggestionName(current)
        return "File › Suggest a Command… asks \(name) only when you submit: your words, the folder, the shell and the last command (secrets masked), and recent output only if you include it. It runs with no tools and no MCP, in an empty folder. The command goes on the line and never runs."
    }

    @objc private func chosen() {
        CompletionPreferences.suggestion = choice.selectedItem?.representedObject as? String
        note.stringValue = Self.note(CompletionPreferences.suggestion)
    }

    /// For the self-test.
    var titles: [String] { choice.itemTitles }
    var noteText: String { note.stringValue }
}

