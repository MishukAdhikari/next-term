import AppKit
import NextTermCore

/// Settings › General: what a launch that names no folder or file shows, and whether a quit with project windows
/// open asks about reopening them. Each choice is saved as it changes and read at the next launch, reopen or quit
/// (LaunchSettings).
final class GeneralSettingsView: NSView {
    /// A radio button for each choice, in LaunchOpens' order, beside "At launch:".
    let opens: [NSButton] = LaunchOpens.allCases.map { NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil) }
    /// The radio buttons, which VoiceOver reads as one group, "When Next Term opens".
    let opensGroup = NSStackView()
    /// Beside "At quit:".
    let askToReopen = NSButton(checkboxWithTitle: "Ask whether to reopen projects when quitting", target: nil, action: nil)
    /// The labels in the 110 pt column on the left, as in the other tabs.
    let launchLabel = NSTextField(labelWithString: "At launch:")
    let quitLabel = NSTextField(labelWithString: "At quit:")
    /// Where the choices are kept: the defaults the launch and the quit read them from.
    private let defaults: UserDefaults = AppDelegate.shared?.launchDefaults ?? .standard

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (index, radio) in opens.enumerated() {
            radio.tag = index
            radio.target = self
            radio.action = #selector(opensChanged(_:))
            opensGroup.addArrangedSubview(radio)
        }
        opensGroup.orientation = .vertical
        opensGroup.alignment = .leading
        opensGroup.spacing = 6
        opensGroup.setAccessibilityElement(true)
        opensGroup.setAccessibilityRole(.radioGroup)
        opensGroup.setAccessibilityLabel("When Next Term opens")
        askToReopen.target = self
        askToReopen.action = #selector(askToReopenChanged)

        // No wider than the widest control above them, which the column never gets narrower than: a note squeezed in a
        // narrow window would wrap to a line its height leaves out.
        let noteWidth: CGFloat = (opens + [askToReopen]).map(\.fittingSize.width).max() ?? 290
        func note(_ text: String) -> NSTextField {
            let note = NSTextField(wrappingLabelWithString: text)
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            note.preferredMaxLayoutWidth = noteWidth
            return note
        }
        let opensNote = note("A folder or file named at launch, from nxtrm or a drop on the Dock icon, always opens directly. With every window closed, a click on the Dock icon shows the Welcome window or, with Reopen chosen, opens only the most recent project.")
        let askNote = note("Asks only when project windows are open. Unsaved files and running work are always asked about.")
        // VoiceOver reads each note with the controls it is about.
        for radio in opens { radio.setAccessibilityHelp(opensNote.stringValue) }
        askToReopen.setAccessibilityHelp(askNote.stringValue)
        // A label in the 110 pt column on the left, as in the other tabs, and its controls beside it: on the first line's
        // baseline, for the radio buttons' two lines.
        func row(_ label: NSTextField, _ views: [NSView]) -> NSStackView {
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.alignment = .firstBaseline
            stack.spacing = 10
            return stack
        }
        // The radio group already has its name, "When Next Term opens": VoiceOver reads it, not this label.
        launchLabel.setAccessibilityElement(false)
        let launchRow = row(launchLabel, [opensGroup])
        let opensNoteRow = row(NSTextField(labelWithString: ""), [opensNote])
        let quitRow = row(quitLabel, [askToReopen])
        let stack = NSStackView(views: [launchRow, opensNoteRow, quitRow, row(NSTextField(labelWithString: ""), [askNote])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: opensNoteRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    /// The radio button for a choice.
    func radio(_ choice: LaunchOpens) -> NSButton {
        opens[LaunchOpens.allCases.firstIndex(of: choice) ?? 0]
    }

    func refresh() {
        let settings = LaunchSettings(defaults: defaults)
        for choice in LaunchOpens.allCases {
            radio(choice).state = choice == settings.opens ? .on : .off
        }
        askToReopen.state = settings.askToReopenOnQuit ? .on : .off
    }

    @objc private func opensChanged(_ sender: NSButton) {
        let choices = LaunchOpens.allCases
        guard choices.indices.contains(sender.tag) else { return }
        var settings = LaunchSettings(defaults: defaults)
        settings.opens = choices[sender.tag]
        settings.save(to: defaults)
        for radio in opens { radio.state = radio === sender ? .on : .off }
    }

    @objc private func askToReopenChanged() {
        var settings = LaunchSettings(defaults: defaults)
        settings.askToReopenOnQuit = askToReopen.state == .on
        settings.save(to: defaults)
    }
}
