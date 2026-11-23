import AppKit
import NextTermCore

/// Settings › Secrets' "Agents look here first": what the next-term-secrets copy does, its state, and Remove, or Restore
/// once the user removed it. Next Term writes the copy itself (BuiltInSkillInstall), so there is nothing to add.
@MainActor
final class SecretsSkillSettingView: NSStackView {
    private(set) var restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private(set) var removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private(set) var stateLabel = NSTextField(wrappingLabelWithString: "")
    private let skill: BuiltInSkill = .secrets

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let heading = NSTextField(labelWithString: BuiltInSkillCopy.secretsTitle)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let help = SecretApprovalPanel.label(BuiltInSkillCopy.secretsHelp, size: 11)
        help.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        restoreButton.target = self
        restoreButton.action = #selector(restore)
        restoreButton.setAccessibilityLabel("Restore the next-term-secrets skill for your agents")
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.setAccessibilityLabel("Remove the next-term-secrets skill from your agents")
        let buttons = NSStackView(views: [restoreButton, removeButton])
        buttons.spacing = 8
        for view in [heading, help, stateLabel, buttons] { addArrangedSubview(view) }
        for view in [help, stateLabel] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: BuiltInSkillInstall.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func reload() {
        let state: BuiltInSkillCopy.State = BuiltInSkillInstall.state(skill)
        let declined: Bool = BuiltInSkillInstall.declined.contains(skill.name)
        let ours: Bool = state == .current || state == .stale
        // Which agents have it: the skills folder's, and Claude Code through its link or why not.
        stateLabel.stringValue = BuiltInSkillCopy.secretsSummary(state, declined: declined)
            + (ours ? " " + BuiltInSkillInstall.claudeNote(skill.name) : "")
        stateLabel.setAccessibilityLabel(nil)
        restoreButton.isHidden = !(state == .absent && declined)
        removeButton.isHidden = !ours
    }

    /// A refusal or failure: shown and said, as the other Secrets views say theirs, and the row read again first.
    private func problem(_ text: String) {
        reload()
        stateLabel.stringValue = text
        stateLabel.setAccessibilityLabel("Warning: " + text)
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// After Restore or Remove one button hides: the keyboard goes to the one shown.
    private func focusShownButton() {
        window?.makeFirstResponder(restoreButton.isHidden ? removeButton : restoreButton)
    }

    @objc private func restore() {
        if let text = BuiltInSkillInstall.restore(skill) { problem(text) } else { focusShownButton() }
    }

    @objc private func remove() {
        if let text = BuiltInSkillInstall.remove(skill) { problem(text) } else { focusShownButton() }
    }
}
