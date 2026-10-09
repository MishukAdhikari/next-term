import AppKit
import NextTermCore

/// Open in New Worktree… and Remove Worktree…: a branch, tag or commit checked out in a folder of its own,
/// opened in its own window, so the checkout an agent works in keeps its HEAD, its files and its changes;
/// and that folder removed again, never forced. The rules are in Core (Worktrees.swift).
/// Plan: claudedocs/2026-10-09-worktree-from-switch-guard-plan.md.
extension GitActions {
    /// The sheet for `target`'s folder name, then `git worktree add`, the ignored files `.worktreeinclude` lists,
    /// and the new folder's window in front. `update`: then forward to its upstream there (Checkout and Update).
    func openInNewWorktree(_ target: WorktreeTarget, update: Bool = false) {
        guard let model, let git = GitWriter.git else { return NSSound.beep() }
        let root = self.root
        let main = WorktreeFolder.mainCheckout(commonDir: model.commonDir)
        let location = AppDelegate.shared.worktreeLocation
        let listed = model.worktrees.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let ignored = location == .claudeWorktrees && WorktreeFolder.ignoresClaudeWorktrees(mainCheckout: main, git: git)
            let includes = WorktreeInclude.exists(in: root)
            DispatchQueue.main.async {
                let place = WorktreeFolder.place(mainCheckout: main, location: location, claudeWorktreesIgnored: ignored)
                askWorktreeName(target, place: place, listed: listed, includes: includes, update: update)
            }
        }
    }

    private func askWorktreeName(_ target: WorktreeTarget, place: WorktreeFolder.Place, listed: [String], includes: Bool, update: Bool) {
        let folder = canonicalPath(place.folder)
        func path(_ name: String) -> String { folder + "/" + name }
        /// A worktree git lists at that path (its folder may be gone).
        func isListed(_ name: String) -> Bool {
            listed.contains { canonicalPath($0) == path(name) || $0 == place.folder + "/" + name }
        }
        let taken = { (name: String) in WorktreeFolder.exists(path(name)) || isListed(name) }
        let prefill = WorktreeFolder.suggestedName(prefix: place.prefix, short: target.shortName, isTaken: taken)
        let checkout = ((model?.root ?? root) as NSString).lastPathComponent
        let sheet = WorktreeSheet(title: WorktreeFolder.sheetTitle(target), folder: folder, prefill: prefill, prefix: place.prefix,
                                  footnote: WorktreeFolder.sheetInfo(checkout: checkout, includes: includes)) { name in
            WorktreeFolder.problem(name, in: folder, isTaken: { WorktreeFolder.exists(path($0)) },
                                   isRegistered: { isListed($0) && !WorktreeFolder.exists(path($0)) })
        }
        sheet.present(over: window) { name, sheet in
            createWorktree(target, at: path(name), update: update, sheet: sheet)
        }
    }

    /// One `git worktree add` through GitWriter (logged in Git Commands), while the sheet says "Creating…".
    /// A worktree that is there after git failed (a post-checkout hook, LFS) opens anyway, with the error
    /// over its window; nothing is rolled back.
    private func createWorktree(_ target: WorktreeTarget, at path: String, update: Bool, sheet: WorktreeSheet) {
        let args = target.addArguments(path: path)
        let folder = (path as NSString).lastPathComponent
        let root = self.root
        let commonDir = model?.commonDir ?? root
        run("New worktree \(folder)", [args]) { result in
            let made = result.ok || Self.isWorktree(path, of: commonDir)
            guard made else {
                sheet.finish()
                return failed("Could not create “\(folder)”", result, retry: args)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let copied = Self.copyIncludes(from: root, to: path)
                DispatchQueue.main.async {
                    sheet.finish()
                    let opened = AppDelegate.shared.openWorktreeWindow(path)
                    guard result.ok else {
                        return failed("“\(folder)” was made, but git reported an error", result, retry: nil, over: opened.window)
                    }
                    let on = target.branchName.map { "on \($0)" } ?? "at \(target.shown), detached"
                    let notice = "New worktree \(on)" + Self.copiedNotice(copied)
                    if update, let branch = target.branchName { return fastForward(branch, in: path, repository: commonDir, over: opened, notice: notice) }
                    GitToast.show(notice, in: opened.window)
                }
            }
        }
    }

    /// Whether `path` is a worktree of the repository at `commonDir` (made, even if git then failed).
    private static func isWorktree(_ path: String, of commonDir: String) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isFolder), !isFolder.boolValue,
              let common = GitRunner.commonGitDir(root: path) else { return false }
        return canonicalPath(common) == canonicalPath(commonDir)
    }

    /// The ignored files `.worktreeinclude` lists, copied from the checkout the window shows. Off the main thread.
    private static func copyIncludes(from root: String, to path: String) -> [String] {
        guard let git = GitWriter.git, WorktreeInclude.exists(in: root) else { return [] }
        let files = WorktreeInclude.files(in: root, git: git)
        return WorktreeInclude.copy(files, from: root, to: path).copied
    }

    /// "; copied .env from .worktreeinclude", or "; copied 12 files from .worktreeinclude".
    private static func copiedNotice(_ copied: [String]) -> String {
        guard !copied.isEmpty else { return "" }
        let what = copied.count <= 2 ? copied.joined(separator: " and ") : "\(copied.count) files"
        return "; copied \(what) from \(WorktreeInclude.fileName)"
    }

    /// Checkout and Update in a new worktree: forward to its upstream there. On failure the worktree stays
    /// open, and the error shows over its window.
    private func fastForward(_ branch: String, in path: String, repository: String, over opened: TerminalWindowController, notice: String) {
        GitWriter.shared.run("Update \(branch)", in: path, repository: repository, steps: [BranchCommand.fastForward], activity: .pulling) { result in
            opened.sidebar.git.refresh()
            guard result.ok else { return failed("Could not bring “\(branch)” up to date", result, retry: BranchCommand.fastForward, over: opened.window) }
            GitToast.show(notice + (result.failure == .nothingToDo ? ", up to date" : ", updated"), in: opened.window)
        }
    }

    // MARK: Remove Worktree…

    /// Remove Worktree… on a worktree's row: refused while an agent, a window or a tab is in it, while a lock
    /// holds it, or while it has changes; a folder deleted by hand is forgotten, after asking.
    func removeWorktree(_ row: BranchPopupController.WorktreeRow) {
        guard let model, let git = GitWriter.git else { return NSSound.beep() }
        let w = row.worktree
        let main = WorktreeFolder.mainCheckout(commonDir: model.commonDir)
        var known = WorktreeRemoval.Facts(isMain: canonicalPath(w.path) == canonicalPath(main), isMissing: w.isPrunable,
                                          lockReason: w.lockReason, holder: row.holder, holderAlive: row.holderAlive)
        let inside = Self.inside(w, of: model)
        let local = AppDelegate.shared.controllers.flatMap { c in c.tabs.filter { $0.remote == nil }.map { (c, $0) } }
        let agents = local.filter { $0.1.status.running && $0.1.status.kind == .agent && inside(AgentPlaces.shared.agentFolder(of: $0.1)) }
        let windows = AppDelegate.shared.controllers.filter { $0.project.map(inside) ?? false }
        let tabs = local.filter { inside($0.1.liveDirectory) }
        known.agents = agents.map { AgentGuard.Agent(program: $0.1.status.program, tab: $0.1.title) }
        known.windows = windows.map(\.projectTitle)
        known.tabWindows = tabs.map { $0.0.projectTitle }
        let goTo: () -> Void = {
            if let place = agents.first ?? (windows.isEmpty ? tabs.first : nil) {
                place.0.show(place.1)
                place.0.window?.makeKeyAndOrderFront(nil)
            } else {
                windows.first?.window?.makeKeyAndOrderFront(nil)
            }
        }
        let facts = known
        DispatchQueue.global(qos: .userInitiated).async {
            var counted = facts
            if !w.isPrunable { counted.changedFiles = WorktreeRemoval.changedFiles(at: w.path, git: git) ?? 0 }
            let decided = WorktreeRemoval.verdict(counted)
            DispatchQueue.main.async { removal(decided, of: row, goTo: goTo) }
        }
    }

    /// Whether a folder is in `worktree` itself, not in a worktree nested inside it.
    private static func inside(_ worktree: Worktree, of model: BranchModel) -> (String) -> Bool {
        let path = canonicalPath(worktree.path)
        return { folder in model.worktree(containing: folder).map { canonicalPath($0.path) == path } ?? false }
    }

    private func removal(_ verdict: WorktreeRemoval.Verdict, of row: BranchPopupController.WorktreeRow, goTo: @escaping () -> Void) {
        let w = row.worktree, folder = row.folder
        switch verdict {
        case .remove:
            let keeps = w.branch.map { "The branch \($0) stays, with its commits." }
                ?? "It is detached at \(String((w.head ?? "").prefix(7))): a commit made there that no branch has is left to git’s reflog."
            GitPrompt.ask("Remove “\(folder)”?", info: "Its folder is deleted, with the ignored files in it. \(keeps)",
                          buttons: ["Remove", "Cancel"], destructive: 0, over: window) { choice in
                if choice == 0 { runRemoval(w, folder: folder, done: "Removed \(folder)" + (w.branch.map { "; \($0) stays" } ?? "")) }
            }
        case .forget:
            GitPrompt.ask("Forget “\(folder)”?", info: "Its folder is gone, but git still lists it\(w.branch.map { ", and keeps \($0) checked out there" } ?? ""). Forgetting it changes nothing on disk.",
                          buttons: ["Forget", "Cancel"], over: window) { choice in
                if choice == 0 { runRemoval(w, folder: folder, done: "Forgot \(folder)") }
            }
        case let .refuse(reason, there):
            let advice = there ? "\n\nClose it there first, then remove the worktree." : reason.hasPrefix("It has") ? "\n\nCommit or discard them there first: Remove Worktree never deletes changes." : ""
            GitPrompt.ask("“\(folder)” can’t be removed now", info: reason + advice, buttons: there ? ["Go There", "OK"] : ["OK"], over: window) { choice in
                if there, choice == 0 { goTo() }
            }
        case let .unlockFirst(reason):
            GitPrompt.ask("“\(folder)” is locked", info: reason + "\n\nA lock keeps git from removing a worktree. Unlock it first if whatever locked it is done with it, then remove it.",
                          buttons: [row.isStale ? "Unlock" : "Unlock…", "Cancel"], over: window) { choice in
                if choice == 0 { unlock(w, stale: row.isStale) }
            }
        }
    }

    private func runRemoval(_ w: Worktree, folder: String, done: String) {
        let args = WorktreeRemoval.arguments(path: w.path)
        run("Remove worktree \(folder)", [args]) { result in
            result.ok ? toast(done) : failed("Could not remove “\(folder)”", result, retry: args)
        }
    }
}

/// The sheet that names a new worktree's folder: one field, prefilled with its short part selected (typing
/// replaces only that), the full path under it as you type, the reason a name can't be used (Create is off
/// then), and the footnote. Create reads "Creating…" with a spinner while git works, and the sheet stays up
/// until `finish`.
final class WorktreeSheet: NSObject, NSTextFieldDelegate {
    /// The sheet up now, for the self-test.
    private(set) static var current: WorktreeSheet?

    private let alert = NSAlert()
    private let field = PrefixField()
    private let pathLine = NSTextField(labelWithString: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let create: NSButton
    private let cancel: NSButton
    private let folder: String
    private let prefix: String
    private let check: (String) -> String?
    private var onCreate: ((String, WorktreeSheet) -> Void)?
    private weak var parent: NSWindow?

    init(title: String, folder: String, prefill: String, prefix: String, footnote: String, check: @escaping (String) -> String?) {
        self.folder = folder
        self.prefix = prefix
        self.check = check
        alert.messageText = title
        alert.informativeText = ""
        create = alert.addButton(withTitle: "Create")
        cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        super.init()
        create.target = self
        create.action = #selector(createPressed)
        build(prefill: prefill, footnote: footnote)
        changed()
    }

    private func build(prefill: String, footnote: String) {
        let width: CGFloat = 380
        let label = NSTextField(labelWithString: "Folder name:")
        label.alignment = .right
        field.stringValue = prefill
        field.kept = (prefix as NSString).length
        field.delegate = self
        field.setAccessibilityLabel("Folder name")
        for small in [pathLine, problem] {
            small.font = .systemFont(ofSize: 11)
            small.textColor = .secondaryLabelColor
        }
        pathLine.lineBreakMode = .byTruncatingMiddle
        problem.textColor = Theme.failed
        let note = NSTextField(wrappingLabelWithString: footnote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width
        problem.preferredMaxLayoutWidth = width - 96
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let views: [NSView] = [label, field, pathLine, problem, note, spinner]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 86),
            label.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            field.topAnchor.constraint(equalTo: box.topAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            pathLine.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
            pathLine.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            pathLine.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            problem.topAnchor.constraint(equalTo: pathLine.bottomAnchor, constant: 2),
            problem.leadingAnchor.constraint(equalTo: pathLine.leadingAnchor),
            problem.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            problem.heightAnchor.constraint(equalToConstant: 28),
            note.topAnchor.constraint(equalTo: problem.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            spinner.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            spinner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            spinner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.layoutSubtreeIfNeeded()
        box.setFrameSize(NSSize(width: width, height: box.fittingSize.height))
        alert.accessoryView = box
        alert.window.initialFirstResponder = field
    }

    /// Shows the sheet over `window`; `create` gets the name once Create is pressed.
    func present(over window: NSWindow?, create: @escaping (String, WorktreeSheet) -> Void) {
        guard let window else { return NSSound.beep() }
        onCreate = create
        parent = window
        Self.current = self
        let done: (NSApplication.ModalResponse) -> Void = { _ in
            if Self.current === self { Self.current = nil }
        }
        alert.beginSheetModal(for: window, completionHandler: done)
        DispatchQueue.main.async { [self] in alert.window.makeFirstResponder(field) }
    }

    /// Ends the sheet: after git, either way.
    func finish() {
        spinner.stopAnimation(nil)
        if let parent, alert.window.sheetParent === parent { parent.endSheet(alert.window) } else { alert.window.orderOut(nil) }
        if Self.current === self { Self.current = nil }
    }

    func controlTextDidChange(_ note: Notification) {
        // A "/" typed by habit becomes "-", where it was typed.
        let typed = field.stringValue
        let normalized = WorktreeFolder.normalized(typed)
        if normalized != typed {
            let selection = field.currentEditor()?.selectedRange
            field.stringValue = normalized
            if let selection { field.currentEditor()?.selectedRange = selection }
        }
        changed()
    }

    private func changed() {
        let why = check(field.stringValue)
        pathLine.stringValue = WorktreeFolder.pathLine(folder: folder, name: field.stringValue)
        problem.stringValue = why ?? ""
        create.isEnabled = why == nil
    }

    @objc private func createPressed() {
        guard check(field.stringValue) == nil, let onCreate else { return NSSound.beep() }
        self.onCreate = nil
        field.isEnabled = false
        create.title = "Creating…"
        create.isEnabled = false
        cancel.isEnabled = false
        spinner.startAnimation(nil)
        onCreate(WorktreeFolder.finalName(field.stringValue), self)
    }

    // For the self-test.
    var name: String { field.stringValue }
    var pathText: String { pathLine.stringValue }
    var problemText: String { problem.stringValue }
    var footnote: String { (alert.accessoryView?.subviews.compactMap { $0 as? NSTextField }.last?.stringValue) ?? "" }
    var title: String { alert.messageText }
    var canCreate: Bool { create.isEnabled }
    var createTitle: String { create.title }
    var selectedText: String {
        guard let editor = field.currentEditor() else { return "" }
        return (field.stringValue as NSString).substring(with: editor.selectedRange)
    }
    func type(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    /// Typed as keys are: over the selection, through the field's editor.
    func typeKeys(_ text: String) {
        guard let editor = field.currentEditor() as? NSTextView else { return type(text) }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    func pressCreate() { create.performClick(nil) }
    func pressCancel() { cancel.performClick(nil) }
}

/// A field that, the first time it takes the keyboard, selects what follows its first `kept` characters
/// rather than all of it: the folder's short part after "xCloud-wt-".
private final class PrefixField: NSTextField {
    var kept = 0
    private var selectedOnce = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, !selectedOnce, let editor = currentEditor() {
            selectedOnce = true
            let length = (stringValue as NSString).length, start = min(kept, length)
            editor.selectedRange = NSRange(location: start, length: length - start)
        }
        return became
    }
}
