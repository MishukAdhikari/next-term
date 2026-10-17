import AppKit
import NextTermCore

/// Settings › Terminal › While typing (suggestions while typing): On (the default) or Off, a note on what Next Term keeps
/// and what it never does, how many commands are kept with Clear History…, the choices remembered where a plugin draws its
/// own suggestions, each with Ask Again, and a line when the history folder can't be used. Between Tab completion's rows
/// and Suggest a Command's, with the same 110 pt right-aligned label.
final class GhostSettingsView: NSStackView {
    private let onOff = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let kept = NSTextField(labelWithString: "")
    private let clear = NSButton(title: "Clear History…", target: nil, action: nil)
    private let choices = NSStackView()
    private let problem = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let label = NSTextField(labelWithString: "While typing:")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        onOff.addItems(withTitles: ["On", "Off"])
        onOff.target = self
        onOff.action = #selector(onOffChanged)
        onOff.setAccessibilityLabel("Suggestions while typing")
        let line = NSStackView(views: [label, onOff])
        line.spacing = 10
        for field in [note, problem] {
            field.textColor = .secondaryLabelColor
            field.font = .systemFont(ofSize: 11)
            field.preferredMaxLayoutWidth = 330
        }
        kept.font = .systemFont(ofSize: 11)
        clear.target = self
        clear.action = #selector(clearHistory)
        clear.controlSize = .small
        clear.font = .systemFont(ofSize: 11)
        clear.bezelStyle = .rounded
        let keptRow = NSStackView(views: [kept, clear])
        keptRow.spacing = 8
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 2
        let indented = NSStackView(views: [note, keptRow, choices, problem])
        indented.orientation = .vertical
        indented.alignment = .leading
        indented.spacing = 4
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 120, bottom: 0, right: 0)
        addArrangedSubview(line)
        addArrangedSubview(indented)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: GhostPreferences.changed, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc func refresh() {
        let on = GhostPreferences.isOn
        onOff.selectItem(at: on ? 0 : 1)
        note.stringValue = Self.note(on: on)
        choices.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in GhostPreferences.remembered {
            let label = NSTextField(labelWithString: Self.choiceText(item.plugin, item.choice, byDismissal: item.byDismissal))
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
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
        let trouble = CommandHistoryStore.shared.problem
        problem.stringValue = trouble.map { "Next Term can’t use its history folder this time: \($0)" } ?? ""
        problem.isHidden = trouble == nil
        // The count comes from the record's own queue (reading it, the first time).
        CommandHistoryStore.shared.count { [weak self] count in self?.showCount(count) }
    }

    private func showCount(_ count: Int) {
        keptCount = count
        kept.stringValue = Self.keptText(count)
        clear.isEnabled = count > 0
    }

    /// The count shown, for the self-test.
    private(set) var keptCount: Int?

    static func note(on: Bool) -> String {
        guard on else {
            return "Off: nothing shows after the cursor, and no command is recorded. What is kept stays until you clear it."
        }
        return "Next Term suggests a command you ran before, dimmed after the cursor: → or End takes it, ⌥→ one word, Esc hides it,"
            + " and Return runs only what you typed. It keeps the commands you run in its zsh tabs, on this Mac only: never agents’"
            + " commands, lines that hold a secret or start with a space, or anything while View › Private Mode is on. It never reads"
            + " or changes zsh’s history file; until it has your commands, zsh’s own history in each shell fills in."
    }

    static func keptText(_ count: Int) -> String {
        switch count {
        case 0: return "No commands kept yet."
        case 1: return "1 command kept."
        default: return "\(count.formatted()) commands kept."
        }
    }

    static func choiceText(_ plugin: GhostOwner.Plugin, _ choice: PluginChoice, byDismissal: Bool) -> String {
        switch choice {
        case .nextTerm: return "\(plugin.name): Next Term’s show instead"
        case .plugin: return byDismissal ? "\(plugin.name) keeps them (the question was closed twice)" : "\(plugin.name) keeps them"
        }
    }

    @objc private func onOffChanged() {
        GhostPreferences.set(onOff.indexOfSelectedItem == 0)
    }

    @objc private func askAgain(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let plugin = GhostOwner.Plugin(id: id) else { return }
        GhostPreferences.choose(nil, for: plugin)
        GhostSession.syncAll()
    }

    /// The alert for Clear History…, for the self-test.
    private(set) var clearAlert: NSAlert?

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Next Term’s command history?"
        alert.informativeText = "Suggestions start over. zsh’s own history isn’t touched."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        clearAlert = alert
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.clearAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            self?.clearNow()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// Clears the record and its log, then says how many are kept (none).
    func clearNow() {
        CommandHistoryStore.shared.clear { [weak self] in self?.refresh() }
    }
}
