import AppKit
import NextTermCore

/// Open in New Worktree… and Remove Worktree…: a branch, tag or commit checked out in a folder of its own,
/// opened in its own window, so the checkout an agent works in keeps its HEAD, its files and its changes;
/// and that folder removed again, never forced. The rules are in Core (Worktrees.swift).
/// Plan: claudedocs/2026-10-09-worktree-from-switch-guard-plan.md.
extension GitActions {
    /// The sheet for `target`'s folder name and what to do with the ignored files, then `git worktree add`, the ignored
    /// files cloned, linked or (left out) those `.worktreeinclude` lists, and the new folder's window in front. `update`:
    /// then forward to its upstream there (Checkout and Update).
    func openInNewWorktree(_ target: WorktreeTarget, update: Bool = false) {
        guard let model, let git = GitWriter.git else { return NSSound.beep() }
        // A linked worktree of a repository whose git folder was moved out (--separate-git-dir): git can't say
        // where its main checkout is, and new worktrees go beside that.
        guard let main = model.mainCheckout else {
            let info = "Its git folder is kept apart from its files, and this window shows a linked worktree of it. "
                + "Open in New Worktree… works from the main checkout’s window."
            return GitPrompt.ask("Next Term can’t tell where this repository’s main checkout is", info: info, buttons: ["OK"], over: window) { _ in }
        }
        let root = self.root
        let location = AppDelegate.shared.worktreeLocation
        let listed = model.worktrees.map(\.path)
        // The choice for the ignored files names what the sidebar already knows git ignores at the checkout's top. git
        // takes a link for a file: one to a folder is named as the folder (a Link-made worktree's "vendor").
        let snapshot = controller?.sidebar.git.snapshot.flatMap { canonicalPath($0.root) == canonicalPath(root) ? $0 : nil }
        func named(_ path: String) -> String {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isFolder) && isFolder.boolValue ? path + "/" : path
        }
        let ignoredHere = snapshot.map { snapshot in
            snapshot.wholeFolders.filter { $0.value == .ignored && !$0.key.contains("/") }.map { $0.key + "/" }
                + snapshot.files.filter { $0.value == .ignored && !$0.key.contains("/") }.map { named($0.key) }
        }
        let titleHere = ignoredHere.map(WorktreeCopy.choiceTitle(ignored:)) ?? "Ignored files:"
        let chosen = AppDelegate.shared.ignoredFilesChoice(for: main)
        DispatchQueue.global(qos: .userInitiated).async {
            let ignored = location == .claudeWorktrees && WorktreeFolder.ignoresClaudeWorktrees(mainCheckout: main, git: git)
            // A submodule's go beside its superproject, in no repository's files.
            let outermost = WorktreeFolder.outermostCheckout(main, git: git)
            let includes = WorktreeInclude.exists(in: root)
            let place = WorktreeFolder.place(mainCheckout: main, outermost: outermost, location: location, claudeWorktreesIgnored: ignored)
            // Copy and Link both take the ignored files from the main checkout (the window's in a bare repository, which
            // has none for links to lead to), and the choice names what git ignores at its top: the sidebar's, when it
            // is this window's, else git's own list.
            let linkSource = WorktreeCopy.linkSource(main: main)
            let source = linkSource ?? root
            let canClone = WorktreeCopy.canClone(from: source, into: place.folder)
            let fromHere = canonicalPath(source) == canonicalPath(root)
            let ignoredThere = fromHere ? nil : WorktreeCopy.ignoredEntries(in: source, git: git)
            let choiceTitle = fromHere ? titleHere : ignoredThere.map(WorktreeCopy.choiceTitle(listed:)) ?? "Ignored files:"
            DispatchQueue.main.async {
                let shared = (source as NSString).lastPathComponent
                let lines = Dictionary(uniqueKeysWithValues: WorktreeCopy.Choice.allCases.map { ($0, WorktreeCopy.line($0, main: shared, includes: includes)) })
                let ignored = choiceTitle.map { title in
                    WorktreeSheet.IgnoredChoice(title: title, lines: lines, chosen: chosen, canClone: canClone, canLink: linkSource != nil, main: main,
                                                source: source)
                }
                askWorktreeName(target, place: place, listed: listed, includes: includes, ignored: ignored, update: update)
            }
        }
    }

    private func askWorktreeName(_ target: WorktreeTarget, place: WorktreeFolder.Place, listed: [String], includes: Bool,
                                 ignored: WorktreeSheet.IgnoredChoice?, update: Bool) {
        let folder = canonicalPath(place.folder)
        func path(_ name: String) -> String { folder + "/" + name }
        /// A worktree git lists at that path (its folder may be gone).
        func isListed(_ name: String) -> Bool {
            listed.contains { canonicalPath($0) == path(name) || $0 == place.folder + "/" + name }
        }
        let taken = { (name: String) in WorktreeFolder.exists(path(name)) || isListed(name) }
        let prefill = WorktreeFolder.suggestedName(prefix: place.prefix, short: target.shortName, isTaken: taken)
        let checkout = ((model?.root ?? root) as NSString).lastPathComponent
        let shared = ((ignored?.source ?? root) as NSString).lastPathComponent
        let footnotes: [WorktreeCopy.Choice: String] = [
            .copy: WorktreeCopy.footnote(checkout: checkout, source: shared), .link: WorktreeCopy.linkFootnote(checkout: checkout, main: shared),
            .leaveOut: WorktreeFolder.sheetInfo(checkout: checkout, includes: includes),
        ]
        let sheet = WorktreeSheet(title: WorktreeFolder.sheetTitle(target), folder: folder, prefill: prefill, prefix: place.prefix,
                                  footnotes: footnotes, ignored: ignored) { name in
            WorktreeFolder.problem(name, in: folder, isTaken: { WorktreeFolder.exists(path($0)) },
                                   isRegistered: { isListed($0) && !WorktreeFolder.exists(path($0)) })
        }
        sheet.present(over: window) { name, sheet in
            // Copy, remembered on a disk that can't clone, starts as Leave Out, as Link does in a bare repository: it
            // stays remembered unless changed.
            if let ignored, (ignored.canClone && ignored.canLink) || sheet.ignoredChoice != ignored.shown {
                AppDelegate.shared.setIgnoredFilesChoice(sheet.ignoredChoice, for: ignored.main)
            }
            createWorktree(target, at: path(name), update: update, sheet: sheet, ignoredSource: ignored?.source ?? root)
        }
    }

    /// One `git worktree add` through GitWriter (logged in Git Commands), while the sheet says "Creating…".
    /// The folder is made first, empty, so one that appeared since the sheet checked the name is never taken
    /// for the new worktree; it goes again when git makes nothing in it. A worktree that is there after git
    /// failed (a post-checkout hook, LFS) opens anyway, with the error over its window; nothing is rolled back.
    /// `ignoredSource`: the checkout Copy clones and Link's links lead to (WorktreeCopy.linkSource, else the window's);
    /// Leave Out copies what the window's `.worktreeinclude` lists.
    private func createWorktree(_ target: WorktreeTarget, at path: String, update: Bool, sheet: WorktreeSheet, ignoredSource: String) {
        if let problem = WorktreeFolder.claim(path) { return sheet.refused(problem) }
        let args = target.addArguments(path: path)
        let folder = (path as NSString).lastPathComponent
        let root = self.root
        let commonDir = model?.commonDir ?? root
        run("New worktree \(folder)", [args]) { result in
            let made = result.ok || Self.isWorktree(path, of: commonDir)
            guard made else {
                WorktreeFolder.release(path)
                sheet.finish()
                return failed("Could not create “\(folder)”", result, retry: args)
            }
            let choice = sheet.ignoredChoice, stop = sheet.stop
            if choice != .leaveOut { sheet.beginCopying(linking: choice == .link) }
            DispatchQueue.global(qos: .userInitiated).async {
                // Copy or Link: what git ignores there, cloned or linked, the window opening once it is in; Leave Out:
                // what .worktreeinclude lists, copied, as before.
                let source = choice == .leaveOut ? root : ignoredSource
                let ignored = choice == .leaveOut ? nil : Self.bringIgnored(choice, from: source, to: path, stop: stop, sheet: sheet)
                let copied = choice == .leaveOut ? Self.copyIncludes(from: root, to: path) : []
                DispatchQueue.main.async {
                    sheet.finish()
                    let opened = AppDelegate.shared.openWorktreeWindow(path)
                    if let ignored { Self.logCopy(ignored.report, from: source, in: path) }
                    guard result.ok else {
                        let skipped = update && target.branchName != nil ? "It wasn’t brought up to date: Update Project there does it." : nil
                        return failed("“\(folder)” was made, but git reported an error", result, retry: nil, note: skipped, there: (opened, path))
                    }
                    if let ignored, let problem = Self.copyProblem(ignored.report, folder: folder) {
                        GitPrompt.ask(problem.title, info: problem.info, buttons: ["Show Git Commands", "OK"], over: opened.window) { choice in
                            if choice == 0 { GitCommandsWindowController.shared.present() }
                        }
                    }
                    let on = target.branchName.map { "on \($0)" } ?? "at \(target.shown), detached"
                    let brought = ignored.map { WorktreeCopy.notice($0.report, hints: $0.hints, warnings: $0.warnings) }
                    let notice = "New worktree \(on)" + (brought ?? Self.copiedNotice(copied))
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

    /// Copy or Link: the entries git ignores in `source` that the new branch ignores too, cloned or linked (WorktreeCopy),
    /// the sheet saying which one it is at; what to run there after, and what to know before installing there. Off the
    /// main thread.
    private static func bringIgnored(_ choice: WorktreeCopy.Choice, from source: String, to path: String, stop: WorktreeCopy.Stop,
                                     sheet: WorktreeSheet) -> (report: WorktreeCopy.Report, hints: [String], warnings: [String]) {
        var refused = WorktreeCopy.Report()
        refused.links = choice == .link
        guard let git = GitWriter.git else { return (refused, [], []) }
        refused.fatal = "git couldn’t say which files it ignores"
        guard let entries = WorktreeCopy.entries(from: source, to: path, git: git) else { return (refused, [], []) }
        let includes = Set(WorktreeInclude.files(in: source, git: git))
        let worktrees = WorktreeCopy.worktrees(of: source, git: git)
        var shown = Date.distantPast
        func progress(_ entry: String, _ index: Int, _ count: Int) {
            // At most ten times a second.
            guard Date().timeIntervalSince(shown) > 0.1 || index == 1 else { return }
            shown = Date()
            DispatchQueue.main.async { sheet.copying(entry, index, count) }
        }
        let report: WorktreeCopy.Report
        if choice == .link {
            // Which folders a link may stand for whole, asked before any link is there.
            guard let linkable = WorktreeCopy.linkable(entries, in: path, git: git) else { return (refused, [], []) }
            report = WorktreeCopy.link(entries, from: source, to: path, worktrees: worktrees, includes: includes, linkable: linkable, stop: stop,
                                       progress: progress)
        } else {
            report = WorktreeCopy.clone(entries, from: source, to: path, worktrees: worktrees, includes: includes,
                                        hasTracked: { WorktreeCopy.tracks($0, in: path, git: git) }, stop: stop, progress: progress)
        }
        let hints = WorktreeCopy.hints(for: report, source: source, destination: path, git: git)
        return (report, hints, WorktreeCopy.warnings(for: report, source: source, destination: path))
    }

    /// What was cloned or linked and left out, in Git Commands.
    private static func logCopy(_ report: WorktreeCopy.Report, from source: String, in path: String) {
        let now = Date(), folder = (path as NSString).lastPathComponent
        let title = report.links ? "Link ignored files" : "Copy ignored files"
        let command = report.links ? "link the ignored files in \(folder) to \(RecentProjects.abbreviate(source))" : "clone the ignored files into \(folder)"
        GitCommandLog.shared.add(GitCommandLog.Entry(title: title, command: command, directory: path, start: now, duration: 0,
                                                     status: report.failures.isEmpty && report.fatal == nil ? 0 : 1, output: WorktreeCopy.logText(report)))
    }

    /// The question when the copy or the links went wrong: what couldn't be brought, never what was left out by design.
    private static func copyProblem(_ report: WorktreeCopy.Report, folder: String) -> (title: String, info: String)? {
        let failures = report.failures
        guard report.fatal != nil || !failures.isEmpty else { return nil }
        var lines = failures.prefix(5).map { "\($0.path): \($0.why.reason)" }
        if failures.count > 5 { lines.append("and \(failures.count - 5) more") }
        if let fatal = report.fatal { lines.insert("It stopped: \(fatal).", at: 0) }
        let title = "“\(folder)” was made, but some ignored files weren’t \(report.links ? "linked" : "copied")"
        return (title, lines.joined(separator: "\n") + "\n\nGit › Git Commands lists them all.")
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
            guard result.ok else {
                // Its Open Terminal opens in the new worktree's window and folder, never in the checkout left alone.
                return failed("Could not bring “\(branch)” up to date", result, retry: BranchCommand.fastForward, there: (opened, path))
            }
            GitToast.show(notice + (result.failure == .nothingToDo ? ", up to date" : ", updated"), in: opened.window)
        }
    }

    // MARK: Remove Worktree…

    /// Remove Worktree… on a worktree's row: refused while an agent, a window or a tab is in it, while a lock
    /// holds it, or while it has changes; a folder deleted by hand is forgotten, after asking.
    func removeWorktree(_ row: BranchPopupController.WorktreeRow) {
        removalVerdict(row) { decided, goTo in removal(decided, of: row, goTo: goTo) }
    }

    /// Whether the worktree of `row` can be removed now, and why not (WorktreeRemoval.verdict), from what is open in it
    /// here and what git says of it, read off the main thread; `goTo` brings forward what is open in it. `leaving`: a
    /// window about to close, whose tabs and agents end with it (Close and Remove Worktree), so they don't count.
    func removalVerdict(_ row: BranchPopupController.WorktreeRow, leaving: TerminalWindowController? = nil,
                        done: @escaping (WorktreeRemoval.Verdict, _ goTo: @escaping () -> Void) -> Void) {
        guard let model, let git = GitWriter.git else { return NSSound.beep() }
        let w = row.worktree
        var known = WorktreeRemoval.Facts(isMain: model.isMainCheckout(w), isMissing: w.isPrunable,
                                          lockReason: w.lockReason, holder: row.holder, holderAlive: row.holderAlive)
        let inside = Self.inside(w, of: model)
        let open = AppDelegate.shared.controllers.filter { $0 !== leaving }
        let local = open.flatMap { c in c.tabs.filter { $0.remote == nil }.map { (c, $0) } }
        let agents = local.filter { $0.1.status.running && $0.1.status.kind == .agent && inside(AgentPlaces.shared.agentFolder(of: $0.1)) }
        let windows = open.filter { $0.project.map(inside) ?? false }
        let tabs = local.filter { inside($0.1.liveDirectory) }
        known.agents = agents.map { AgentGuard.Agent(program: $0.1.status.program, tab: $0.1.title) }
        known.windows = windows.map(\.projectTitle)
        known.tabs = tabs.map { $0.1.title }
        let goTo: () -> Void = {
            if let place = agents.first ?? (windows.isEmpty ? tabs.first : nil) {
                place.0.show(place.1)
                place.0.window?.makeKeyAndOrderFront(nil)
            } else {
                windows.first?.window?.makeKeyAndOrderFront(nil)
            }
        }
        known.head = w.head
        let facts = known, root = model.root
        DispatchQueue.global(qos: .userInitiated).async {
            var counted = facts
            if !w.isPrunable {
                counted.changedFiles = WorktreeRemoval.changedFiles(at: w.path, git: git) ?? 0
                counted.inProgress = AgentLocation.gitDir(ofCheckout: w.path).flatMap(BranchModel.inProgress(gitDir:))
            }
            // Detached: git's gc deletes a commit no branch or tag has once the worktree's reflog goes with it.
            if w.isDetached, let head = w.head { counted.headOnNoBranch = WorktreeRemoval.isOnNoBranch(head, in: root, git: git) }
            let decided = WorktreeRemoval.verdict(counted)
            DispatchQueue.main.async { done(decided, goTo) }
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
            GitPrompt.ask("Remove “\(folder)”?", info: WorktreeRemoval.removeInfo(branch: w.branch, head: w.head),
                          buttons: ["Remove", "Cancel"], destructive: 0, over: window) { choice in
                if choice == 0 { runRemoval(w, folder: folder, done: "Removed \(folder)" + (w.branch.map { "; \($0) stays" } ?? "")) }
            }
        case let .forget(losing):
            GitPrompt.ask("Forget “\(folder)”?", info: WorktreeRemoval.forgetInfo(branch: w.branch, losing: losing),
                          buttons: ["Forget", "Cancel"], destructive: losing == nil ? nil : 0, over: window) { choice in
                if choice == 0 { runRemoval(w, folder: folder, done: "Forgot \(folder)") }
            }
        case let .refuse(reason, there):
            let advice = there ? "\n\nClose it there first, then remove the worktree." : reason.hasPrefix("It has") ? "\n\nCommit or discard them there first: Remove Worktree never deletes changes." : ""
            GitPrompt.ask("“\(folder)” can’t be removed now", info: reason + advice, buttons: there ? ["Go There", "OK"] : ["OK"], over: window) { choice in
                if there, choice == 0 { goTo() }
            }
        case let .unlockFirst(reason):
            // The question unlock(_:stale:) would ask is this one: Unlock goes at once (with Undo).
            GitPrompt.ask("“\(folder)” is locked", info: reason + "\n\nA lock keeps git from removing a worktree. Unlock it first if whatever locked it is done with it, then remove it.",
                          buttons: ["Unlock", "Cancel"], over: window) { choice in
                if choice == 0 { unlock(w, stale: true) }
            }
        }
    }

    /// `then`: what follows once it is gone (a switch to the branch it held), in place of the notice. Its folder leaves
    /// Recent Projects too.
    func runRemoval(_ w: Worktree, folder: String, done: String, then: (() -> Void)? = nil) {
        let args = WorktreeRemoval.arguments(path: w.path)
        let places = [w.path, canonicalPath(w.path)] // as the kernel spells it, while the folder is still there to ask
        run("Remove worktree \(folder)", [args]) { result in
            guard result.ok else { return failed("Could not remove “\(folder)”", result, retry: args) }
            AppDelegate.shared.forgetRecentProjects(under: places)
            if let then { then() } else { toast(done) }
        }
    }

    /// Close and Remove Worktree, once its window has closed and the programs in it have ended: the same remove, run
    /// from the main checkout (never forced, so git still refuses a worktree that changed meanwhile), told in the
    /// window in front now.
    static func removeClosed(_ w: Worktree, folder: String, model: BranchModel) {
        let main = model.mainCheckout ?? model.commonDir
        let steps = [WorktreeRemoval.arguments(path: w.path)]
        let places = [w.path, canonicalPath(w.path)]
        AgentPlaces.shared.noteOwnGit(steps, in: main)
        GitWriter.shared.run("Remove worktree \(folder)", in: main, repository: model.commonDir, steps: steps) { result in
            AgentPlaces.shared.noteOwnGit(steps, in: main)
            let open = AppDelegate.shared.controllers.filter { !$0.hasClosed }
            let front = (open.first { $0.window?.isKeyWindow == true } ?? open.first)?.window
            guard result.ok else {
                return GitPrompt.ask("Could not remove “\(folder)”", info: tail(result.output) + "\n\nIts window is closed, and the worktree is still there.",
                                     buttons: ["OK", "Open Worktree", "Show Git Commands"], style: .warning, over: front) { choice in
                    if choice == 1 { _ = AppDelegate.shared.openWorktreeWindow(w.path) }
                    if choice == 2 { GitCommandsWindowController.shared.present() }
                }
            }
            AppDelegate.shared.forgetRecentProjects(under: places)
            GitToast.show("Removed \(folder)" + (w.branch.map { "; \($0) stays" } ?? ""), in: front)
        }
    }
}

/// The sheet that names a new worktree's folder: one field, prefilled with its short part selected (typing
/// replaces only that), the full path under it as you type, the reason a name can't be used (Create is off
/// then), what to do with the ignored files (Copy, Link or Leave Out, each saying in a line what it means), and
/// the footnote for that choice. Create reads "Creating…" with a spinner while git works, and the sheet stays up
/// until `finish`.
final class WorktreeSheet: NSObject, NSTextFieldDelegate {
    /// The sheet up now, for the self-test.
    private(set) static var current: WorktreeSheet?

    /// The ignored files' choice: its title naming them, each choice's line, the one remembered, whether the disk lets
    /// Copy be and whether the repository has a main checkout for Link (else each is off, and says why), the main
    /// checkout it is remembered for, and the checkout Copy clones and Link's links lead to.
    struct IgnoredChoice {
        let title: String
        let lines: [WorktreeCopy.Choice: String]
        let chosen: WorktreeCopy.Choice
        let canClone: Bool
        let canLink: Bool
        let main: String
        let source: String

        /// Whether `choice` can be made here: Copy on a disk that clones, Link with a main checkout to lead to.
        func offers(_ choice: WorktreeCopy.Choice) -> Bool {
            switch choice {
            case .copy: return canClone
            case .link: return canLink
            case .leaveOut: return true
            }
        }

        /// The one chosen as the sheet comes up: one remembered that can't be made here (Copy on a disk that can't
        /// clone, Link in a bare repository) is Leave Out.
        var shown: WorktreeCopy.Choice { offers(chosen) ? chosen : .leaveOut }
    }

    private let alert = NSAlert()
    private let field = PrefixField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var choiceTitle: NSTextField?
    /// Copy, Link and Leave Out, in that order: one group, as radio buttons with one action in one view are.
    private var radios: [(choice: WorktreeCopy.Choice, button: NSButton)] = []
    /// What the choice offers: which radios can be on again when the sheet is the sheet again (`refused`).
    private var choices: IgnoredChoice?
    private let footnotes: [WorktreeCopy.Choice: String]
    /// What the new worktree gets of the ignored files: Leave Out when the sheet offers no choice.
    private(set) var ignoredChoice: WorktreeCopy.Choice = .leaveOut
    /// Stop Copying sets it; the copy reads it between clone calls.
    let stop = WorktreeCopy.Stop()
    /// "Copying" or "Linking", once Create is pressed.
    private var doing = "Copying"
    private let pathLine = NSTextField(labelWithString: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let create: NSButton
    private let cancel: NSButton
    private let folder: String
    private let prefix: String
    private let check: (String) -> String?
    private var onCreate: ((String, WorktreeSheet) -> Void)?
    /// Create was pressed and git runs: a second press does nothing.
    private var creating = false
    private weak var parent: NSWindow?

    init(title: String, folder: String, prefill: String, prefix: String, footnotes: [WorktreeCopy.Choice: String], ignored: IgnoredChoice? = nil,
         check: @escaping (String) -> String?) {
        self.folder = folder
        self.prefix = prefix
        self.check = check
        self.footnotes = footnotes
        alert.messageText = title
        alert.informativeText = ""
        create = alert.addButton(withTitle: "Create")
        cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        super.init()
        create.target = self
        create.action = #selector(createPressed)
        build(prefill: prefill, ignored: ignored)
        changed()
    }

    private func build(prefill: String, ignored: IgnoredChoice?) {
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
        // Laid out for the longest footnote, so the sheet keeps its size when the choice swaps them.
        let offered: [WorktreeCopy.Choice] = ignored == nil ? [.leaveOut] : WorktreeCopy.Choice.allCases
        note.stringValue = offered.compactMap { footnotes[$0] }.max { $0.count < $1.count } ?? ""
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width
        problem.preferredMaxLayoutWidth = width - 96
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        var views: [NSView] = [label, field, pathLine, problem, note, spinner]
        if let ignored {
            let heading = NSTextField(labelWithString: ignored.title)
            heading.lineBreakMode = .byTruncatingTail
            choiceTitle = heading
            views.append(heading)
            choices = ignored
            ignoredChoice = ignored.shown
            for choice in WorktreeCopy.Choice.allCases {
                let line = ignored.lines[choice] ?? ""
                let enabled = ignored.offers(choice)
                let radio = NSButton(radioButtonWithTitle: choice.title, target: self, action: #selector(choiceMade))
                radio.attributedTitle = Self.radioTitle(choice.title, line, enabled: enabled)
                radio.state = choice == ignoredChoice ? .on : .off
                radio.isEnabled = enabled
                let why = choice == .copy ? WorktreeCopy.cantClone : WorktreeCopy.cantLink
                radio.toolTip = enabled ? choice.title + ": " + line : why
                radio.setAccessibilityLabel(choice.title + ": " + line)
                radio.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // cut, never wider than the sheet
                radios.append((choice, radio))
                views.append(radio)
            }
        }
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
            note.topAnchor.constraint(equalTo: radios.last?.button.bottomAnchor ?? problem.bottomAnchor, constant: radios.isEmpty ? 6 : 8),
            note.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            spinner.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            spinner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            spinner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        if let choiceTitle {
            NSLayoutConstraint.activate([
                choiceTitle.topAnchor.constraint(equalTo: problem.bottomAnchor, constant: 4),
                choiceTitle.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                choiceTitle.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            ])
            // Under the title, a little in, one a line.
            var above: NSView = choiceTitle
            for (_, radio) in radios {
                NSLayoutConstraint.activate([
                    radio.topAnchor.constraint(equalTo: above.bottomAnchor, constant: above === choiceTitle ? 5 : 3),
                    radio.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
                    radio.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
                ])
                above = radio
            }
        }
        box.layoutSubtreeIfNeeded()
        box.setFrameSize(NSSize(width: width, height: box.fittingSize.height))
        note.stringValue = footnotes[ignoredChoice] ?? ""
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
        // initialFirstResponder puts the keyboard in the field, its short part selected (PrefixField).
        alert.beginSheetModal(for: window, completionHandler: done)
    }

    /// Ends the sheet: after git, either way.
    func finish() {
        spinner.stopAnimation(nil)
        if let parent, alert.window.sheetParent === parent { parent.endSheet(alert.window) } else { alert.window.orderOut(nil) }
        if Self.current === self { Self.current = nil }
    }

    /// The folder can't be made after all (it appeared since the name was checked): the sheet is the
    /// sheet again, with the reason under the field.
    func refused(_ reason: String) {
        creating = false
        spinner.stopAnimation(nil)
        create.title = "Create"
        cancel.isEnabled = true
        field.isEnabled = true
        for (choice, radio) in radios { radio.isEnabled = choices?.offers(choice) ?? true }
        changed()
        if problem.stringValue.isEmpty { problem.stringValue = reason }
        alert.window.makeFirstResponder(field)
    }

    func controlTextDidChange(_ note: Notification) {
        field.untouched = false
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

    /// A choice's title: its name, then its line, quieter, cut at the end when it doesn't fit (the tooltip has it whole).
    private static func radioTitle(_ name: String, _ line: String, enabled: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: enabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
        ])
        text.append(NSAttributedString(string: ": " + line, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ]))
        return Typography.truncating(text, .byTruncatingTail)
    }

    /// A choice made: the footnote says what the new folder gets.
    @objc private func choiceMade(_ sender: NSButton) {
        guard let made = radios.first(where: { $0.button === sender })?.choice else { return }
        ignoredChoice = made
        note.stringValue = footnotes[made] ?? ""
    }

    /// After git, while the ignored files are cloned or linked: the sheet stays up, Cancel is Stop Copying (or Linking).
    func beginCopying(linking: Bool = false) {
        doing = linking ? "Linking" : "Copying"
        create.title = doing + "…"
        cancel.title = "Stop " + doing
        cancel.target = self
        cancel.action = #selector(stopPressed)
        cancel.isEnabled = true
        for (_, radio) in radios { radio.isEnabled = false }
        problem.textColor = .secondaryLabelColor
        problem.stringValue = doing + " ignored files…"
    }

    /// "Copying vendor (2 of 9)…", as each entry git listed starts.
    func copying(_ entry: String, _ index: Int, _ count: Int) {
        guard !stop.isSet else { return }
        problem.stringValue = "\(doing) \(entry) (\(index) of \(count))…"
    }

    /// Stop Copying: the copy ends after the clone call it is in; what was copied stays, and the window opens.
    @objc private func stopPressed() {
        stop.set()
        cancel.isEnabled = false
        problem.stringValue = "Stopping…"
    }

    @objc private func createPressed() {
        guard !creating, check(field.stringValue) == nil, let onCreate else { return NSSound.beep() }
        creating = true
        field.isEnabled = false
        create.title = "Creating…"
        create.isEnabled = false
        cancel.isEnabled = false
        // The choice is read once git is done (createWorktree): it stays as it was at Create.
        for (_, radio) in radios { radio.isEnabled = false }
        spinner.startAnimation(nil)
        onCreate(WorktreeFolder.finalName(field.stringValue), self)
    }

    // For the self-test.
    var name: String { field.stringValue }
    var pathText: String { pathLine.stringValue }
    var problemText: String { problem.stringValue }
    var footnote: String { note.stringValue }
    var ignoredTitle: String? { choiceTitle?.stringValue }
    /// Each choice as its button says it: "Link: shared with xCloud, so changing one changes both".
    var choiceLines: [String] { radios.map { $0.button.attributedTitle.string } }
    func canChoose(_ choice: WorktreeCopy.Choice) -> Bool { radios.first { $0.choice == choice }?.button.isEnabled ?? false }
    /// Clicks the choice's button, as a click on it does.
    func choose(_ choice: WorktreeCopy.Choice) { radios.first { $0.choice == choice }?.button.performClick(nil) }
    var cancelTitle: String { cancel.title }
    func pressStop() { cancel.performClick(nil) }
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

/// A field that, each time it takes the keyboard until its text is changed, selects what follows its first
/// `kept` characters rather than all of it: the folder's short part after "xCloud-wt-". Each time, since
/// AppKit may start editing it more than once as the sheet comes up, selecting all again.
private final class PrefixField: NSTextField {
    var kept = 0
    /// Its text is still the prefill.
    var untouched = true

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, untouched, let editor = currentEditor() {
            let length = (stringValue as NSString).length, start = min(kept, length)
            editor.selectedRange = NSRange(location: start, length: length - start)
        }
        return became
    }
}
