import AppKit
import NextTermCore

/// Import from MCP Configs…: the keys found in plain text in the MCP configs Next Term knows, one row per
/// key, every row unticked. Move Selected asks once, names every file it changes and how its servers start afterwards,
/// then one Touch ID saves the keys and seals what each backup keeps, and each file is rewritten. Core's
/// `SecretImport` plans and writes; this sheet only asks.
@MainActor
final class SecretImportSheet: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let refusal = "Turn on “Let agents control Next Term” first. Servers get their keys through it."
    static let placeRefusal = "Move Next Term to Applications and open it from there first, so the servers' command keeps working. "
        + "It is running from a disk image or a temporary copy, which won't be there later."
    static let gitWarning = "This file is shared through git: the change reaches everyone who pulls, and they need Next Term. "
        + "Git history keeps the old key."
    static let commentNote = "Comments inside this server's entry are lost when it is rewritten."
    static let keepsCopies = "Next Term keeps a copy of each changed entry with the keys taken out, so Undo can put them back for 30 days."
    static let startsAfter = "After this, these servers start only while Next Term is open. Each start asks you to approve with Touch ID, "
        + "unless you allowed it earlier. If you don't answer within 25 seconds, the server doesn't start. Allow it, then restart the server."
    static let rotate = "These keys sat in plaintext files. To rotate a key, make a new one on the service's website, then use Replace… here. "
        + "Do it if this Mac ever ran an untrusted install, or if a file is in git: its history keeps the old key. Time Machine keeps old copies too."
    static let restart = "Restart the servers: /mcp in Claude Code, or restart the agent. The first time an agent starts these servers, "
        + "approve each one. Restart any you missed."

    /// Where it looks, and how (the self-test passes a temporary home, and no app runs).
    struct Setup {
        var home = NSHomeDirectory()
        var projects: [String] = []
        var agentControl = true
        /// Whether the app with this bundle identifier runs now (the Claude app, which saves its MCP file whole): asked
        /// at the scan, when the move plans and just before each write, never kept from an earlier ask.
        var isOpen: @Sendable (String) -> Bool = { _ in false }
        var lockWait: TimeInterval = 5
        /// The command moved entries start (`nxtrmCommand()`); nil when no path to it lasts, and the import refuses.
        var nxtrm: [String]?
    }

    /// One row the user can tick: a group of identical values.
    @MainActor
    final class GroupRow {
        let group: SecretImport.Group
        let box: NSButton
        let nameField: NSTextField
        let nameNote: NSTextField
        let result: NSTextField

        init(group: SecretImport.Group, box: NSButton, nameField: NSTextField, nameNote: NSTextField, result: NSTextField) {
            self.group = group
            self.box = box
            self.nameField = nameField
            self.nameNote = nameNote
            self.result = result
        }

        var name: String { SecretRequestWindow.normalized(nameField.stringValue.trimmingCharacters(in: .whitespaces)) }
    }

    private let setup: Setup
    private let done: () -> Void
    private let rows = NSStackView()
    private(set) var headerLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var moveButton = NSButton(title: "Move Selected…", target: nil, action: nil)
    private(set) var closeButton = NSButton(title: "Close", target: nil, action: nil)
    private(set) var groupRows: [GroupRow] = []
    /// What the scan found that can't move, as each row says it.
    private(set) var listed: [String] = []
    private(set) var scan: SecretImport.Scan?
    private(set) var confirmAlert: NSAlert?
    /// Each file's result, after a move.
    private(set) var results: [String: SecretImport.Applied] = [:]
    private(set) var isBusy = false
    /// The scan under way: cancelled when the sheet closes or scans again, so it stops between files.
    private var scanTask: Task<Void, Never>?
    #if DEBUG
    /// Whether the last plan ran on the main thread, for the self-test: it reads every file again, so it never should.
    private(set) var plannedOnMainThread: Bool?
    #endif

    init(_ setup: Setup, done: @escaping () -> Void) {
        self.setup = setup
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: building

    private func build() {
        guard let view = window?.contentView else { return }
        let title = SecretApprovalPanel.label("Import from MCP Configs", size: 14, weight: .semibold)
        headerLabel.font = .systemFont(ofSize: 12)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.isHidden = true
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = ImportFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        moveButton.target = self
        moveButton.action = #selector(moveSelected)
        moveButton.isEnabled = false
        closeButton.target = self
        closeButton.action = #selector(closeSheet)
        closeButton.keyEquivalent = "\u{1b}"
        for button in [moveButton, closeButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [NSView(), closeButton, moveButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, headerLabel, statusLabel, scroll, summaryLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ]
        for row in [headerLabel, statusLabel, scroll, summaryLabel, buttons] {
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36))
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Shows the sheet on `parent` and starts the scan; with agent control off, or no lasting `nxtrm` path, only a refusal.
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
        start()
    }

    /// The scan, off the main thread.
    func start() {
        guard setup.agentControl else { return refuse(Self.refusal) }
        // The configs keep the command after Next Term quits: never one in a disk image or a translocated copy.
        guard setup.nxtrm != nil else { return refuse(Self.placeRefusal) }
        let count = setup.projects.count
        headerLabel.stringValue = "Looked in your agents' settings and in the \(count) \(count == 1 ? "project" : "projects") open in Next Term."
        statusLabel.stringValue = "Looking…"
        let setup = setup
        scanTask?.cancel()
        scanTask = Task.detached {
            let sources = SecretImport.sources(home: setup.home, projects: setup.projects)
            let found = SecretImport.scan(sources, inGitWorkTree: SecretImport.isInGitWorkTree, isOpen: setup.isOpen)
            // Checked again on the main actor, where `closeSheet` cancels: a scan that ended as the sheet closed shows nothing.
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.show(found)
            }
        }
    }

    /// Only `text`, in the header: no scan, and nothing to move.
    private func refuse(_ text: String) {
        headerLabel.stringValue = text
        headerLabel.setAccessibilityLabel("Warning: \(text)")
        statusLabel.isHidden = true
    }

    /// The rows: one per group of identical values, unticked; then what can't move, what uses Secrets already, and the
    /// files that couldn't be checked.
    func show(_ found: SecretImport.Scan) {
        scan = found
        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        groupRows = []
        listed = []
        let index = SecretsStore.shared.index
        let stored = index?.names ?? []
        let mask = SecretMask.current
        // A value keys an earlier move stored hold already (a move tried again after its file was left as it was)
        // keeps those keys, one per group.
        let groups = SecretImport.groups(found.findings, stored: stored) { value in
            SecretImport.reusable(holding: value, in: index, mask: mask)
        }
        for group in groups { addGroupRow(group) }
        for finding in found.findings where !finding.movable {
            let text = "\(Self.place(finding)): \(finding.notMovable ?? "")"
            listed.append(text)
            rows.addArrangedSubview(Self.small(text, color: .secondaryLabelColor))
        }
        for (source, location) in found.wrapped {
            let server: String = SecretImport.shownServer(location.server)
            let text = "\(source.client.name), \(Self.file(source.path)), “\(server)”: uses Next Term's Secrets"
            listed.append(text)
            rows.addArrangedSubview(Self.small(text, color: .secondaryLabelColor))
        }
        let shown = listed.count
        // Files there but not read: keys in them were not looked for, so the sheet never says none were found.
        for (source, reason) in found.unreadable {
            let text = "\(source.client.name), \(Self.file(source.path)): \(Self.notChecked) (\(reason))"
            listed.append(text)
            rows.addArrangedSubview(Self.warning(text))
        }
        statusLabel.stringValue = Self.status(movable: groups.count, listed: shown, unchecked: found.unreadable.count)
        refreshMove()
    }

    static let noKeysLine = "No keys in plain text were found."
    static let notChecked = "not checked"

    /// The line above the rows: what can move, and how many files were not checked.
    static func status(movable: Int, listed: Int, unchecked: Int) -> String {
        var text = "\(movable) \(movable == 1 ? "key" : "keys") can move. Tick the ones to move."
        if movable == 0, listed == 0 { text = unchecked == 0 ? noKeysLine : "No keys in plain text were found in the files Next Term read." }
        guard unchecked > 0 else { return text }
        return text + " \(unchecked) \(unchecked == 1 ? "file couldn't be checked for keys; it is" : "files couldn't be checked for keys; they are")"
            + " listed below."
    }

    private func addGroupRow(_ group: SecretImport.Group) {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ticked))
        box.state = .off
        box.setAccessibilityLabel("Move \(group.name)")
        let nameField = NSTextField(string: group.name)
        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self
        nameField.setAccessibilityLabel("Name in Secrets")
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let nameNote = Self.small("", color: .systemOrange)
        let kind = SecretApprovalPanel.label("\(group.kind), ending …\(group.findings[0].lastFour)", size: 11)
        kind.textColor = .secondaryLabelColor
        let line = NSStackView(views: [box, nameField, kind])
        line.spacing = 8
        var views: [NSView] = [line, nameNote]
        if let summary = group.summary { views.append(Self.small(summary, color: .labelColor)) }
        for finding in group.findings { views.append(Self.small(Self.place(finding), color: .secondaryLabelColor)) }
        if group.findings.contains(where: \.shared) { views.append(Self.warning(Self.gitWarning)) }
        if group.findings.contains(where: \.loses) { views.append(Self.small(Self.commentNote, color: .secondaryLabelColor)) }
        let result = Self.small("", color: .labelColor)
        result.isHidden = true
        views.append(result)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        rows.addArrangedSubview(stack)
        groupRows.append(GroupRow(group: group, box: box, nameField: nameField, nameNote: nameNote, result: result))
    }

    /// "Codex, ~/.codex/config.toml, “github”, GITHUB_TOKEN", the server's name cut at 60 characters.
    static func place(_ finding: SecretImport.Finding) -> String {
        let server: String = SecretImport.shownServer(finding.location.server)
        return "\(finding.source.client.name), \(file(finding.source.path)), “\(server)”, \(finding.variable)"
    }

    static func file(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    static func small(_ text: String, color: NSColor) -> NSTextField {
        let label = SecretApprovalPanel.label(text, size: 11)
        label.textColor = color
        label.preferredMaxLayoutWidth = 560
        return label
    }

    static func warning(_ text: String) -> NSView {
        let label = small("⚠︎ " + text, color: .systemOrange)
        label.setAccessibilityLabel("Warning: \(text)")
        return label
    }

    // MARK: ticking

    @objc private func ticked() { refreshMove() }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, groupRows.contains(where: { $0.nameField === field }) else { return }
        let shown = SecretRequestWindow.normalized(field.stringValue)
        if shown != field.stringValue { field.stringValue = shown }
        refreshMove()
    }

    static let reuseNote = "Already in Secrets with this value, from an earlier move: the move uses that key and stores no "
        + "second copy."

    /// Whether a row's name is a key an earlier move stored that holds its value already, and that the move may use
    /// (`SecretImport.reusable`: not one added in Settings or by an agent, not a write-only one).
    func reusesStored(_ row: GroupRow) -> Bool {
        let reusable = SecretImport.reusable(holding: row.group.value, in: SecretsStore.shared.index, mask: .current)
        return reusable.contains(row.name)
    }

    /// A ticked row's name is checked as typed: the rule, a stored key with another value, or another ticked row.
    func nameProblem(_ row: GroupRow) -> String? {
        let name = row.name
        guard StoredSecretName.isValid(name) else { return StoredSecretName.rule }
        let isStored = SecretsStore.shared.index?.entry(named: name) != nil
        if isStored, !reusesStored(row) { return "A key named \(name) is stored already." }
        if groupRows.contains(where: { $0 !== row && $0.box.state == .on && $0.name == name }) { return "Another row has this name." }
        return nil
    }

    func refreshMove() {
        var ok = true
        var any = false
        for row in groupRows {
            let problem = row.box.state == .on ? nameProblem(row) : nil
            let note = problem ?? (reusesStored(row) ? Self.reuseNote : nil)
            row.nameNote.stringValue = note ?? ""
            row.nameNote.textColor = problem == nil ? .secondaryLabelColor : .systemOrange
            row.nameNote.isHidden = note == nil
            if row.box.state == .on {
                any = true
                if problem != nil { ok = false }
            }
        }
        moveButton.isEnabled = !isBusy && any && ok
    }

    func tick(_ name: String, _ on: Bool = true) {
        groupRows.first { $0.group.name == name }?.box.state = on ? .on : .off
        refreshMove()
    }

    // MARK: moving

    /// The ticked rows as moves.
    var moves: [SecretImport.Move] {
        groupRows.filter { $0.box.state == .on }.map { SecretImport.Move(name: $0.name, findings: $0.group.findings) }
    }

    @objc func moveSelected() {
        guard moveButton.isEnabled, let window else { return }
        let moves = self.moves
        let files = Array(Set(moves.flatMap { $0.findings.map(\.source.path) })).sorted()
        let count = moves.count
        // A value not ticked that a wrapped entry drops, since the wrapper would take it out at start: named before the write.
        let stored: [String] = SecretsStore.shared.index?.names ?? []
        let dropped = SecretImport.droppedFindings(moves, among: scan?.findings ?? [], stored: stored)
        let droppedPlaces: [(variable: String, server: String)] = dropped.map { ($0.variable, $0.location.server) }
        var listed: String = files.map { "• " + Self.file($0) }.joined(separator: "\n")
        if let warning = SecretImport.droppedWarning(droppedPlaces) { listed += "\n\n" + warning }
        let alert = NSAlert()
        alert.messageText = "Move \(count) \(count == 1 ? "key" : "keys") into Secrets?"
        alert.informativeText = listed + "\n\n" + Self.keepsCopies + "\n\n" + Self.startsAfter
        alert.addButton(withTitle: "Move Keys")
        alert.addButton(withTitle: "Cancel")
        confirmAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.confirmAlert = nil
                if response == .alertFirstButtonReturn { self?.move(moves) }
            }
        }
    }

    /// Plan (off the main thread: it reads each file again), one Touch ID (the keys saved, the kept values sealed), the
    /// backups, then each file written.
    func move(_ moves: [SecretImport.Move]) {
        guard let nxtrm = setup.nxtrm else { return }
        setBusy(true, Self.readingLine)
        let setup = setup
        // The vault's names: what nxtrm secret run takes out of a server's environment unless the entry asks for it.
        let stored: [String] = SecretsStore.shared.index?.names ?? []
        Task { @MainActor in
            let planned = await Task.detached { () -> (edits: [SecretImport.FileEdit], failures: [SecretImport.PlanFailure], onMain: Bool) in
                // An app opened since the scan leaves its file now, before any key is stored for it.
                let plan = SecretImport.plan(moves, nxtrm: nxtrm, stored: stored, isOpen: setup.isOpen)
                return (plan.edits, plan.failures, pthread_main_np() != 0)
            }.value
            #if DEBUG
            self.plannedOnMainThread = planned.onMain
            #endif
            for failure in planned.failures { self.results[failure.path] = .skipped(failure.reason) }
            var edits = planned.edits
            guard !edits.isEmpty else {
                self.setBusy(false)
                return self.showResults(edits: [], moved: [])
            }
            let movedNames = Set(edits.flatMap(\.names))
            let keys = moves.filter { movedNames.contains($0.name) }.map { move in
                SecretsStore.ImportKey(name: move.name, purpose: Self.purpose(move), value: move.findings[0].value)
            }
            var kept: [String: [SecretBytes]] = [:]
            for edit in edits { for backup in edit.backups { kept[backup.id] = backup.keptValues } }
            do {
                self.statusLabel.stringValue = Self.touchIDLine
                let imported = try await SecretsStore.shared.performImport(keys, kept: kept, reason: SecretReason.moveOut(keys.count))
                for index in edits.indices {
                    for backup in edits[index].backups { edits[index].seal(backup.id, box: imported.boxes[backup.id]) }
                    // Which keys this move stored, not used from an earlier one: an Undo of it deletes those alone.
                    edits[index].setStored(imported.stored)
                }
                try SecretsStore.shared.saveBackups(edits.flatMap(\.backups))
                self.statusLabel.stringValue = Self.writingLine
                let written = await Task.detached { () -> [String: SecretImport.Applied] in
                    var results: [String: SecretImport.Applied] = [:]
                    for edit in edits {
                        // Asked again here: the app may have opened during Touch ID.
                        results[edit.path] = SecretImport.apply(edit, lockWait: setup.lockWait, isOpen: setup.isOpen)
                    }
                    return results
                }.value
                for (path, result) in written { self.results[path] = result }
                // A file left as it was keeps no backup: there is nothing to undo there.
                for edit in edits where written[edit.path] != .written {
                    for backup in edit.backups { SecretsStore.shared.removeBackup(backup) }
                }
                self.setBusy(false)
                self.showResults(edits: edits, moved: keys.map(\.name))
            } catch SecretsStore.Failure.cancelled {
                self.setBusy(false, "Not approved.")
            } catch {
                self.setBusy(false, (error as? LocalizedError)?.errorDescription ?? "Next Term couldn’t move the keys.")
            }
        }
    }

    /// What it's for, for a moved key: where it came from.
    static func purpose(_ move: SecretImport.Move) -> String {
        let first = move.findings[0]
        let more = move.findings.count > 1 ? " and \(move.findings.count - 1) more" : ""
        return String("\(first.source.client.name) MCP server “\(first.location.server)”\(more)".prefix(SecretVault.maxPurposeLength))
    }

    /// Each row's file result, and the summary, which says it all: the line above the rows goes, so it never still
    /// waits for a Touch ID that was never asked (every file left as it was) or that is over.
    private func showResults(edits: [SecretImport.FileEdit], moved: [String]) {
        statusLabel.isHidden = true
        for row in groupRows where row.box.state == .on {
            let lines = Set(row.group.findings.map(\.source.path)).sorted().map { path -> String in
                "\(Self.file(path)): \(Self.text(results[path]))"
            }
            row.result.stringValue = lines.joined(separator: "\n")
            row.result.isHidden = false
            row.box.isEnabled = false
        }
        let written = edits.filter { results[$0.path] == .written }
        let files = written.count
        let movedOut = moved.filter { name in written.contains { $0.names.contains(name) } }
        let keys = movedOut.count
        var summary = "Moved \(keys) \(keys == 1 ? "key" : "keys") from \(files) \(files == 1 ? "file" : "files")."
        let stayed = moved.filter { !movedOut.contains($0) }
        if !stayed.isEmpty {
            summary += " \(SecretRun.keysText(stayed)) \(stayed.count == 1 ? "is" : "are") in Secrets, but no file was changed for "
                + (stayed.count == 1 ? "it." : "them.")
        }
        // What the written entries dropped with their keys, since the wrapper would take it out at start.
        if let dropped = SecretImport.droppedText(written.flatMap(\.dropped)) { summary += "\n\n" + dropped }
        summaryLabel.stringValue = summary + "\n\n" + Self.rotate + "\n\n" + Self.restart
        summaryLabel.isHidden = false
        moveButton.isEnabled = false
        done()
    }

    static func text(_ applied: SecretImport.Applied?) -> String {
        switch applied {
        case .written?: return "moved"
        case .changed?: return "it changed while Next Term wrote it, so it was left as it is"
        case .locked?: return SecretImport.lockedNote
        case .skipped(let reason)?: return "left as it is (\(reason))"
        case .failed(let reason)?: return "not written (\(reason))"
        case nil: return "not written"
        }
    }

    static let readingLine = "Reading the files again…"
    static let touchIDLine = "Waiting for Touch ID or your password…"
    static let writingLine = "Writing the files…"

    /// Busy: Move and Close are off. `status`, when given, is the line above the rows; otherwise it stays as it is.
    private func setBusy(_ busy: Bool, _ status: String? = nil) {
        isBusy = busy
        closeButton.isEnabled = !busy
        if let status {
            statusLabel.stringValue = status
            statusLabel.isHidden = false
        }
        refreshMove()
    }

    @objc func closeSheet() {
        guard !isBusy, let window else { return }
        scanTask?.cancel()
        scanTask = nil
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        done()
    }

    /// The command a wrapped entry starts: the `nxtrm` link Next Term made on PATH (launches repoint it), else the
    /// script in the running app, else this binary with `--cli`; the app's own paths only when it is where it stays
    /// (`CommandLineTool.isInStableLocation`, as MCP registration asks). Nil when no path lasts (`SecretImport.wrapperCommand`).
    static func nxtrmCommand() -> [String]? {
        let script = CommandLineTool.script?.path
        var links: [(path: String, target: String)] = []
        if CommandLineTool.isInstalled, let script { links.append((CommandLineTool.installPath, script)) }
        if let made = UserDefaults.standard.string(forKey: CommandLineTool.linkedKey), case .link(let target) = CommandLineTool.entry(at: made),
           CommandLineTool.isOurs(target) {
            links.append((made, target))
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return SecretImport.wrapperCommand(links: links, script: script, executable: executable, appLasts: CommandLineTool.isInStableLocation)
    }
}

/// A document view whose rows start at the top.
private final class ImportFlippedView: NSView {
    override var isFlipped: Bool { true }
}
