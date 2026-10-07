import AppKit
import NextTermCore

/// The selected commit in full, beside the Git Log: its message, who made it and when, its id (with
/// Copy), its parents (click one to go to it), its branches and tags, then the files it changed with
/// their lines added and removed. Double-click a file, or press ↩ on it, for its diff in this commit.
final class GitLogDetailsView: NSView, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let root: String
    /// A parent's id was clicked.
    var onSelectCommit: ((String) -> Void)?
    /// A file was double-clicked: its change in the commit.
    var onOpenFile: ((ChangedFile, CommitDetails) -> Void)?

    private(set) var details: CommitDetails?
    private(set) var shown: Commit?
    private(set) var isLoading = false
    /// The commit shown is the newest request: a read still queued for one already left is skipped.
    private let requests = NewestRequest()
    private var pending: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "nextterm.git-log-details", qos: .userInitiated)

    private let textScroll = NSTextView.scrollableTextView()
    var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let filesHeader = NSTextField(labelWithString: "")
    let files = GitLogTableView()
    private let filesScroll = NSScrollView()
    private let split = NSSplitView()
    private let empty = NSTextField(labelWithString: "Select a commit to see it here.")

    init(root: String) {
        self.root = root
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// For the self-test: the changed files as listed.
    var fileNames: [String] { details?.files.map(\.path) ?? [] }
    var text: String { textView.string }

    /// Shows a commit: what the log row knows at once, the rest when git has read it.
    func show(_ commit: Commit?) {
        let token = requests.next()
        pending?.cancel()
        shown = commit
        details = nil
        files.reloadData()
        empty.isHidden = commit != nil
        split.isHidden = commit == nil
        guard let commit, let git = GitLogPane.git else {
            isLoading = false
            return
        }
        render(CommitDetails(commit: commit, message: commit.subject))
        filesHeader.stringValue = "Reading the changed files…"
        isLoading = true
        let root = self.root, requests = self.requests
        // Moving through the list with the arrow keys reads only where it stops. One read at a time,
        // and one can take half a minute (a treeless clone fetching from a remote that does not answer):
        // those queued behind it for commits already left are skipped.
        let work = DispatchWorkItem {
            requests.async(on: Self.queue, for: token) { [weak self] in
                let read = CommitLog.details(of: commit.sha, in: root, git: git)
                DispatchQueue.main.async {
                    guard let self, requests.isNewest(token) else { return }
                    self.isLoading = false
                    guard let read else {
                        self.filesHeader.stringValue = "Git could not read this commit."
                        return
                    }
                    self.details = read
                    self.render(read)
                    self.files.reloadData()
                    self.showTotals()
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Into the file list (↩ in the commit list), on its first file.
    func focusFiles() {
        guard let count = details?.files.count, count > 0 else { return }
        if files.selectedRow < 0 { files.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        window?.makeFirstResponder(files)
    }

    func openFile(at index: Int) {
        guard let details, let file = details.files[safe: index] else { return NSSound.beep() }
        onOpenFile?(file, details)
    }

    // MARK: text

    private func render(_ details: CommitDetails) {
        textView.textStorage?.setAttributedString(Self.describe(details))
        textView.scroll(.zero)
    }

    private static let labelWidth: CGFloat = 74

    /// The message, then a label and a value per line: author, committer (when someone else), id, parents, refs.
    static func describe(_ details: CommitDetails) -> NSAttributedString {
        let commit = details.commit
        let out = NSMutableAttributedString()
        let subject = NSMutableParagraphStyle()
        subject.paragraphSpacing = 6
        out.append(NSAttributedString(string: commit.subject + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Theme.text, .paragraphStyle: subject,
        ]))
        if !details.body.isEmpty {
            let body = NSMutableParagraphStyle()
            body.paragraphSpacing = 4
            out.append(NSAttributedString(string: details.body + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.terminalForeground, .paragraphStyle: body,
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))

        let rows = NSMutableParagraphStyle()
        rows.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth)]
        rows.headIndent = labelWidth
        rows.paragraphSpacing = 5
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim, .paragraphStyle: rows]
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.text, .paragraphStyle: rows]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.text, .paragraphStyle: rows]
        func line(_ name: String, _ parts: [NSAttributedString]) {
            out.append(NSAttributedString(string: name + "\t", attributes: label))
            parts.forEach(out.append)
            out.append(NSAttributedString(string: "\n", attributes: value))
        }
        func link(_ text: String, _ url: String, mono isMono: Bool = true) -> NSAttributedString {
            var attributes = isMono ? mono : value
            attributes[.link] = URL(string: url)
            return NSAttributedString(string: text, attributes: attributes)
        }
        func when(_ date: Date) -> String {
            let age = Date().timeIntervalSince(date)
            let absolute = GitLogStyle.fullDate(date)
            return age >= 0 && age < 7 * 86_400 ? "\(absolute) (\(GitLogStyle.dateText(date).lowercased()))" : absolute
        }
        line("Author", [NSAttributedString(string: "\(commit.authorName) <\(commit.authorEmail)>\n\t" + when(commit.authorDate), attributes: value)])
        let sameCommitter = commit.committerName == commit.authorName && commit.committerEmail == commit.authorEmail
        if !sameCommitter || abs(commit.committerDate.timeIntervalSince(commit.authorDate)) > 60 {
            line("Committer", [NSAttributedString(string: "\(commit.committerName) <\(commit.committerEmail)>\n\t" + when(commit.committerDate), attributes: value)])
        }
        line("Commit", [NSAttributedString(string: commit.sha + "  ", attributes: mono), link("Copy", "nextterm-copy:" + commit.sha, mono: false)])
        if commit.parents.isEmpty {
            line("Parents", [NSAttributedString(string: "None: the first commit", attributes: value)])
        } else {
            var parts: [NSAttributedString] = []
            for (index, parent) in commit.parents.enumerated() {
                if index > 0 { parts.append(NSAttributedString(string: "  ", attributes: mono)) }
                parts.append(link(String(parent.prefix(7)), "nextterm-commit:" + parent))
            }
            line(commit.parents.count > 1 ? "Parents" : "Parent", parts)
        }
        let refs = GitLogStyle.ordered(commit.refs).filter { $0.kind != .other }
        if !refs.isEmpty {
            var parts: [NSAttributedString] = []
            for (index, ref) in refs.enumerated() {
                if index > 0 { parts.append(NSAttributedString(string: ", ", attributes: value)) }
                var attributes = value
                attributes[.foregroundColor] = GitLogStyle.badge(ref)
                parts.append(NSAttributedString(string: (ref.isCurrent ? "HEAD → " : "") + ref.name, attributes: attributes))
            }
            line(refs.count == 1 ? "Ref" : "Refs", parts)
        }
        return out
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let text = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if text.hasPrefix("nextterm-copy:") {
            let sha = String(text.dropFirst("nextterm-copy:".count))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sha, forType: .string)
            GitToast.show("Copied \(sha.prefix(7))", in: window)
            return true
        }
        if text.hasPrefix("nextterm-commit:") {
            onSelectCommit?(String(text.dropFirst("nextterm-commit:".count)))
            return true
        }
        return false
    }

    // MARK: files

    private func showTotals() {
        guard let details else { return }
        let totals = details.totals
        let header = NSMutableAttributedString(string: "\(totals.files) file\(totals.files == 1 ? "" : "s") changed", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: Theme.text,
        ])
        if commitIsMerge { header.append(NSAttributedString(string: " (against the first parent)", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim])) }
        let counts: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)]
        if details.isCounted {
            header.append(Typography.gap(10, font: .systemFont(ofSize: 11.5)))
            header.append(NSAttributedString(string: "+\(totals.added)", attributes: counts.merging([.foregroundColor: Theme.linesAdded]) { $1 }))
            header.append(Typography.gap(6, font: .systemFont(ofSize: 11.5)))
            header.append(NSAttributedString(string: "−\(totals.removed)", attributes: counts.merging([.foregroundColor: Theme.linesRemoved]) { $1 }))
        } else {
            // A partial clone: the contents to count lines in are not downloaded.
            header.append(NSAttributedString(string: " · lines not counted", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim]))
        }
        if details.truncated {
            header.append(NSAttributedString(string: " · the first \(details.files.count.formatted()) shown", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim]))
        }
        // Git could not read the commit's trees (a treeless clone, offline): not the same as no files.
        let none = details.isListed ? "No files changed" : "Could not list the files"
        if totals.files == 0 { header.setAttributedString(NSAttributedString(string: none, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim])) }
        filesHeader.attributedStringValue = Typography.truncating(header, .byTruncatingTail)
    }

    private var commitIsMerge: Bool { details?.commit.isMerge ?? false }

    func numberOfRows(in tableView: NSTableView) -> Int { details?.files.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let file = details?.files[safe: row] else { return nil }
        let cell = tableView.makeView(withIdentifier: GitFileCell.identifier, owner: self) as? GitFileCell ?? GitFileCell()
        cell.show(file)
        return cell
    }

    @objc private func fileDoubleClicked() {
        guard files.clickedRow >= 0 else { return }
        openFile(at: files.clickedRow)
    }

    // MARK: layout

    private func build() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = self
        textView.linkTextAttributes = [.foregroundColor: Theme.gitModified, .cursor: NSCursor.pointingHand]
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.setAccessibilityLabel("Commit")
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = Theme.background

        filesHeader.font = .systemFont(ofSize: 11.5)
        filesHeader.textColor = Theme.textDim
        Typography.singleLine(filesHeader, truncation: .byTruncatingTail)
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        files.addTableColumn(column)
        files.headerView = nil
        files.style = .plain
        files.rowHeight = 22
        files.intercellSpacing = .zero
        files.backgroundColor = Theme.background
        files.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        files.dataSource = self
        files.delegate = self
        files.target = self
        files.doubleAction = #selector(fileDoubleClicked)
        files.onReturn = { [weak self] in
            guard let self else { return }
            self.openFile(at: self.files.selectedRow)
        }
        files.setAccessibilityLabel("Changed files")
        filesScroll.documentView = files
        filesScroll.hasVerticalScroller = true
        filesScroll.autohidesScrollers = true
        filesScroll.drawsBackground = true
        filesScroll.backgroundColor = Theme.background

        let lower = NSView()
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = WorkSplitView.line
        for view in [rule, filesHeader, filesScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            lower.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: lower.topAnchor),
            rule.leadingAnchor.constraint(equalTo: lower.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: lower.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            filesHeader.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 7),
            filesHeader.leadingAnchor.constraint(equalTo: lower.leadingAnchor, constant: 12),
            filesHeader.trailingAnchor.constraint(equalTo: lower.trailingAnchor, constant: -12),
            filesScroll.topAnchor.constraint(equalTo: filesHeader.bottomAnchor, constant: 5),
            filesScroll.leadingAnchor.constraint(equalTo: lower.leadingAnchor),
            filesScroll.trailingAnchor.constraint(equalTo: lower.trailingAnchor),
            filesScroll.bottomAnchor.constraint(equalTo: lower.bottomAnchor),
            lower.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(textScroll)
        split.addArrangedSubview(lower)

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = Theme.textDim
        empty.alignment = .center
        for view in [split, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private var placedDivider = false

    override func layout() {
        super.layout()
        // The message gets the upper part, the files the rest, the first time there is room.
        if !placedDivider, split.bounds.height > 200 {
            placedDivider = true
            split.setPosition(round(split.bounds.height * 0.45), ofDividerAt: 0)
        }
    }
}

/// A changed file: its status letter, its name and folder, and its lines added and removed.
final class GitFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GitFile")
    private let status = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        status.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        status.alignment = .center
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        Typography.singleLine(counts, truncation: .byTruncatingHead)
        counts.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [status, name, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            status.widthAnchor.constraint(equalToConstant: 14),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -8),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func color(_ status: ChangedFile.Status) -> NSColor {
        switch status {
        case .added, .copied: return Theme.gitAdded
        case .deleted: return Theme.linesRemoved
        case .unmerged: return Theme.gitConflicted
        case .modified, .renamed: return Theme.gitModified
        case .typeChanged, .unknown: return Theme.textDim
        }
    }

    func show(_ file: ChangedFile) {
        status.stringValue = file.status.rawValue
        status.textColor = Self.color(file.status)
        let folder = (file.path as NSString).deletingLastPathComponent
        let text = NSMutableAttributedString(string: (file.path as NSString).lastPathComponent, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: file.status == .deleted ? Theme.textDim : Theme.text,
        ])
        if !folder.isEmpty {
            text.append(Typography.gap(6, font: .systemFont(ofSize: 11)))
            text.append(NSAttributedString(string: folder, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim]))
        }
        if let old = file.oldPath {
            text.append(NSAttributedString(string: "  ← " + old, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim]))
        }
        name.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        let numbers = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        if file.isBinary {
            numbers.append(NSAttributedString(string: "binary", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim]))
        } else {
            if let added = file.added, added > 0 { numbers.append(NSAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.linesAdded])) }
            if let removed = file.removed, removed > 0 {
                if numbers.length > 0 { numbers.append(NSAttributedString(string: " ", attributes: [.font: font])) }
                numbers.append(NSAttributedString(string: "−\(removed)", attributes: [.font: font, .foregroundColor: Theme.linesRemoved]))
            }
        }
        counts.attributedStringValue = numbers
        let what = ["A": "added", "M": "modified", "D": "deleted", "R": "renamed", "C": "copied", "T": "type changed", "U": "unmerged"][file.status.rawValue] ?? "changed"
        toolTip = file.oldPath.map { "\(file.path), renamed from \($0)" } ?? file.path
        setAccessibilityLabel("\(file.path), \(what)" + (file.isBinary ? ", binary" : ", \(file.added ?? 0) added, \(file.removed ?? 0) removed"))
    }
}
