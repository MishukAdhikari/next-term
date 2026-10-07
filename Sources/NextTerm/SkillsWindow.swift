import AppKit
import NextTermCore

/// Window › Skills: find skills and install them. Featured skills from the agents' makers, or any public
/// GitHub source pasted in; every install goes through the review sheet. Managing what is installed
/// (updates, removal, Unify, Undo) lives in Settings › Skills.
@MainActor
final class SkillsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static var shared: SkillsWindowController?

    /// Whether opening the window checks installed skills for updates (at most once an hour).
    static var checksOnOpen: Bool {
        get { UserDefaults.standard.object(forKey: "SkillsCheckUpdatesOnOpen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SkillsCheckUpdatesOnOpen") }
    }

    private let sourceField = NSTextField()
    private let addButton = NSButton(title: "Review…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let featured = NSTableView()
    private let reviewFeatured = NSButton(title: "Review…", target: nil, action: nil)
    private let updatesBanner = NSTextField(labelWithString: "")
    private let manageButton = NSButton(title: "Manage in Settings", target: nil, action: nil)
    private var installedNames = Set<String>()
    private var busy = false
    private var review: SkillsReviewSheet?

    static func show() {
        if shared == nil { shared = SkillsWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        shared?.opened()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Skills"
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SkillsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SkillsInstaller.updatesChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let addTitle = NSTextField(labelWithString: "Add from GitHub")
        addTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sourceField.placeholderString = "owner/repo, owner/repo/path/to/skill, or a github.com link"
        sourceField.delegate = self
        sourceField.target = self
        sourceField.action = #selector(addFromGitHub)
        addButton.target = self
        addButton.action = #selector(addFromGitHub)
        addButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let addRow = NSStackView(views: [sourceField, addButton, spinner])
        addRow.spacing = 8
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Next Term fetches one commit, checks its files, and shows you everything before anything is written. Public repositories only."

        let featuredTitle = NSTextField(labelWithString: "Featured")
        featuredTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let featuredNote = NSTextField(wrappingLabelWithString: "From Anthropic's and OpenAI's public skill repositories, at a commit Next Term looked at. Installing still shows the full review.")
        featuredNote.font = .systemFont(ofSize: 11)
        featuredNote.textColor = .secondaryLabelColor
        for (id, title, width) in [("name", "Skill", 170.0), ("from", "From", 120.0), ("summary", "What it does", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            featured.addTableColumn(column)
        }
        featured.dataSource = self
        featured.delegate = self
        featured.usesAlternatingRowBackgroundColors = true
        featured.target = self
        featured.doubleAction = #selector(reviewFeaturedSkill)
        let scroll = NSScrollView()
        scroll.documentView = featured
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        reviewFeatured.target = self
        reviewFeatured.action = #selector(reviewFeaturedSkill)
        reviewFeatured.bezelStyle = .rounded
        reviewFeatured.isEnabled = false

        updatesBanner.textColor = .controlAccentColor
        manageButton.target = self
        manageButton.action = #selector(manage)
        manageButton.bezelStyle = .rounded
        let bottom = NSStackView(views: [updatesBanner, NSView(), reviewFeatured, manageButton])
        bottom.spacing = 8

        let stack = NSStackView(views: [addTitle, addRow, status, featuredTitle, featuredNote, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: status)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [addRow, status, featuredNote, scroll, bottom] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    /// Each time the window opens: the update check, if it is on and an hour has passed.
    private func opened() {
        guard Self.checksOnOpen, SkillsStore.home == NSHomeDirectory() else { return }
        if let last = SkillsInstaller.lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        Task { await SkillsInstaller.checkForUpdates() }
    }

    @objc private func refresh() {
        installedNames = Set(SkillsStore.inventory().rows.map(\.name))
        featured.reloadData()
        let count = SkillsInstaller.updates.values.filter { if case .available = $0 { return true }; return false }.count
        updatesBanner.stringValue = count == 0 ? "" : count == 1 ? "1 update available" : "\(count) updates available"
    }

    // MARK: featured

    func numberOfRows(in tableView: NSTableView) -> Int { SkillFeatured.list.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let skill = SkillFeatured.list[row]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        switch tableColumn?.identifier.rawValue {
        case "name": cell.stringValue = skill.name + (installedNames.contains(skill.name) ? "  ✓ installed" : "")
        case "from": cell.stringValue = skill.owner == "anthropics" ? "Anthropic" : "OpenAI"
        default:
            cell.stringValue = skill.summary
            cell.textColor = .secondaryLabelColor
        }
        cell.toolTip = "\(skill.owner)/\(skill.repo)/\(skill.path) at \(skill.commit.prefix(7))"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        reviewFeatured.isEnabled = featured.selectedRow >= 0 && !busy
    }

    @objc private func reviewFeaturedSkill() {
        guard SkillFeatured.list.indices.contains(featured.selectedRow) else { return }
        let skill = SkillFeatured.list[featured.selectedRow]
        fetchAndReview(skill.source, at: skill.commit)
    }

    // MARK: add from GitHub

    func controlTextDidChange(_ obj: Notification) {
        status.textColor = .secondaryLabelColor
    }

    @objc private func addFromGitHub() {
        let text = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let source = SkillSource.parse(text) else {
            return say("That is not a GitHub source. Paste owner/repo, owner/repo/path, or a github.com link.", problem: true)
        }
        fetchAndReview(source, at: nil)
    }

    private func fetchAndReview(_ source: SkillSource, at commit: String?) {
        guard !busy, let window else { return }
        busy = true
        spinner.startAnimation(nil)
        addButton.isEnabled = false
        reviewFeatured.isEnabled = false
        say("Fetching \(source.shortName)…", problem: false)
        Task {
            defer {
                busy = false
                spinner.stopAnimation(nil)
                addButton.isEnabled = true
                reviewFeatured.isEnabled = featured.selectedRow >= 0
            }
            do {
                let fetched = try await SkillsInstaller.fetch(source, at: commit)
                say("", problem: false)
                let sheet = SkillsReviewSheet(fetched: fetched) { [weak self] installed in
                    self?.review = nil
                    if installed { self?.say("Installed. Settings › Skills shows it, with Undo.", problem: false) }
                }
                review = sheet
                if let sheetWindow = sheet.window { window.beginSheet(sheetWindow, completionHandler: nil) }
            } catch {
                say((error as? SkillsGitHub.Failure)?.message ?? error.localizedDescription, problem: true)
            }
        }
    }

    private func say(_ text: String, problem: Bool) {
        status.stringValue = text
        status.textColor = problem ? .systemRed : .secondaryLabelColor
    }

    @objc private func manage() {
        AppDelegate.shared.showSettings(nil)
        NSApp.windows.compactMap { $0.windowController as? SettingsWindowController }.first?.showTab("skills")
    }
}

extension AppDelegate {
    @objc func showSkills(_ sender: Any?) {
        MainActor.assumeIsolated { SkillsWindowController.show() }
    }
}
