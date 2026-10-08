import AppKit
import NextTermCore

/// The review sheet: every skill found at the fetched commit, and for the selected one everything the
/// developer needs before it is written: where it goes and which agents will load it, what it replaces,
/// what else its folder is (a plugin or extension, with what a Claude Code plugin starts by itself), the
/// MCP servers it brings to each agent, what it may do, what looks risky, and every file's text as written
/// (hidden characters spelled out, never rendered). Claude Code's link is a checkbox for plain skills and
/// a popup for plugin folders (SkillsClaudeChoice). Nothing is ticked when a source holds several skills.
/// Install has no Return key, so typing meant for somewhere else never installs anything.
@MainActor
final class SkillsReviewSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var fetched: SkillsInstaller.Fetched
    private var ticked: Set<Int>
    private var selected = 0
    /// Called once: the names installed, or nil when the user cancelled.
    private let done: ([String]?) -> Void
    /// Set for an agent's request: a download that is gone is reported to it as a failure, not as the
    /// user declining.
    var onDownloadGone: ((String) -> Void)?
    /// For an update: the installed copy, to show what changed.
    private let installedFolders: [String: String]

    private let list = NSTableView()
    private let heading = NSTextField(labelWithString: "")
    /// What the review says about the selected skill (readable by the self-test).
    private(set) var details = NSTextField(wrappingLabelWithString: "")
    private let fileChoice = NSPopUpButton()
    private(set) var textView: NSTextView!
    /// Claude Code's link for plain skills (readable by the self-test).
    let claudeLink = NSButton(checkboxWithTitle: "Link it for Claude Code (in ~/.claude/skills)", target: nil, action: nil)
    /// Claude Code's link for skill folders that are also Claude Code plugins (readable by the self-test).
    let choice = SkillsClaudeChoice()
    /// Each plugin folder's own default for Claude Code's link, by skill name, with the skills ticked now.
    private var presets: [String: SkillInstall.ClaudeLink] = [:]
    /// Claude Code is on this Mac, with a skills folder of its own: links can be made.
    private var claudeAvailable = false
    private(set) var installButton = NSButton(title: "Install", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(fetched: SkillsInstaller.Fetched, done: @escaping ([String]?) -> Void) {
        self.fetched = fetched
        self.done = done
        ticked = fetched.candidates.count == 1 && fetched.candidates[0].installable ? [0] : []
        // An installed copy of the same name, for the changes view (from the inventory read with the fetch).
        var installed: [String: String] = [:]
        let inventory = fetched.inventory
        for candidate in fetched.candidates {
            if let copy = inventory.rows.first(where: { $0.name == candidate.name })?.copies.first(where: { $0.root.kind == .shared && !$0.broken }) {
                installed[candidate.name] = copy.realPath
            }
        }
        installedFolders = installed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Review Skills"
        window.minSize = NSSize(width: 720, height: 480)
        super.init(window: window)
        build()
        refreshPresets()
        redraw()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var source: SkillSource { fetched.resolved.source }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Review skills from \(source.shortName)\(source.path.isEmpty ? "" : "/" + source.path)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        var facts = ["commit \(fetched.resolved.commit.prefix(7))"]
        if let date = fetched.resolved.date { facts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let info = fetched.info {
            facts.append("★ \(info.stars)")
            if let license = info.license { facts.append("repository licence \(license)") }
            if info.archived { facts.append("archived") }
        }
        if fetched.resolved.truncated { facts.append("GitHub listed only part of this large repository: some skills may be missing") }
        let subtitle = NSTextField(wrappingLabelWithString: facts.joined(separator: " · "))
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("skill"))
        column.title = fetched.candidates.count == 1 ? "Skill" : "\(fetched.candidates.count) skills (tick the ones to install)"
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 22
        list.dataSource = self
        list.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.widthAnchor.constraint(equalToConstant: 230).isActive = true

        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        details.font = .systemFont(ofSize: 12)
        details.isSelectable = true
        fileChoice.target = self
        fileChoice.action = #selector(fileChanged)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as? NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let detailsScroll = NSScrollView()
        let detailsHolder = FlippedView()
        detailsHolder.translatesAutoresizingMaskIntoConstraints = false
        let detailsStack = NSStackView(views: [heading, details])
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 6
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsHolder.addSubview(detailsStack)
        detailsScroll.documentView = detailsHolder
        detailsScroll.hasVerticalScroller = true
        detailsScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            detailsStack.topAnchor.constraint(equalTo: detailsHolder.topAnchor),
            detailsStack.leadingAnchor.constraint(equalTo: detailsHolder.leadingAnchor),
            detailsStack.trailingAnchor.constraint(equalTo: detailsHolder.trailingAnchor),
            detailsStack.bottomAnchor.constraint(equalTo: detailsHolder.bottomAnchor),
            detailsHolder.widthAnchor.constraint(equalTo: detailsScroll.contentView.widthAnchor),
            details.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
        ])
        detailsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        let fileRow = NSStackView(views: [NSTextField(labelWithString: "Show:"), fileChoice])
        fileRow.spacing = 6
        let right = NSStackView(views: [detailsScroll, fileRow, scroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        for view in [detailsScroll, scroll] { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        let middle = NSStackView(views: [listScroll, right])
        middle.alignment = .top
        middle.spacing = 12
        listScroll.heightAnchor.constraint(equalTo: right.heightAnchor).isActive = true

        claudeLink.state = .on
        claudeLink.target = self
        claudeLink.action = #selector(linkChanged)
        let claudeHere = FileManager.default.fileExists(atPath: (SkillsStore.home as NSString).appendingPathComponent(".claude"))
        claudeAvailable = fetched.inventory.root(.claude) != nil && claudeHere
        claudeLink.isHidden = !claudeAvailable
        if !claudeHere { claudeLink.state = .off }
        choice.onChange = { [weak self] in
            self?.updateDetails()
            self?.updateInstallButton()
        }
        installButton.target = self
        installButton.action = #selector(install)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "" // never Return: see the type's comment
        installButton.refusesFirstResponder = true // nor Tab and Space: only a click installs
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [claudeLink, NSView(), cancelButton, installButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, subtitle, middle, choice.view, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            middle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        list.reloadData()
        list.selectRowIndexes([0], byExtendingSelection: false)
    }

    // MARK: list

    func numberOfRows(in tableView: NSTableView) -> Int { fetched.candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = fetched.candidates[row]
        let box = NSButton(checkboxWithTitle: candidate.name, target: self, action: #selector(tickChanged(_:)))
        box.tag = row
        box.state = ticked.contains(row) ? .on : .off
        box.isEnabled = candidate.installable
        let level = candidate.review.flags.map(\.level).max()
        if !candidate.installable { box.toolTip = candidate.refusal ?? candidate.review.flags.first { $0.level == .refuse }?.text }
        else if level == .warning { box.title = candidate.name + "  ⚠︎" }
        return box
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard list.selectedRow >= 0 else { return }
        let before = coveredNames
        selected = list.selectedRow
        coverChanged(from: before)
        redraw()
    }

    @objc private func tickChanged(_ sender: NSButton) {
        let before = coveredNames
        if sender.state == .on { ticked.insert(sender.tag) } else { ticked.remove(sender.tag) }
        // The plugin names of the ticked skills can clash with each other: their defaults are worked out again.
        refreshPresets()
        coverChanged(from: before)
        if list.selectedRow == sender.tag { redraw() } else { list.selectRowIndexes([sender.tag], byExtendingSelection: false) }
    }

    @objc private func linkChanged() {
        updateDetails()
        updateInstallButton()
    }

    private var chosen: [SkillsInstaller.Candidate] { ticked.sorted().map { fetched.candidates[$0] } }

    /// The skills Claude Code's checkbox and popup cover: the ticked ones, or the selected one with none ticked.
    private var covered: [SkillsInstaller.Candidate] {
        let chosen = chosen
        guard chosen.isEmpty else { return chosen }
        return fetched.candidates.indices.contains(selected) ? [fetched.candidates[selected]] : []
    }

    private var coveredNames: Set<String> { Set(covered.map(\.name)) }

    /// Each plugin folder's own default, worked out once per change of ticks (it reads the installed copy).
    private func refreshPresets() {
        presets = [:]
        guard claudeAvailable else { return }
        let chosen = chosen
        for candidate in fetched.candidates where candidate.review.package?.claude != nil {
            presets[candidate.name] = SkillsInstaller.defaultClaudeLink(candidate, fetched: fetched, together: chosen)
        }
    }

    /// A plugin folder the popup newly covers whose own default leaves it out sets the popup back to that.
    private func coverChanged(from before: Set<String>) {
        let added = covered.filter { !before.contains($0.name) && $0.review.package?.claude != nil }
        if added.contains(where: { presets[$0.name] == .skip }) { choice.reset() }
    }

    /// Claude Code's link for one skill: the checkbox for a plain skill, the popup for a plugin folder it
    /// covers, and the folder's own default for one it doesn't (selected while others are ticked).
    private func claudeChoice(_ candidate: SkillsInstaller.Candidate) -> SkillInstall.ClaudeLink {
        guard claudeAvailable else { return .skip }
        guard candidate.review.package?.claude != nil else { return claudeLink.state == .on ? .link : .skip }
        if covered.contains(where: { $0.name == candidate.name }) { return choice.value }
        return presets[candidate.name] ?? .skip
    }

    /// The checkbox shows when a plain skill is covered, the popup when a plugin folder is; both for both.
    private func updateControls() {
        let covered = covered
        claudeLink.isHidden = !claudeAvailable || !covered.contains { $0.review.package?.claude == nil }
        let folders = claudeAvailable ? covered.compactMap(folder) : []
        choice.show(folders)
    }

    private func folder(_ candidate: SkillsInstaller.Candidate) -> SkillsClaudeChoice.Folder? {
        guard let plugin = candidate.review.package?.claude else { return nil }
        // The kept link and the clashes don't depend on the choice.
        let plan = SkillsInstaller.plan(candidate, fetched: fetched, claude: .skip, together: chosen)
        let start = plugin.start(key: fetched.claude.value(for: plugin.name))
        return SkillsClaudeChoice.Folder(skill: candidate.name, plugin: plugin, start: start, keptLink: plan.keptLink != nil,
                                         clashes: plan.clashes, preset: presets[candidate.name] ?? .skip)
    }

    /// Everything that follows the ticks, the selection and Claude Code's choice: the controls, the selected
    /// skill's review and the Install button.
    private func redraw() {
        updateControls()
        show(selected)
        updateInstallButton()
    }

    private func updateInstallButton() {
        let chosen = chosen
        installButton.isEnabled = !chosen.isEmpty && chosen.allSatisfy(\.installable)
        let plans = chosen.map { SkillsInstaller.plan($0, fetched: fetched, claude: claudeChoice($0), together: chosen) }
        if chosen.count > 1 { installButton.title = "Install \(chosen.count) Skills" }
        else if plans.first?.existing == .update { installButton.title = "Update" }
        else if plans.first?.existing == .conflict { installButton.title = "Replace and Install" }
        else { installButton.title = "Install" }
    }

    // MARK: one skill

    private func show(_ index: Int) {
        guard fetched.candidates.indices.contains(index) else { return }
        selected = index
        let candidate = fetched.candidates[index]
        let review = candidate.review
        heading.stringValue = candidate.name
        updateDetails()

        fileChoice.removeAllItems()
        if installedFolders[candidate.name] != nil { fileChoice.addItem(withTitle: "Changes since the installed copy") }
        for file in review.files {
            let size = file.linkTarget.map { "link to \($0)" } ?? ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            fileChoice.addItem(withTitle: "\(file.path) (\(size)\(file.executable ? ", executable" : ""))")
            fileChoice.lastItem?.representedObject = file.path
        }
        let skillItem = fileChoice.itemArray.first { ($0.representedObject as? String)?.lowercased() == "skill.md" }
        if installedFolders[candidate.name] == nil, let skillItem { fileChoice.select(skillItem) }
        fileChanged()
    }

    /// The selected skill's review, with Claude Code's choice as it is now. The file shown stays as it is.
    private func updateDetails() {
        guard fetched.candidates.indices.contains(selected) else { return }
        let candidate = fetched.candidates[selected]
        let review = candidate.review
        var lines: [String] = []
        if let description = review.frontMatter?.description { lines.append(SkillReview.revealHidden(description)) }
        lines.append("")
        let claude = claudeChoice(candidate)
        let plan = SkillsInstaller.plan(candidate, fetched: fetched, claude: claude, together: chosen)
        if let refusal = candidate.refusal { lines.append("⛔ Can't be installed: \(refusal)") }
        for flag in review.flags where flag.level == .refuse { lines.append("⛔ Can't be installed: \(flag.text)\(flag.file.isEmpty ? "" : " (\(flag.file))")") }
        let pluginOff = review.package?.claude.map { fetched.claude.value(for: $0.name) == false } ?? false
        let readers = SkillReaders.loadedBy(plan.agents, linked: plan.linksClaude, pluginOff: pluginOff)
        lines.append("Goes to ~/.agents/skills/\(candidate.name). " + readers)
        switch plan.existing {
        case .none: break
        case .update:
            lines.append("Installed before from this source: this updates it.")
            if fetched.editedSinceInstall.contains(candidate.name) {
                lines.append("⚠︎ You changed this skill since it was installed. Updating moves your version to the Trash; Undo puts it back.")
            }
        case .conflict:
            let places = plan.replaced.map { SkillStep.short($0.path) + ($0.isLink ? " (a link)" : "") }.joined(separator: ", ")
            lines.append("⚠︎ “\(candidate.name)” is already here: \(places). Installing moves \(plan.replaced.count == 1 ? "it" : "them") to the Trash (links are only removed); Undo puts \(plan.replaced.count == 1 ? "it" : "them") back.")
        }
        for note in SkillsReviewRows.notes(plan) { lines.append("• " + note) }
        for note in candidate.notes { lines.append("• " + note) }
        lines += SkillsReviewRows.lines(candidate, fetched: fetched, plan: plan, choice: claude)
        lines.append("")
        lines.append(licenceLine(review))
        let warnings = review.flags.filter { $0.level != .refuse }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Worth a look:")
            for flag in warnings { lines.append("\(flag.level == .warning ? "⚠︎" : "•") \(flag.text)\(flag.file.isEmpty ? "" : " — \(flag.file)")") }
        }
        if !review.capabilities.isEmpty {
            lines.append("")
            lines.append("What it may do:")
            for item in review.capabilities { lines.append("• " + item) }
        }
        if !review.urls.isEmpty {
            lines.append("")
            lines.append("Web addresses it mentions (what they serve is fetched when used, outside this commit):")
            for url in review.urls.prefix(20) { lines.append("• " + url) }
            if review.urls.count > 20 { lines.append("• and \(review.urls.count - 20) more") }
        }
        details.stringValue = lines.joined(separator: "\n")
    }

    private func licenceLine(_ review: SkillReview) -> String {
        guard let stated = review.license ?? fetched.info?.license else {
            return "No licence is stated: you may not be allowed to use or share it."
        }
        if review.licenseIsRestrictive { return "Licence: \(stated). It keeps rights back: read it before using or sharing the skill." }
        return "Licence: \(stated)."
    }

    @objc private func fileChanged() {
        let candidate = fetched.candidates[selected]
        guard let item = fileChoice.selectedItem else { return textView.string = "" }
        guard let relative = item.representedObject as? String else {
            // The changes view.
            let installed = installedFolders[candidate.name] ?? ""
            let folder = candidate.folder
            let shown = selected
            textView.string = "Comparing…"
            Task {
                let diff = await Task.detached { SkillsInstaller.changes(installed: installed, downloaded: folder) }.value
                // The user may have picked another file or skill meanwhile.
                guard selected == shown, fileChoice.selectedItem?.representedObject == nil else { return }
                textView.string = diff.isEmpty ? "No changes: the installed copy has the same files." : SkillReview.revealHidden(diff)
            }
            return
        }
        let path = (candidate.folder as NSString).appendingPathComponent(relative)
        let file = candidate.review.files.first { $0.path == relative }
        if let target = file?.linkTarget { return textView.string = "A link to \(target)." }
        guard let handle = FileHandle(forReadingAtPath: path) else { return textView.string = "" }
        let data = (try? handle.read(upToCount: 400_001)) ?? Data()
        try? handle.close()
        // Every file is shown as text, even when not valid UTF-8 (with replacement characters): SKILL.md
        // and the scripts are what the agent follows and runs, and zsh runs a file's lines whatever its
        // first bytes, so a program is shown too, under a note.
        let text = String(decoding: data.prefix(400_000), as: UTF8.self)
        let program = file?.program == true
        // A program's control bytes as dots: written out one by one they swamp the text and take seconds.
        // Zero-width characters, tag letters and the like are still written out.
        let shown = program ? SkillReview.dottingControls(text) : text
        let header = program ? "A compiled program, shown as text (zsh runs a file's lines whatever its first bytes):\n\n" : ""
        textView.string = header + SkillReview.revealHidden(shown) + (data.count > 400_000 ? "\n… (the rest is not shown)" : "")
    }

    // MARK: answer

    @objc private func cancel() {
        fetched.discard()
        finish(nil)
    }

    @objc private func install() {
        let chosen = chosen
        guard !chosen.isEmpty, chosen.allSatisfy(\.installable) else { return }
        installButton.isEnabled = false
        cancelButton.isEnabled = false
        choice.setEnabled(false)
        var choices: [String: SkillInstall.ClaudeLink] = [:]
        for candidate in chosen { choices[candidate.name] = claudeChoice(candidate) }
        Task {
            let result = await SkillsInstaller.install(chosen, fetched: fetched, claude: choices)
            cancelButton.isEnabled = true
            choice.setEnabled(true)
            switch result {
            case .success(let note):
                finish(chosen.map(\.name))
                if !note.isEmpty, let parent = window?.sheetParent ?? NSApp.keyWindow { SkillsSettingsView.tell(note, in: parent, title: "Installed") }
            case .failure(let failure):
                // The download is gone (it no longer matched the commit): this review is over.
                guard FileManager.default.fileExists(atPath: fetched.scratch.path) else {
                    // Told over the window this sheet is on, never over the review itself, which closes here.
                    let parent = window?.sheetParent
                    if let window, let parent { parent.endSheet(window) } else { window?.close() }
                    if let onDownloadGone {
                        onDownloadGone(failure.message)
                    } else {
                        done(nil)
                        if let parent { SkillsSettingsView.tell(failure.message, in: parent) }
                    }
                    return
                }
                // The skill folders or Claude Code's plugins changed since the review: redraw it from the
                // disk as it is now.
                if failure.message.hasPrefix("Your skill folders changed") || failure.message.hasPrefix("Your Claude Code plugins changed") {
                    let inventory = await SkillsStore.scan()
                    let claude = await SkillsInstaller.claudeFacts(fetched.candidates)
                    fetched = fetched.with(inventory: inventory, claude: claude, codex: await SkillsInstaller.codexFacts())
                    refreshPresets()
                    updateControls()
                    updateDetails()
                }
                // The download is kept after a failure, so Install can be tried again once the cause is fixed.
                updateInstallButton()
                if let window { SkillsSettingsView.tell(failure.message, in: window) }
            }
        }
    }

    private func finish(_ installed: [String]?) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) } else { window?.close() }
        done(installed)
    }
}

/// A view whose origin is at the top, so a stack in a scroll view starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
