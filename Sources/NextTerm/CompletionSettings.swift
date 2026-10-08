import AppKit
import NextTermCore

/// Settings › Terminal › Tab completion: Auto, Next Term or Off, and a note on what each means. Its own row
/// (TerminalSettingsView's `row` is local to it), with the same 110 pt right-aligned label.
final class CompletionSettingsView: NSStackView {
    private let mode = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")

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
        note.preferredMaxLayoutWidth = 420
        let indented = NSStackView(views: [note])
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 120, bottom: 0, right: 0)
        addArrangedSubview(line)
        addArrangedSubview(indented)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    func refresh() {
        let current = CompletionPreferences.mode
        mode.selectItem(at: TabCompletionMode.allCases.firstIndex(of: current) ?? 0)
        note.stringValue = Self.note(current)
    }

    static func note(_ mode: TabCompletionMode) -> String {
        switch mode {
        case .auto:
            return "Tab at a zsh prompt opens Next Term’s list: zsh’s own completions when zsh has them, else folders and files. Where a plugin such as fzf-tab already owns Tab, Next Term asks once. Turning it on reaches new tabs."
        case .nextTerm:
            return "Tab at a zsh prompt always opens Next Term’s list, even where a plugin owns Tab. Turning it on reaches new tabs."
        case .off:
            return "Tab is the shell’s own, as in any terminal."
        }
    }

    @objc private func modeChanged() {
        guard let raw = mode.selectedItem?.representedObject as? String, let chosen = TabCompletionMode(rawValue: raw) else { return }
        CompletionPreferences.set(chosen)
        note.stringValue = Self.note(chosen)
    }
}

extension CompletionPreferences {
    /// Sets the mode for every window: lists open now close, and the tabs' tooltips say who answers Tab.
    static func set(_ chosen: TabCompletionMode) {
        mode = chosen
        for controller in AppDelegate.shared?.controllers ?? [] {
            controller.completions.closeShown()
            for tab in controller.tabs { tab.delegate?.tabDidChange(tab) }
        }
    }
}
