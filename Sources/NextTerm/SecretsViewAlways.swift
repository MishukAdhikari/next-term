import AppKit
import NextTermCore

/// Settings › Secrets' Always approvals: under each key's name, each grant that holds it ("Always: Codex · curl -sS … ·
/// in app", and when it was last used), with Remove. Removing asks for Touch ID, which raises the vault's floor so the
/// grant never comes back. Read from the file as it is (SecretAlways.listed): nothing shown here answers a request.
extension SecretsView {
    func reloadAlways() {
        for view in alwaysBox.arrangedSubviews { view.removeFromSuperview() }
        let grants = SecretAlways.listed()
        alwaysBox.isHidden = grants.isEmpty
        guard !grants.isEmpty else { return }
        alwaysBox.addArrangedSubview(Self.heading("Always"))
        for name in Set(grants.flatMap(\.names)).sorted() {
            let key = NSTextField(labelWithString: name)
            key.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            alwaysBox.addArrangedSubview(key)
            for grant in grants where grant.keys[name] != nil {
                let remove = NSButton(title: "Remove", target: self, action: #selector(removeAlways(_:)))
                remove.bezelStyle = .rounded
                remove.controlSize = .small
                remove.identifier = NSUserInterfaceItemIdentifier(grant.id)
                remove.setAccessibilityLabel("Remove \(Self.alwaysText(grant))")
                let text = SecretApprovalPanel.label(Self.alwaysText(grant), size: 12)
                text.toolTip = grant.scope.path
                let used = SecretApprovalPanel.label(Self.alwaysUsed(grant), size: 11)
                used.textColor = .secondaryLabelColor
                let lines = NSStackView(views: [text, used])
                lines.orientation = .vertical
                lines.alignment = .leading
                lines.spacing = 2
                // The text takes the row up to Remove, which keeps to the right edge.
                for view in [lines, text, used] { view.setContentHuggingPriority(.defaultLow, for: .horizontal) }
                remove.setContentHuggingPriority(.required, for: .horizontal)
                text.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
                let row = NSStackView(views: [lines, remove])
                row.distribution = .fill
                row.spacing = 8
                row.alignment = .top
                row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
                alwaysBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: alwaysBox.widthAnchor).isActive = true
            }
        }
        let help = SecretApprovalPanel.label(Self.alwaysHelp, size: 11)
        help.textColor = .secondaryLabelColor
        alwaysBox.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: alwaysBox.widthAnchor).isActive = true
    }

    static let alwaysHelp = "Each asks for Touch ID once each time Next Term opens, then no more. Changing, renaming or deleting a key "
        + "removes its Always approvals, and so does setting it to ask for Touch ID every time."

    /// "Always: Codex · curl -sS https://api.example.com · in app and its worktrees" (the full path is the row's tooltip).
    static func alwaysText(_ grant: SecretAlwaysGrant) -> String {
        let place: String
        switch grant.scope.kind {
        case .project: place = "in \((grant.scope.path as NSString).lastPathComponent) and its worktrees"
        case .worktree: place = "in \((grant.scope.path as NSString).lastPathComponent)"
        case .folder: place = "in \((grant.scope.path as NSString).lastPathComponent) alone"
        }
        let what = SecretApprovalPanel.sanitized(grant.summary, limit: 160)
        return "Always: \(SecretApprovalPanel.sanitized(grant.agent, limit: 60)) \u{00B7} \(what) \u{00B7} \(place)"
    }

    /// "Last used 2 days ago", or "Never used".
    static func alwaysUsed(_ grant: SecretAlwaysGrant) -> String {
        guard let used = grant.lastUsed else { return "Never used" }
        guard abs(used.timeIntervalSinceNow) >= 60 else { return "Last used just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last used " + formatter.localizedString(for: used, relativeTo: Date())
    }

    @objc func removeAlways(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor in
            do {
                try await SecretAlways.remove(id)
            } catch {
                sender.isEnabled = true
            }
            reloadAlways()
        }
    }
}
