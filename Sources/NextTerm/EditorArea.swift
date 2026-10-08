import AppKit
import NextTermCore

protocol EditorAreaDelegate: AnyObject {
    /// The area showed (its first tab opened) or hid (its last one closed): it does that itself, and the
    /// window makes room for it or gives the room back.
    func editorAreaDidShowOrHide(_ area: EditorArea)
    /// The selection moved, or another file came to the front.
    func editorAreaSelectionChanged(_ area: EditorArea)
}

/// Open files above the terminal, one tab each, like an IDE's editor area.
final class EditorArea: NSView, TabBarViewDelegate {
    weak var delegate: EditorAreaDelegate?
    /// A change mark in an editor's gutter was clicked: show that file's changes.
    var onShowChanges: ((URL) -> Void)?
    let tabBar = TabBarView(frame: .zero)
    private let container = NSView()
    private let banner = EditorBanner()
    private var bannerHeight: NSLayoutConstraint!
    /// Tabs in order: files being edited (CodeEditorView), diffs (DiffPane), notebooks (NotebookPane),
    /// SQLite files (DatabasePane), large data files (DataPane), commit histories (GitLogPane) and
    /// branch comparisons (BranchComparePane).
    private(set) var panes: [NSView] = []
    /// The 5-second recheck of the open file's committed text (off in the self-test, to prove that a
    /// commit is noticed on its own).
    var periodicBaselineChecks = true
    private(set) var activeIndex = 0
    /// The preview tab, if there is one: a file opened by a single click in the project sidebar, which the
    /// next file clicked replaces in place. Editing it, double-clicking or dragging its tab, or opening the
    /// file another way keeps it as an ordinary tab, so a preview never has unsaved changes.
    private(set) weak var previewPane: NSView?

    var editors: [CodeEditorView] { panes.compactMap { $0 as? CodeEditorView } }
    var diffs: [DiffPane] { panes.compactMap { $0 as? DiffPane } }
    var notebooks: [NotebookPane] { panes.compactMap { $0 as? NotebookPane } }
    var databases: [DatabasePane] { panes.compactMap { $0 as? DatabasePane } }
    var dataFiles: [DataPane] { panes.compactMap { $0 as? DataPane } }
    var gitLogs: [GitLogPane] { panes.compactMap { $0 as? GitLogPane } }
    var comparisons: [BranchComparePane] { panes.compactMap { $0 as? BranchComparePane } }
    var activePane: NSView? { panes[safe: activeIndex] }
    var activeEditor: CodeEditorView? { activePane as? CodeEditorView }
    var activeDiff: DiffPane? { activePane as? DiffPane }
    var activeNotebook: NotebookPane? { activePane as? NotebookPane }
    var activeDatabase: DatabasePane? { activePane as? DatabasePane }
    var activeData: DataPane? { activePane as? DataPane }
    var activeGitLog: GitLogPane? { activePane as? GitLogPane }
    var activeComparison: BranchComparePane? { activePane as? BranchComparePane }
    /// Send to Agent was clicked in a SQLite viewer.
    var onSendToAgent: (([ContextItem]) -> Void)?
    /// The file in front: the one being edited, the notebook, database or data file being read, or the
    /// file whose diff is shown.
    var activePath: String? {
        activeEditor?.document.path ?? activeNotebook?.path ?? activeDatabase?.path ?? activeData?.path ?? activeDiff?.absolutePath
    }
    var activeName: String? { activeEditor?.document.name ?? activeNotebook?.name ?? activeDatabase?.name ?? activeData?.name }

    /// The file a tab shows, as `activePath` has it for the tab in front; nil for the Git Log and branch
    /// comparisons, which are of a whole repository.
    func path(of pane: NSView) -> String? {
        if let editor = pane as? CodeEditorView { return editor.document.path }
        if let notebook = pane as? NotebookPane { return notebook.path }
        if let database = pane as? DatabasePane { return database.path }
        if let data = pane as? DataPane { return data.path }
        return (pane as? DiffPane)?.absolutePath
    }
    /// Where its text is, for a selection to search for.
    var activeTextView: NSTextView? { activeEditor?.textView ?? activeNotebook?.textView }
    var documents: [EditorDocument] { editors.map(\.document) }
    var dirtyDocuments: [EditorDocument] { documents.filter(\.isDirty) }
    var isEmpty: Bool { panes.isEmpty }

    /// Shown exactly while a tab is open, whoever sets it. A split view shows a hidden pane by itself when
    /// its divider is dragged, and an editor area with no tabs must never show: an empty space beside the
    /// terminal, with a bar that has nothing in it.
    override var isHidden: Bool {
        get { super.isHidden }
        set { super.isHidden = panes.isEmpty }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true // nothing open yet
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        tabBar.allowsNewTab = false
        tabBar.allowsRename = false
        tabBar.kind = "file"
        tabBar.delegate = self
        for view in [tabBar, banner, container] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            banner.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,
            container.topAnchor.constraint(equalTo: banner.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        banner.onReload = { [weak self] in self?.resolveConflict(keepMine: false) }
        banner.onKeep = { [weak self] in self?.resolveConflict(keepMine: true) }
        banner.onClose = { [weak self] in
            guard let self, let editor = self.activeEditor else { return }
            self.remove(editor)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: opening

    enum OpenResult { case opened, notText, tooLarge, failed }

    /// Opens a file (or shows it if open), optionally at a line. Binary files are not opened.
    /// A notebook opens read-only as cells, unless asked for as text or at a line (a search result points
    /// into its JSON). A data file over 2 MB, and any text file too large for the editor, opens in the
    /// head view: its first rows, read-only. `preview` (a single click in the sidebar) opens it in the
    /// preview tab; opening a preview's file any other way keeps it.
    @discardableResult
    func open(_ url: URL, line: Int? = nil, column: Int = 1, focus: Bool = true, asText: Bool = false, preview: Bool = false) -> OpenResult {
        let path = canonicalPath(url.path)
        if !asText, line == nil, Notebook.isNotebook(path) { return openNotebook(path, focus: focus, preview: preview) }
        if !asText, DatabasePane.opens(path) { return openDatabase(path, focus: focus, preview: preview) }
        if !asText, line == nil, DataPane.opens(path) { return openData(path, focus: focus, preview: preview) }
        if let index = panes.firstIndex(where: { ($0 as? CodeEditorView)?.document.path == path }),
           let editor = panes[index] as? CodeEditorView {
            show(index, focus: focus, preview: preview)
            if let line { editor.textView.go(toLine: line, column: column) }
            return .opened
        }
        let document: EditorDocument
        do {
            document = try EditorDocument(url: url) // it resolves links itself, and keeps the name it was opened by
        } catch EditorDocument.OpenError.notText {
            return .notText
        } catch EditorDocument.OpenError.tooLarge {
            // Its first rows instead of another app, when it is UTF-8 text (not a PDF with no NUL early on).
            if !asText, DataHead.isUTF8Text(path) { return openData(path, focus: focus, preview: preview) }
            return .tooLarge
        } catch {
            return .failed
        }
        let editor = CodeEditorView(document: document)
        document.onChange = { [weak self, weak editor] document in
            guard let self else { return }
            // The first edit keeps a preview, before anything is saved: replacing one never loses work.
            if document.isDirty, let editor, editor === self.previewPane { self.previewPane = nil }
            self.refresh()
        }
        editor.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.delegate?.editorAreaSelectionChanged(self)
        }
        editor.onChangeMarkClick = { [weak self, weak document] _ in
            guard let self, let document else { return }
            self.onShowChanges?(document.url)
        }
        add(editor, preview: preview)
        select(activeIndex, focus: focus)
        container.layoutSubtreeIfNeeded()
        editor.textView.go(toLine: line ?? 1, column: line == nil ? 1 : column)
        editor.refreshBaseline()
        return .opened
    }

    /// A notebook's cells, read-only. Its size limit is the notebook reader's (50 MB), not the editor's:
    /// most of a big notebook is images and outputs, which it never lays out as text.
    private func openNotebook(_ path: String, focus: Bool, preview: Bool) -> OpenResult {
        if let index = panes.firstIndex(where: { ($0 as? NotebookPane)?.path == path }) {
            show(index, focus: focus, preview: preview)
            return .opened
        }
        guard isRegularFile(path) else { return .notText } // a named pipe would block forever
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= Notebook.maxFileSize else { return .tooLarge }
        let pane = NotebookPane(url: URL(fileURLWithPath: path))
        pane.onTitleChange = { [weak self] in self?.refresh() }
        pane.onOpenAsJSON = { [weak self] url in self?.openAsText(url) }
        add(pane, preview: preview)
        select(activeIndex, focus: focus)
        return .opened
    }

    /// A SQLite file, read-only, in its own tab (or brought to the front if it is open).
    @discardableResult
    func openDatabase(_ path: String, focus: Bool = true, preview: Bool = false) -> OpenResult {
        let path = canonicalPath(path)
        if let index = panes.firstIndex(where: { ($0 as? DatabasePane)?.path == path }) {
            show(index, focus: focus, preview: preview)
            return .opened
        }
        guard Databases.isSQLiteFile(path) || DatabasePane.isEmptyFile(path) else { return .notText }
        let pane = DatabasePane(url: URL(fileURLWithPath: path))
        pane.onTitleChange = { [weak self] in self?.refresh() }
        pane.onSendToAgent = { [weak self] items in self?.onSendToAgent?(items) }
        add(pane, preview: preview)
        select(activeIndex, focus: focus)
        return .opened
    }

    /// A large data file's first rows, read-only, in its own tab (or brought to the front if it is open).
    @discardableResult
    func openData(_ path: String, focus: Bool = true, preview: Bool = false) -> OpenResult {
        let path = canonicalPath(path)
        if let index = panes.firstIndex(where: { ($0 as? DataPane)?.path == path }) {
            show(index, focus: focus, preview: preview)
            return .opened
        }
        guard isRegularFile(path) else { return .notText } // a named pipe would block forever
        let pane = DataPane(url: URL(fileURLWithPath: path))
        pane.onTitleChange = { [weak self] in self?.refresh() }
        pane.onOpenInEditor = { [weak self] url in self?.openAsText(url) }
        add(pane, preview: preview)
        select(activeIndex, focus: focus)
        return .opened
    }

    /// Open as JSON, from a notebook, or Open in Editor, from a data file: its file in the editor, beside it.
    func openAsText(_ url: URL) {
        switch open(url, asText: true) {
        case .opened:
            break
        case .tooLarge:
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is too large to open as text"
            alert.informativeText = "The editor opens files up to \(TextFile.maxEditableSize / 1024 / 1024) MB."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        case .notText, .failed:
            NSSound.beep()
        }
    }

    /// Adds a tab next to the current one, filling the content area.
    private func insert(_ pane: NSView) {
        fill(pane)
        let insertAt = panes.isEmpty ? 0 : activeIndex + 1
        panes.insert(pane, at: insertAt)
        activeIndex = insertAt
        tabsChanged()
    }

    private func fill(_ pane: NSView) {
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: container.topAnchor),
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// A new tab. A preview takes the place of the one before it, at the same position in the tab bar;
    /// anything else goes next to the current tab.
    private func add(_ pane: NSView, preview: Bool) {
        if preview, let old = previewPane, (old as? CodeEditorView)?.document.isDirty != true,
           let index = panes.firstIndex(where: { $0 === old }) {
            // Not through remove(): closing the only tab would hide the editor area on the way.
            fill(pane)
            panes[index] = pane
            activeIndex = index
            discard(old)
        } else {
            insert(pane)
        }
        if preview { previewPane = pane }
    }

    /// Brings an open tab to the front. Opening a preview's file any way but a single click keeps it.
    private func show(_ index: Int, focus: Bool, preview: Bool) {
        if !preview, panes[index] === previewPane { previewPane = nil }
        select(index, focus: focus)
    }

    /// The preview becomes an ordinary tab (its tab was double-clicked, or single clicks were turned off).
    func keepPreview() {
        guard previewPane != nil else { return }
        previewPane = nil
        refresh()
    }

    /// Every tab opened or closed ends here: the bar gets one tab per pane, then the area shows while there
    /// is one and hides when there is none, telling the delegate when that changes.
    private func tabsChanged() {
        refresh()
        let wasHidden = isHidden
        isHidden = panes.isEmpty
        if isHidden != wasHidden { delegate?.editorAreaDidShowOrHide(self) }
    }

    func select(_ index: Int, focus: Bool = true) {
        guard panes.indices.contains(index) else { return }
        activeIndex = index
        for (i, pane) in panes.enumerated() { pane.isHidden = i != index }
        if let editor = panes[index] as? CodeEditorView {
            editor.document.lastFocused = Date()
            editor.refreshBlameIfStale()
            if focus { window?.makeFirstResponder(editor.textView) }
        } else if let diff = panes[index] as? DiffPane, focus {
            window?.makeFirstResponder(diff.focusView)
        } else if let notebook = panes[index] as? NotebookPane, focus {
            window?.makeFirstResponder(notebook.textView)
        } else if let database = panes[index] as? DatabasePane, focus {
            window?.makeFirstResponder(database.focusView)
        } else if let data = panes[index] as? DataPane, focus {
            window?.makeFirstResponder(data.focusView)
        } else if let log = panes[index] as? GitLogPane, focus {
            window?.makeFirstResponder(log.focusView)
        } else if let comparison = panes[index] as? BranchComparePane, focus {
            window?.makeFirstResponder(comparison.focusView)
        }
        refresh()
        delegate?.editorAreaSelectionChanged(self)
    }

    func cycle(by delta: Int) {
        guard !panes.isEmpty else { return }
        select((activeIndex + delta + panes.count) % panes.count)
    }

    // MARK: diffs

    /// An agent's proposed edit, to accept or reject. Closing its tab rejects it.
    @discardableResult
    func openProposal(for path: String, proposal: DiffPane.Proposal, onDecision: @escaping (Bool, String) -> Void) -> DiffPane {
        let pane = DiffPane(proposalFor: path, proposal: proposal)
        pane.onDecision = onDecision
        pane.onTitleChange = { [weak self] in self?.refresh() }
        insert(pane)
        select(activeIndex)
        return pane
    }

    var proposals: [DiffPane] { diffs.filter { $0.proposal != nil } }

    /// Closes a tab without asking (a decided proposal, a diff).
    func close(_ pane: NSView) {
        if let editor = pane as? CodeEditorView { return requestClose(editor) }
        remove(pane)
    }

    /// Shows a file's changes (or brings its diff to the front, comparing against `base`).
    func openDiff(root: String, path: String, base: GitRunner.DiffBase = .head) {
        if let index = panes.firstIndex(where: { ($0 as? DiffPane)?.matches(root: root, path: path) == true }),
           let diff = panes[index] as? DiffPane {
            diff.base = base
            select(index)
            return
        }
        let diff = DiffPane(root: root, path: path, base: base)
        diff.onTitleChange = { [weak self] in self?.refresh() }
        insert(diff)
        select(activeIndex)
    }

    /// A file as one commit changed it, read-only (or brings that diff to the front).
    func openCommitDiff(root: String, path: String, change: DiffPane.CommitChange) {
        if let index = panes.firstIndex(where: { ($0 as? DiffPane)?.matches(root: root, path: path, commit: change.sha) == true }) {
            return select(index)
        }
        let diff = DiffPane(root: root, path: path, commit: change)
        diff.onTitleChange = { [weak self] in self?.refresh() }
        insert(diff)
        select(activeIndex)
    }

    /// A file as `change.branch` changed it since it parted from HEAD, read-only (or brings that diff to the
    /// front, read again: the branch may have moved since it opened).
    func openBranchDiff(root: String, path: String, change: DiffPane.BranchChange) {
        if let index = panes.firstIndex(where: { ($0 as? DiffPane)?.matches(root: root, path: path, branch: change.branch) == true }),
           let diff = panes[index] as? DiffPane {
            diff.reopen(change)
            return select(index)
        }
        let diff = DiffPane(root: root, path: path, branchChange: change)
        diff.onTitleChange = { [weak self] in self?.refresh() }
        insert(diff)
        select(activeIndex)
    }

    /// A file on disk against its version on `branch` (or brings that diff to the front, read again: the
    /// branch may have moved since it opened).
    func openWorkingTreeDiff(root: String, path: String, branch: String, renamedFrom: String?) {
        if let index = panes.firstIndex(where: { ($0 as? DiffPane)?.matches(root: root, path: path, workingTreeAgainst: branch) == true }),
           let diff = panes[index] as? DiffPane {
            diff.reopen(renamedFrom: renamedFrom)
            return select(index)
        }
        let diff = DiffPane(root: root, path: path, workingTreeAgainst: branch, renamedFrom: renamedFrom)
        diff.onTitleChange = { [weak self] in self?.refresh() }
        insert(diff)
        select(activeIndex)
    }

    // MARK: history

    /// The commit history of the repository whose top folder is `root` (or brings its tab to the front).
    @discardableResult
    func openGitLog(root: String) -> GitLogPane {
        if let index = panes.firstIndex(where: { ($0 as? GitLogPane)?.root == root }), let log = panes[index] as? GitLogPane {
            select(index)
            return log
        }
        let log = GitLogPane(root: root)
        log.onTitleChange = { [weak self] in self?.refresh() }
        log.onOpenChange = { [weak self] path, change in self?.openCommitDiff(root: root, path: path, change: change) }
        insert(log)
        select(activeIndex)
        return log
    }

    /// Compare with Current or Show Diff with Working Tree for `branch` ("refs/heads/feat/x") of the work
    /// tree at `root` (or brings that tab to the front, reading it again). `current` names what is
    /// checked out until the tab has read it.
    @discardableResult
    func openBranchComparison(root: String, branch: String, mode: BranchComparePane.Mode, current: String?) -> BranchComparePane {
        if let index = panes.firstIndex(where: { ($0 as? BranchComparePane)?.matches(root: root, branch: branch, mode: mode) == true }),
           let pane = panes[index] as? BranchComparePane {
            select(index)
            pane.reload()
            return pane
        }
        let pane = BranchComparePane(root: root, branch: branch, mode: mode, current: current)
        pane.onTitleChange = { [weak self] in self?.refresh() }
        pane.onOpenFile = { [weak self, weak pane] file in
            guard let self else { return }
            switch mode {
            case .compare:
                // Files are listed only when there is a merge base: the diff starts from it too.
                guard let base = pane?.comparison?.mergeBase else { return }
                self.openBranchDiff(root: root, path: file.path, change: DiffPane.BranchChange(branch: branch, oldPath: file.oldPath, base: base))
            case .workingTree: self.openWorkingTreeDiff(root: root, path: file.path, branch: branch, renamedFrom: file.oldPath)
            }
        }
        insert(pane)
        select(activeIndex)
        return pane
    }

    // MARK: closing

    /// Closes an editor, asking to save first if it has unsaved changes.
    func requestClose(_ editor: CodeEditorView) {
        guard editor.document.isDirty, let window else { return remove(editor) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(editor.document.name)”?"
        alert.informativeText = "Your changes are lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save(editor.document) { self.remove(editor) }
            case .alertThirdButtonReturn:
                self.remove(editor)
            default:
                break
            }
        }
    }

    func closeActive() {
        if let editor = activeEditor { requestClose(editor) } else if let pane = activePane { remove(pane) }
    }

    private func remove(_ pane: NSView) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        (pane as? DiffPane)?.decide(false) // closing an undecided proposal rejects it
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: pane) == true
        if pane === previewPane { previewPane = nil }
        discard(pane)
        panes.remove(at: index)
        if index <= activeIndex { activeIndex = max(0, activeIndex - 1) }
        tabsChanged()
        if panes.isEmpty {
            delegate?.editorAreaSelectionChanged(self)
            return
        }
        select(activeIndex, focus: hadFocus)
    }

    /// Close Others and Close Tabs to the Right: several tabs at once, asking once about the unsaved files
    /// among them (Save, Cancel or Don't Save, as closing one asks). `keeping` comes to the front if the tab
    /// in front was among them.
    func close(_ closing: [NSView], keeping: NSView) {
        let front = activePane
        let done = { [weak self] in
            guard let self else { return }
            closing.forEach(self.remove)
            if let front, closing.contains(where: { $0 === front }), let index = self.panes.firstIndex(where: { $0 === keeping }) {
                self.select(index)
            }
        }
        let dirty = closing.compactMap { ($0 as? CodeEditorView)?.document }.filter(\.isDirty)
        guard !dirty.isEmpty, let window else { return done() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].name)” before closing?" : "Save changes to \(dirty.count) files before closing?"
        alert.informativeText = dirty.count == 1 ? "Your changes are lost if you don’t save them."
            : "Your changes to \(TerminalWindowController.nameList(dirty.map(\.name))) are lost if you don’t save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // A file that could not be saved says why, and nothing closes.
                if dirty.allSatisfy({ self.save($0) }) { done() }
            case .alertThirdButtonReturn:
                done()
            default:
                break
            }
        }
    }

    /// Closes every editor without asking (the window is closing and the user already chose).
    func closeAll() {
        for pane in panes { remove(pane) }
    }

    /// Takes a closed tab's view away, and its editor's layout off the document's text.
    private func discard(_ pane: NSView) {
        pane.removeFromSuperview()
        if let editor = pane as? CodeEditorView {
            editor.document.storage.layoutManagers.forEach { editor.document.storage.removeLayoutManager($0) }
        }
    }

    // MARK: saving

    /// Saves; on failure says why and returns false.
    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.save()
            editors.first { $0.document === document }?.refreshBaseline()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "“\(document.name)” could not be saved."
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
    }

    func saveActive() {
        guard let document = activeEditor?.document else { return NSSound.beep() }
        save(document)
    }

    /// Saves every file with changes. False if any could not be saved.
    @discardableResult
    func saveAll() -> Bool {
        dirtyDocuments.allSatisfy { save($0) }
    }

    // MARK: disk changes

    /// Picks up changes other programs (agents, git) made to open files. Called about once a second.
    func checkDisk() {
        for editor in editors { editor.document.checkDisk() }
        for diff in diffs { diff.refreshIfChanged() }
        for notebook in notebooks { notebook.refreshIfChanged() }
        for database in databases { database.refreshIfChanged() }
        for data in dataFiles { data.refreshIfChanged() }
        // The file being edited against the last commit: a commit (yours or an agent's) moves the marks.
        checks += 1
        if periodicBaselineChecks, checks % 5 == 0 { activeEditor?.refreshBaseline() }
    }

    private var checks = 0

    private func resolveConflict(keepMine: Bool) {
        guard let document = activeEditor?.document else { return }
        if keepMine { document.keepMine() } else if !document.reload() { NSSound.beep() }
        refresh()
    }

    /// A file or folder was renamed or moved in the sidebar: open editors follow it.
    func itemMoved(from old: String, to new: String) {
        for document in documents {
            if document.path == old {
                document.moved(to: URL(fileURLWithPath: new))
            } else if document.path.hasPrefix(old + "/") {
                document.moved(to: URL(fileURLWithPath: new + document.path.dropFirst(old.count)))
            }
        }
        for notebook in notebooks {
            if notebook.path == old {
                notebook.moved(to: URL(fileURLWithPath: new))
            } else if notebook.path.hasPrefix(old + "/") {
                notebook.moved(to: URL(fileURLWithPath: new + notebook.path.dropFirst(old.count)))
            }
        }
        for database in databases {
            if database.path == old {
                database.moved(to: URL(fileURLWithPath: new))
            } else if database.path.hasPrefix(old + "/") {
                database.moved(to: URL(fileURLWithPath: new + database.path.dropFirst(old.count)))
            }
        }
        for data in dataFiles {
            if data.path == old {
                data.moved(to: URL(fileURLWithPath: new))
            } else if data.path.hasPrefix(old + "/") {
                data.moved(to: URL(fileURLWithPath: new + data.path.dropFirst(old.count)))
            }
        }
        // A new name can make a file a .env file, whose values may be hidden, or stop it being one.
        editors.forEach { $0.textView.needsDisplay = true }
        refresh()
    }

    // MARK: display

    func refresh() {
        // Same name twice: add the folder, as editors do (a notebook open as JSON too is the same file).
        let paths = Set(documents.map(\.path) + notebooks.map(\.path) + dataFiles.map(\.path))
        let names = Dictionary(grouping: paths, by: { ($0 as NSString).lastPathComponent })
        func title(_ url: URL) -> String {
            let name = url.lastPathComponent
            return (names[name]?.count ?? 0) > 1 ? name + " — " + url.deletingLastPathComponent().lastPathComponent : name
        }
        var items = panes.map { pane -> TabBarItem in
            if let diff = pane as? DiffPane {
                return TabBarItem(title: diff.title, state: .idle, tooltip: diff.tooltip, accessibilityStatus: "changes",
                                  icon: FileIcons.icon(for: URL(fileURLWithPath: diff.absolutePath), size: 16), modified: false)
            }
            if let log = pane as? GitLogPane {
                // Two repositories' logs: each says whose.
                let named = gitLogs.count > 1 ? log.title + " — " + (log.root as NSString).lastPathComponent : log.title
                return TabBarItem(title: named, state: .idle, tooltip: log.tooltip, accessibilityStatus: "commit history", icon: GitLogPane.tabIcon, modified: false)
            }
            if let comparison = pane as? BranchComparePane {
                return TabBarItem(title: comparison.title, state: .idle, tooltip: comparison.tooltip, accessibilityStatus: "branch comparison",
                                  icon: BranchComparePane.tabIcon, modified: false)
            }
            if let notebook = pane as? NotebookPane {
                return TabBarItem(title: title(notebook.url), state: .idle, tooltip: RecentProjects.abbreviate(notebook.path) + " (notebook, read-only)",
                                  accessibilityStatus: "notebook, read-only", icon: FileIcons.icon(for: notebook.url, size: 16), modified: false)
            }
            if let database = pane as? DatabasePane {
                return TabBarItem(title: database.name, state: .idle, tooltip: RecentProjects.abbreviate(database.path) + " (SQLite, read-only)",
                                  accessibilityStatus: "database, read-only", icon: FileIcons.icon(for: database.url, size: 16), modified: false)
            }
            if let data = pane as? DataPane {
                return TabBarItem(title: title(data.url), state: .idle, tooltip: RecentProjects.abbreviate(data.path) + " (first rows, read-only)",
                                  accessibilityStatus: "data file, read-only", icon: FileIcons.icon(for: data.url, size: 16), modified: false)
            }
            let document = (pane as! CodeEditorView).document
            let status = document.isDirty ? "unsaved changes" : "saved"
            // A notebook open as JSON gets JSON's icon, to tell it from the notebook's own tab.
            let icon = FileIcons.icon(for: Notebook.isNotebook(document.path) ? document.url.deletingPathExtension().appendingPathExtension("json") : document.url, size: 16)
            return TabBarItem(title: title(document.url), state: .idle, tooltip: RecentProjects.abbreviate(document.path),
                              accessibilityStatus: status, icon: icon, modified: document.isDirty)
        }
        if let preview = previewPane, let index = panes.firstIndex(where: { $0 === preview }) {
            items[index].preview = true
            items[index].tooltip += "\nPreview: the next file you click takes this tab. Edit the file or double-click the tab to keep it."
            items[index].accessibilityStatus += ", preview"
        }
        tabBar.update(items: items, selectedIndex: activeIndex)
        let conflict = activeEditor?.document.conflict
        banner.show(conflict, name: activeEditor?.document.name ?? "")
        bannerHeight.constant = conflict == nil ? 0 : EditorBanner.height
        window?.windowController.map { ($0 as? TerminalWindowController)?.updateTitle() }
    }

    func applyFont() {
        editors.forEach { $0.applyFont() }
        diffs.forEach { $0.applyFont() }
        notebooks.forEach { $0.applyFont() }
    }

    func applyWrap() {
        editors.forEach { $0.applyWrap() }
    }

    func applyEnvValuesSetting() {
        editors.forEach { $0.applyEnvValuesSetting() }
    }

    /// Blame was turned on or off (View menu); `announce` says when the file in front has none. Only
    /// the file in front is blamed now; the others when they come to the front.
    func applyBlame(announce: Bool = false) {
        editors.forEach { $0.applyBlame(announce: announce && $0 === activeEditor, now: $0 === activeEditor) }
    }

    /// A commit or a checkout: every open file's change marks follow at once. Blame is read now for the
    /// file in front only, and for the others when they come to the front.
    func headMoved() {
        editors.forEach { $0.refreshBaseline(blame: $0 === activeEditor) }
    }

    // MARK: TabBarViewDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index) }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        if let editor = panes[safe: index] as? CodeEditorView { requestClose(editor) } else if let pane = panes[safe: index] { remove(pane) }
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        guard panes.indices.contains(from), panes.indices.contains(to) else { return }
        if panes[from] === previewPane { previewPane = nil } // a preview dragged into place is kept
        let active = activePane
        panes.insert(panes.remove(at: from), at: to)
        activeIndex = active.flatMap { a in panes.firstIndex { $0 === a } } ?? 0
        refresh()
    }

    func tabBar(_ bar: TabBarView, didRename index: Int, to title: String?) {}
    func tabBarDidEndEditing(_ bar: TabBarView) {}
    func tabBarDidRequestNewTab(_ bar: TabBarView) {}

    /// Double-clicking a preview's tab keeps it.
    func tabBar(_ bar: TabBarView, didDoubleClick index: Int) {
        if let pane = panes[safe: index], pane === previewPane { keepPreview() }
    }

    /// The window builds it: some of its commands reach the project sidebar.
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? {
        (window?.windowController as? TerminalWindowController)?.editorTabMenu(at: index)
    }
}

/// "This file changed on disk" with what to do about it.
final class EditorBanner: NSView {
    static let height: CGFloat = 34
    private let label = NSTextField(labelWithString: "")
    private let reload = NSButton(title: "Reload from Disk", target: nil, action: nil)
    private let keep = NSButton(title: "Keep My Changes", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)
    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x3D3223).cgColor
        clipsToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text
        Typography.singleLine(label, truncation: .byTruncatingTail)
        for button in [reload, keep, close] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
        }
        reload.action = #selector(reloadClicked)
        keep.action = #selector(keepClicked)
        close.action = #selector(closeClicked)
        let stack = NSStackView(views: [label, NSView(), keep, close, reload])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ conflict: EditorDocument.Conflict?, name: String) {
        isHidden = conflict == nil
        switch conflict {
        case .changedOnDisk:
            label.stringValue = "“\(name)” changed on disk while you were editing it."
            reload.isHidden = false
            close.isHidden = true
        case .deletedOnDisk:
            label.stringValue = "“\(name)” was deleted or moved on disk."
            reload.isHidden = true
            close.isHidden = false
        case nil:
            break
        }
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeep?() }
    @objc private func closeClicked() { onClose?() }
}
