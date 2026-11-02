import AppKit
import NextTermCore

/// The next-term-secrets copy on disk (SecretsSkillCopy has the rules): Add writes ~/.agents/skills/next-term-secrets
/// and Claude Code's link, Remove sends both to the Trash, and each launch brings Next Term's own copy up to date. A copy
/// or link that is not Next Term's own is never written over or removed.
@MainActor
enum SecretsSkillInstall {
    /// The home the copy goes in; the self-test sets a scratch one, so it never touches the user's own folders.
    static var home: String = NSHomeDirectory()
    /// The hash of the text Next Term last wrote, beside Secrets' other settings (never a key's name or value).
    static let writtenKey = "secretsSkillCopyHash"
    static let changed = Notification.Name("NextTermSecretsSkillCopyChanged")
    /// Remove sends to the Trash; the self-test deletes its scratch copy instead, leaving the user's Trash alone.
    static var trashes = true

    static var paths: SecretsSkillCopy.Paths { SecretsSkillCopy.Paths(home: home) }

    static var written: String? {
        get { SecretReminderRecords.defaults.string(forKey: writtenKey) }
        set { SecretReminderRecords.defaults.set(newValue, forKey: writtenKey) }
    }

    private static var manager: FileManager { .default }

    /// Whose the copy at its place is now.
    static func state() -> SecretsSkillCopy.State {
        let text: String? = try? String(contentsOfFile: paths.file, encoding: .utf8)
        let isLink: Bool = (try? manager.destinationOfSymbolicLink(atPath: paths.folder)) != nil
        let exists: Bool = isLink || manager.fileExists(atPath: paths.folder)
        // A link at the folder's place is someone's own arrangement, whatever it points to.
        if isLink { return .theirs }
        return SecretsSkillCopy.state(onDisk: text, folderExists: exists, written: written, current: BuiltInSkill.secrets.text)
    }

    /// Writes the copy and Claude Code's link; nil when done, else why not.
    @discardableResult
    static func add() -> String? {
        let now: SecretsSkillCopy.State = state()
        guard now != .theirs else { return SecretsSkillCopy.summary(.theirs) }
        do {
            try write()
        } catch {
            return "Couldn\u{2019}t write ~/.agents/skills/\(SecretsSkillCopy.name): \(error.localizedDescription)"
        }
        linkForClaude()
        NotificationCenter.default.post(name: changed, object: nil)
        return nil
    }

    /// Sends Next Term's copy and its link to the Trash; nil when done, else why not.
    @discardableResult
    static func remove() -> String? {
        let now: SecretsSkillCopy.State = state()
        guard now == .current || now == .stale else { return "There is no copy of Next Term\u{2019}s to remove." }
        do {
            try discard(paths.folder)
        } catch {
            return "Couldn\u{2019}t move ~/.agents/skills/\(SecretsSkillCopy.name) to the Trash: \(error.localizedDescription)"
        }
        let link: String = paths.claudeLink
        if SecretsSkillCopy.linkIsOurs(destination: try? manager.destinationOfSymbolicLink(atPath: link), linkPath: link,
                                       folder: paths.folder) {
            try? discard(link)
        }
        written = nil
        NotificationCenter.default.post(name: changed, object: nil)
        return nil
    }

    /// At launch: Next Term's own copy of an earlier version gets today's text. Nothing else is touched.
    static func refresh() {
        guard state() == .stale else { return }
        try? write()
    }

    private static func discard(_ path: String) throws {
        if trashes { try manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } else { try manager.removeItem(atPath: path) }
    }

    private static func write() throws {
        let text: String = BuiltInSkill.secrets.text
        try manager.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
        try text.write(toFile: paths.file, atomically: true, encoding: .utf8)
        written = SecretsSkillCopy.hash(text)
    }

    /// Claude Code reads ~/.claude/skills, not ~/.agents/skills: a relative link there, only where Claude Code has its
    /// folder and nothing is at the link's place already.
    private static func linkForClaude() {
        let claude: String = (home as NSString).appendingPathComponent(".claude")
        guard manager.fileExists(atPath: claude) else { return }
        let link: String = paths.claudeLink
        let taken: Bool = (try? manager.destinationOfSymbolicLink(atPath: link)) != nil || manager.fileExists(atPath: link)
        guard !taken else { return }
        try? manager.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? manager.createSymbolicLink(atPath: link, withDestinationPath: "../../.agents/skills/" + SecretsSkillCopy.name)
    }
}

/// Settings › Secrets' "Agents look here first": what Add to Agents… does, the copy's state, and Add or Remove.
@MainActor
final class SecretsSkillSettingView: NSStackView {
    private(set) var addButton = NSButton(title: "Add to Agents\u{2026}", target: nil, action: nil)
    private(set) var removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private(set) var stateLabel = NSTextField(wrappingLabelWithString: "")
    /// The confirm on screen, for the self-test.
    private(set) var alert: NSAlert?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let heading = NSTextField(labelWithString: SecretsSkillCopy.title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let help = SecretApprovalPanel.label(SecretsSkillCopy.help, size: 11)
        help.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(add)
        removeButton.target = self
        removeButton.action = #selector(remove)
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = 8
        for view in [heading, help, stateLabel, buttons] { addArrangedSubview(view) }
        for view in [help, stateLabel] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: SecretsSkillInstall.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func reload() {
        let state: SecretsSkillCopy.State = SecretsSkillInstall.state()
        stateLabel.stringValue = SecretsSkillCopy.summary(state)
        let ours: Bool = state == .current || state == .stale
        addButton.isHidden = ours
        addButton.isEnabled = state == .absent
        removeButton.isHidden = !ours
    }

    /// Asks first, naming what is written, then writes it.
    @objc private func add() {
        let paths = SecretsSkillInstall.paths
        let alert = NSAlert()
        alert.messageText = "Add the next-term-secrets skill to your agents?"
        alert.informativeText = "Next Term writes \(Self.shown(paths.file)) and, if you use Claude Code, a link to its folder "
            + "at \(Self.shown(paths.claudeLink)). Your agents then check Secrets for a key before anything else. Next Term "
            + "keeps its own copy up to date, and Remove sends both to the Trash."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        self.alert = alert
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.alert = nil
            guard response == .alertFirstButtonReturn else { return }
            if let problem = SecretsSkillInstall.add() { self?.stateLabel.stringValue = problem }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    @objc private func remove() {
        if let problem = SecretsSkillInstall.remove() { stateLabel.stringValue = problem }
    }

    /// A path under the home as ~/…
    private static func shown(_ path: String) -> String {
        let home: String = SecretsSkillInstall.home
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
