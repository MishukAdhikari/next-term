import AppKit
import NextTermCore

/// Settings › General: what a launch that names no folder or file shows, whether a quit with a terminal window open asks
/// about resuming, whether a restore brings scrollback back, whether windows show their project's colour, and Full Disk
/// Access… for the user who wants it. Each control saves only its own choice, as it changes, and it is read at the next
/// launch, reopen or quit (LaunchSettings): "At launch" counts as chosen only once the user chose it. The project colours
/// show or hide at once, as View › Project Color › Show Project Colors does.
final class GeneralSettingsView: NSView {
    /// A radio button for each choice, in LaunchOpens' order, beside "At launch:".
    let opens: [NSButton] = LaunchOpens.allCases.map { NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil) }
    /// The radio buttons, which VoiceOver reads as one group named as its visible label, "At launch".
    let opensGroup = NSStackView()
    /// Beside "At quit:".
    let askToResume = NSButton(checkboxWithTitle: "Ask whether to resume when quitting", target: nil, action: nil)
    /// Beside "Sessions:".
    let keepScrollback = NSButton(checkboxWithTitle: "Keep scrollback", target: nil, action: nil)
    /// Beside "Windows:": Show Project Colors.
    let projectColors = NSButton(checkboxWithTitle: "Show project colors", target: nil, action: nil)
    /// Beside "Privacy:": System Settings' Full Disk Access pane, opened when clicked. Nothing asks for it by itself.
    let fullDiskAccess = NSButton(title: "Full Disk Access…", target: nil, action: nil)
    /// The labels in the 110 pt column on the left, as in the other tabs.
    let launchLabel = NSTextField(labelWithString: "At launch:")
    let quitLabel = NSTextField(labelWithString: "At quit:")
    let sessionsLabel = NSTextField(labelWithString: "Sessions:")
    let windowsLabel = NSTextField(labelWithString: "Windows:")
    let privacyLabel = NSTextField(labelWithString: "Privacy:")
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
        opensGroup.setAccessibilityLabel("At launch")
        askToResume.target = self
        askToResume.action = #selector(askToResumeChanged)
        keepScrollback.target = self
        keepScrollback.action = #selector(keepScrollbackChanged)
        projectColors.target = self
        projectColors.action = #selector(projectColorsChanged)
        fullDiskAccess.bezelStyle = .rounded
        fullDiskAccess.target = self
        fullDiskAccess.action = #selector(openFullDiskAccess)

        // No wider than the widest control above them, which the column never gets narrower than: a note squeezed in a
        // narrow window would wrap to a line its height leaves out.
        let noteWidth: CGFloat = (opens + [askToResume, keepScrollback, projectColors]).map(\.fittingSize.width).max() ?? 290
        func note(_ text: String) -> NSTextField {
            let note = NSTextField(wrappingLabelWithString: text)
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            note.preferredMaxLayoutWidth = noteWidth
            return note
        }
        let opensNote = note("Brings back windows, tabs, splits, scrollback and agents. Resume is the default; with nothing to bring back, as at the first launch, the Welcome window shows. Agents resume by themselves only after a quit with “Reopen windows and resume sessions” checked; otherwise each agent’s resume command waits on the line. A folder or file named at launch opens too. With every window closed, a click on the Dock icon opens the most recent project under Resume, shows the Welcome window under “Show the Welcome window”, and opens a shell window under “Open a new terminal”.")
        let askNote = note("Asks only when a terminal window is open. Unsaved files and running work are always asked about.")
        let scrollbackNote = note("Brings shell output back when windows resume after a quit or an update. It is kept in private files, with secrets masked on a best-effort basis, until Next Term next opens.")
        let colorsNote = note("A soft glow of each project’s colour along the top of its window, behind the window’s buttons. A worktree’s window has its repository’s. Choose another in View › Project Color, or right-click the window’s top row.")
        let privacyNote = note("Only if you want Next Term and the commands in it to reach every folder without macOS asking: this opens System Settings, where you add Next Term yourself.")
        // VoiceOver reads each note with the controls it is about.
        for radio in opens { radio.setAccessibilityHelp(opensNote.stringValue) }
        askToResume.setAccessibilityHelp(askNote.stringValue)
        keepScrollback.setAccessibilityHelp(scrollbackNote.stringValue)
        projectColors.setAccessibilityHelp(colorsNote.stringValue)
        fullDiskAccess.setAccessibilityHelp(privacyNote.stringValue)
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
        // The radio group has the label's words for its name, "At launch": VoiceOver reads them once, with the group.
        launchLabel.setAccessibilityElement(false)
        // The notes' rows start with an empty label, for the column: nothing for VoiceOver to read.
        func blank() -> NSTextField {
            let label = NSTextField(labelWithString: "")
            label.setAccessibilityElement(false)
            return label
        }
        let launchRow = row(launchLabel, [opensGroup])
        let opensNoteRow = row(blank(), [opensNote])
        let quitRow = row(quitLabel, [askToResume])
        let askNoteRow = row(blank(), [askNote])
        let sessionsRow = row(sessionsLabel, [keepScrollback])
        let scrollbackNoteRow = row(blank(), [scrollbackNote])
        let windowsRow = row(windowsLabel, [projectColors])
        let colorsNoteRow = row(blank(), [colorsNote])
        let privacyRow = row(privacyLabel, [fullDiskAccess])
        let rows: [NSView] = [launchRow, opensNoteRow, quitRow, askNoteRow, sessionsRow, scrollbackNoteRow, windowsRow, colorsNoteRow,
                              privacyRow, row(blank(), [privacyNote])]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: opensNoteRow)
        stack.setCustomSpacing(20, after: askNoteRow)
        stack.setCustomSpacing(20, after: scrollbackNoteRow)
        stack.setCustomSpacing(20, after: colorsNoteRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        refresh()
        // An import or its Undo can change what reopens at launch, and so can the Welcome window's At launch pop-up.
        NotificationCenter.default.addObserver(self, selector: #selector(importChanged), name: ImportCoordinator.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(importChanged), name: LaunchSettings.changed, object: nil)
        // Show Project Colors from the View menu, while this shows.
        NotificationCenter.default.addObserver(self, selector: #selector(importChanged), name: ProjectColorStore.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func importChanged() { refresh() }

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
        askToResume.state = settings.askToReopenOnQuit ? .on : .off
        keepScrollback.state = settings.keepScrollback ? .on : .off
        projectColors.state = ProjectColorStore.isShown ? .on : .off
    }

    @objc private func opensChanged(_ sender: NSButton) {
        let choices = LaunchOpens.allCases
        guard choices.indices.contains(sender.tag) else { return }
        var settings = LaunchSettings(defaults: defaults)
        settings.opens = choices[sender.tag]
        settings.save(.opens, to: defaults)
        for radio in opens { radio.state = radio === sender ? .on : .off }
        NotificationCenter.default.post(name: LaunchSettings.changed, object: self)
    }

    @objc private func askToResumeChanged() {
        var settings = LaunchSettings(defaults: defaults)
        settings.askToReopenOnQuit = askToResume.state == .on
        settings.save(.askToReopenOnQuit, to: defaults)
    }

    /// Full Disk Access…: System Settings' pane, for the user to add Next Term there if they want to.
    @objc private func openFullDiskAccess() {
        NSWorkspace.shared.open(PrivacySettings.url(.fullDiskAccess))
    }

    /// Every window's project colour, shown or hidden at once.
    @objc private func projectColorsChanged() {
        ProjectColorStore.isShown = projectColors.state == .on
    }

    @objc private func keepScrollbackChanged() {
        var settings = LaunchSettings(defaults: defaults)
        settings.keepScrollback = keepScrollback.state == .on
        settings.save(.keepScrollback, to: defaults)
    }
}

extension LaunchSettings {
    /// "At launch" was chosen here or in the Welcome window's footer: the other shows it at once.
    static let changed = Notification.Name("NextTermLaunchSettingsChanged")
}
