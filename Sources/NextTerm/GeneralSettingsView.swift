import AppKit
import NextTermCore

/// Settings › General: what a launch that names no folder or file shows, and whether a quit with project windows
/// open asks about reopening them. Each choice is saved as it changes and read at the next launch, reopen or quit
/// (LaunchSettings).
final class GeneralSettingsView: NSView {
    /// "When Next Term opens:", a radio button for each choice, in LaunchOpens' order.
    let opens: [NSButton] = LaunchOpens.allCases.map { NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil) }
    /// The radio buttons, which VoiceOver reads as one group.
    let opensGroup = NSStackView()
    let askToReopen = NSButton(checkboxWithTitle: "Ask whether to reopen projects when quitting", target: nil, action: nil)
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
        let column = NSStackView(views: [opensGroup, opensNote, askToReopen, askNote])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(24, after: opensNote)
        let label = NSTextField(labelWithString: "When Next Term opens:")
        label.alignment = .right
        // The radio group already has this name: VoiceOver reads it once.
        label.setAccessibilityElement(false)
        let stack = NSStackView(views: [label, column])
        stack.alignment = .firstBaseline
        stack.spacing = 10
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
