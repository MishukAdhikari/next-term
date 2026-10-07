import AppKit
import NextTermCore

/// The review sheet: every skill found at the fetched commit, and for the selected one everything the
/// developer needs before it is written: where it goes and which agents will load it, what it replaces,
/// what it may do, what looks risky, and every file's text as written (hidden characters spelled out,
/// never rendered). Nothing is ticked when a source holds several skills. Install has no Return key, so
/// typing meant for somewhere else never installs anything.
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
    private let details = NSTextField(wrappingLabelWithString: "")
    private let fileChoice = NSPopUpButton()
    private(set) var textView: NSTextView!
    private let claudeLink = NSButton(checkboxWithTitle: "Link it for Claude Code (in ~/.claude/skills)", target: nil, action: nil)
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
        show(0)
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
        claudeLink.isHidden = fetched.inventory.root(.claude) == nil || !claudeHere
        if !claudeHere { claudeLink.state = .off }
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

        let stack = NSStackView(views: [title, subtitle, middle, buttons])
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
        updateInstallButton()
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
        if list.selectedRow >= 0 { show(list.selectedRow) }
    }

    @objc private func tickChanged(_ sender: NSButton) {
        if sender.state == .on { ticked.insert(sender.tag) } else { ticked.remove(sender.tag) }
        list.selectRowIndexes([sender.tag], byExtendingSelection: false)
        updateInstallButton()
    }

    @objc private func linkChanged() {
        show(selected)
        updateInstallButton()
    }

    private var linkForClaude: Bool { !claudeLink.isHidden && claudeLink.state == .on }

    private func updateInstallButton() {
        let chosen = ticked.sorted().map { fetched.candidates[$0] }
        installButton.isEnabled = !chosen.isEmpty && chosen.allSatisfy(\.installable)
        let plans = chosen.map { SkillsInstaller.plan($0, fetched: fetched, linkForClaude: linkForClaude) }
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
        var lines: [String] = []
        if let description = review.frontMatter?.description { lines.append(SkillReview.revealHidden(description)) }
        lines.append("")
        let plan = SkillsInstaller.plan(candidate, fetched: fetched, linkForClaude: linkForClaude)
        if let refusal = candidate.refusal { lines.append("⛔ Can't be installed: \(refusal)") }
        for flag in review.flags where flag.level == .refuse { lines.append("⛔ Can't be installed: \(flag.text)\(flag.file.isEmpty ? "" : " (\(flag.file))")") }
        let names = plan.agents.map(\.title)
        lines.append("Goes to ~/.agents/skills/\(candidate.name). Loaded by \(names.joined(separator: ", ")).")
        lines.append("Every agent that reads ~/.agents/skills loads it; the only choice is Claude Code's link.")
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
        for note in plan.untouched { lines.append("• " + note) }
        for note in candidate.notes { lines.append("• " + note) }
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
        let chosen = ticked.sorted().map { fetched.candidates[$0] }
        guard !chosen.isEmpty, chosen.allSatisfy(\.installable) else { return }
        installButton.isEnabled = false
        cancelButton.isEnabled = false
        Task {
            let result = await SkillsInstaller.install(chosen, fetched: fetched, linkForClaude: linkForClaude)
            cancelButton.isEnabled = true
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
                // The skill folders changed since the review: redraw it from the disk as it is now.
                if failure.message.hasPrefix("Your skill folders changed") {
                    fetched = fetched.with(inventory: await SkillsStore.scan())
                    show(selected)
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
