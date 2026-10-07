import AppKit
import NextTermCore

/// What the branch popup and the Git menu do. Each is a few git commands with fixed flags (run by
/// GitWriter, so each is in Git Commands as it would be typed), with the rules from the design: never
/// change files under a working agent without asking, never discard (a stash is kept, by its id), say
/// what an error means and offer a terminal when a person is needed.
struct GitActions {
    let popup: BranchPopupController
    init(_ popup: BranchPopupController) { self.popup = popup }

    private var controller: TerminalWindowController? { popup.window }
    private var window: NSWindow? { controller?.window }
    private var model: BranchModel? { popup.model }
    private var root: String { model?.root ?? "" }

    private func run(_ title: String, _ steps: [[String]], activity: GitWriter.Activity? = nil, then: @escaping (GitWriter.Result) -> Void) {
        let popup = self.popup
        let controller = self.controller
        GitWriter.shared.run(title, in: root, repository: model?.commonDir ?? root, steps: steps, activity: activity) { result in
            controller?.sidebar.git.refresh()
            popup.reload()
            then(result)
        }
    }

    private func toast(_ text: String) { GitToast.show(text, in: window) }

    // MARK: agents

    /// Agents running in tabs in this worktree (not in a worktree nested inside it).
    func agentsHere() -> [TerminalTab] {
        let root = canonicalPath(self.root)
        let nested = (model?.worktrees ?? []).map { canonicalPath($0.path) }.filter { $0 != root && $0.hasPrefix(root + "/") }
        return AppDelegate.shared.controllers.flatMap(\.tabs).filter { tab in
            guard tab.remote == nil, tab.status.running, tab.status.kind == .agent else { return false }
            let folder = canonicalPath(tab.liveDirectory)
            guard folder == root || folder.hasPrefix(root + "/") else { return false }
            return !nested.contains { folder == $0 || folder.hasPrefix($0 + "/") }
        }
    }

    /// Asks first when an agent works here: switching or updating changes the files under it.
    private func confirmAgents(_ doing: String, then go: @escaping () -> Void) {
        guard let tab = agentsHere().first else { return go() }
        let agent = tab.status.program.isEmpty ? "An agent" : tab.status.program
        GitPrompt.ask("\(agent) is working in this folder", info: "In the tab “\(tab.title)”. \(doing) changes the files under it.",
                      buttons: ["\(doing.components(separatedBy: " ").first ?? "Continue") Anyway", "Cancel"], style: .warning, over: window) { choice in
            if choice == 0 { go() }
        }
    }

    // MARK: switching

    func checkout(_ ref: BranchRef) {
        let target = ref.isRemote ? ref.shortName : ref.name
        let steps: [[String]]
        if ref.isRemote {
            steps = model?.local(target) != nil ? [["switch", target]] : [["switch", "-c", target, "--track", ref.name]]
        } else {
            steps = [["switch", target]]
        }
        confirmAgents("Switching branches") {
            run("Checkout \(target)", steps) { result in
                if result.ok { return toast("Switched to \(target)") }
                switchFailed(result, to: target, steps: steps)
            }
        }
    }

    func checkoutRevision(_ revision: String) {
        run("Check “\(revision)”", [["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"]]) { found in
            guard found.ok else {
                return GitPrompt.ask("“\(revision)” isn’t a tag or revision here", info: "Try a tag (v1.2.0), a commit (abc1234) or something like main~3.",
                                     buttons: ["OK"], over: window) { _ in }
            }
            let steps = [["switch", "--detach", revision]]
            confirmAgents("Switching") {
                run("Checkout \(revision)", steps) { result in
                    if result.ok { return toast("At \(revision), detached: New Branch… keeps work made here") }
                    switchFailed(result, to: revision, steps: steps)
                }
            }
        }
    }

    func askRevision() {
        GitPrompt.text("Checkout Tag or Revision", info: "A tag, a commit, or any revision git understands, such as v1.2.0, abc1234 or main~3. You’ll be on it detached.",
                       placeholder: "v1.2.0", button: "Checkout", over: window, check: { $0.contains(" ") ? "No spaces in a revision." : nil }) { revision in
            if let revision { checkoutRevision(revision) }
        }
    }

    private func switchFailed(_ result: GitWriter.Result, to target: String, steps: [[String]]) {
        switch result.failure {
        case let .localChanges(files)?:
            let list = files.prefix(8).joined(separator: "\n") + (files.count > 8 ? "\n…and \(files.count - 8) more" : "")
            guard agentsHere().isEmpty else {
                return GitPrompt.ask("Your changes would be overwritten", info: "\(list)\n\nAn agent is working in this folder, so Next Term won’t move its changes aside. Commit them, or let the agent finish first.",
                                     buttons: ["OK"], over: window) { _ in }
            }
            GitPrompt.ask("Switching to “\(target)” would overwrite your changes", info: "\(list)\n\nNext Term can put them in a stash, switch, and put them back. If they don’t fit there, they stay safe in the stash.",
                          buttons: ["Stash, Switch and Reapply", "Cancel"], over: window) { choice in
                if choice == 0 { stashSwitch(to: target, steps: steps) }
            }
        case let .heldByWorktree(path)?:
            GitPrompt.ask("“\(target)” is checked out in another worktree", info: path.map { RecentProjects.abbreviate($0) } ?? "",
                          buttons: ["Open Worktree", "Cancel"], over: window) { choice in
                if choice == 0, let path { openWorktree(path) }
            }
        default:
            failed("Could not switch to “\(target)”", result, retry: steps.last)
        }
    }

    /// Stash (kept by its id, never "the newest"), switch, put the changes back. On any trouble the stash
    /// stays and says where the changes are.
    private func stashSwitch(to target: String, steps: [[String]]) {
        let from = model?.current ?? String((model?.headSHA ?? "HEAD").prefix(7))
        let message = "Next Term: switching from \(from) to \(target)"
        run("Stash changes", [["stash", "push", "--include-untracked", "--message", message], ["rev-parse", "--verify", "--quiet", "refs/stash"]]) { stashed in
            let sha = stashed.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard stashed.ok, sha.count >= 40 else { return failed("Could not put your changes aside", stashed, retry: nil) }
            run("Checkout \(target)", steps) { switched in
                guard switched.ok else {
                    // Back where it was, with the changes.
                    return reapply(sha) { _ in failed("Could not switch to “\(target)”", switched, retry: steps.last) }
                }
                reapply(sha) { clean in
                    if clean {
                        toast("Switched to \(target), with your changes")
                    } else {
                        GitPrompt.ask("Switched to “\(target)”; some changes conflict", info: "Your changes are safe in the stash “\(message)”. The files with conflicts are marked in the sidebar.",
                                      buttons: ["Ask Agent to Resolve", "OK"], over: window) { choice in
                            if choice == 0 { askAgent("Resolve the conflicts from re-applying my stashed changes (`git status` lists them), keeping what I meant, then stage the files. Don't commit, and keep the stash.") }
                        }
                    }
                }
            }
        }
    }

    /// `stash apply --index` (without --index when the index can't be restored); drops the stash only
    /// after a clean apply, found by its id.
    private func reapply(_ sha: String, done: @escaping (_ clean: Bool) -> Void) {
        run("Put changes back", [["stash", "apply", "--index", sha]]) { applied in
            let finish = { (result: GitWriter.Result) in
                let clean = result.ok && result.failure != .conflicts
                if clean { drop(sha) }
                done(clean)
            }
            if !applied.ok, applied.output.contains("--index") {
                run("Put changes back", [["stash", "apply", sha]], then: finish)
            } else {
                finish(applied)
            }
        }
    }

    private func drop(_ sha: String) {
        run("Find the stash", [["stash", "list", "--format=%gd %H"]]) { list in
            guard let entry = list.output.split(separator: "\n").first(where: { $0.hasSuffix(" " + sha) })?.split(separator: " ").first else { return }
            run("Drop the stash", [["stash", "drop", String(entry)]]) { _ in }
        }
    }

    func openWorktree(_ path: String) {
        guard let controller else { return }
        controller.addTab(directory: path)
    }

    // MARK: branches

    func askNewBranch(base: BranchRef?) {
        let existing = Set(model?.locals.map(\.name) ?? [])
        let from = base.map { "From “\($0.name)”." } ?? "From what’s checked out now" + (model?.current.map { " (\($0))" } ?? "") + "."
        GitPrompt.text("New Branch", info: from + " Next Term switches to it.", placeholder: "feat/my-change", button: "Create", over: window,
                       check: { BranchName.problem($0, existing: existing) }) { name in
            if let name { createBranch(name, base: base, switching: true) }
        }
    }

    func newBranch(from ref: BranchRef) { askNewBranch(base: ref) }

    /// New Branch from Here… on a commit in the Git Log: made there, and switched to.
    func askNewBranch(atCommit sha: String, subject: String) {
        let existing = Set(model?.locals.map(\.name) ?? [])
        GitPrompt.text("New Branch", info: "From commit \(sha.prefix(7)), “\(Typography.shortened(subject, to: 60))”. Next Term switches to it.",
                       placeholder: "feat/my-change", button: "Create", over: window, check: { BranchName.problem($0, existing: existing) }) { name in
            if let name { createBranch(name, base: BranchRef(name: sha, isRemote: false, sha: sha), switching: true) }
        }
    }

    /// Checkout… on a commit in the Git Log: says first that it leaves you detached.
    func askCheckout(commit sha: String, subject: String) {
        GitPrompt.ask("Check out \(sha.prefix(7))?", info: "“\(Typography.shortened(subject, to: 80))”. You’ll be on it detached: New Branch… keeps work made there.",
                      buttons: ["Checkout", "Cancel"], over: window) { choice in
            if choice == 0 { checkoutRevision(sha) }
        }
    }

    func createBranch(_ name: String, base: BranchRef?, switching: Bool) {
        // A branch made from a remote one with another name doesn't track it (feat/x from origin/main).
        let noTrack = base.map { $0.isRemote && $0.shortName != name } ?? false
        var args = switching ? ["switch", "-c", name] : ["branch", name]
        if noTrack { args.append("--no-track") }
        if let base { args.append(base.name) }
        let go = {
            run("New branch \(name)", [args]) { result in
                if result.ok { return toast(switching ? "Created and switched to \(name)" : "Created \(name)") }
                failed("Could not create “\(name)”", result, retry: args)
            }
        }
        // From where we are, nothing changes on disk; from elsewhere, the files do.
        if switching, base != nil, base?.isHead != true { confirmAgents("Switching branches", then: go) } else { go() }
    }

    func rename(_ ref: BranchRef) {
        let others = Set((model?.locals.map(\.name) ?? []).filter { $0 != ref.name })
        GitPrompt.text("Rename “\(ref.name)”", info: "Its upstream and settings move with it.", initial: ref.name, button: "Rename", over: window,
                       check: { $0 == ref.name ? nil : BranchName.problem($0, existing: others) }) { name in
            guard let name, name != ref.name else { return }
            run("Rename \(ref.name)", [["branch", "-m", ref.name, name]]) { result in
                result.ok ? toast("Renamed to \(name)") : failed("Could not rename “\(ref.name)”", result, retry: nil)
            }
        }
    }

    func delete(_ ref: BranchRef) {
        guard !ref.isHead, !ref.isRemote else { return NSSound.beep() }
        run("Delete \(ref.name)", [["branch", "-d", ref.name]]) { result in
            if result.ok { return deleted(ref) }
            guard result.failure == .notFullyMerged else { return failed("Could not delete “\(ref.name)”", result, retry: nil) }
            let base = ref.upstreamGone ? (model?.defaultBranch ?? "HEAD") : (ref.upstream ?? model?.defaultBranch ?? "HEAD")
            run("Commits only on \(ref.name)", [["log", "--format=%h %s", "--max-count=12", ref.name, "--not", base]]) { log in
                let commits = log.output.trimmingCharacters(in: .whitespacesAndNewlines)
                GitPrompt.ask("“\(ref.name)” has commits that aren’t merged", info: (commits.isEmpty ? "" : commits + "\n\n") + "Undo puts the branch back for a while after.",
                              buttons: ["Delete Anyway", "Cancel"], destructive: 0, style: .warning, over: window) { choice in
                    guard choice == 0 else { return }
                    run("Delete \(ref.name)", [["branch", "-D", ref.name]]) { forced in
                        forced.ok ? deleted(ref) : failed("Could not delete “\(ref.name)”", forced, retry: nil)
                    }
                }
            }
        }
    }

    /// "Deleted feat/x (was abc1234)", with Undo: the branch comes back at that commit, tracking what it tracked.
    private func deleted(_ ref: BranchRef) {
        GitToast.show("Deleted \(ref.name) (was \(ref.shortSHA))", in: window, button: "Undo") {
            var steps = [["branch", ref.name, ref.sha]]
            if let upstream = ref.upstream, !ref.upstreamGone { steps.append(["branch", "--set-upstream-to=" + upstream, ref.name]) }
            run("Restore \(ref.name)", steps) { result in
                result.ok ? toast("Restored \(ref.name)") : failed("Could not restore “\(ref.name)”", result, retry: nil)
            }
        }
    }

    // MARK: remotes

    func fetch() {
        run("Fetch", [["fetch", "--all", "--prune"]], activity: .fetching) { result in
            guard result.ok else { return failed("Fetch failed", result, retry: ["fetch", "--all", "--prune"]) }
            popup.reload {
                let behind = popup.model?.currentRef?.behind ?? 0
                toast(behind > 0 ? "Fetched: \(behind) new commit\(behind == 1 ? "" : "s") on the upstream" : "Fetched: up to date")
            }
        }
    }

    func updateProject() {
        guard let current = model?.currentRef else {
            return GitPrompt.ask("Not on a branch", info: "HEAD is detached. New Branch… keeps work made here.", buttons: ["OK"], over: window) { _ in }
        }
        guard let upstream = current.upstream, !current.upstreamGone, let remote = upstream.split(separator: "/").first.map(String.init) else {
            return GitPrompt.ask("“\(current.name)” isn’t tracking a remote branch", info: "Push… publishes it, and then it can be updated.",
                                 buttons: ["OK"], over: window) { _ in }
        }
        run("Update Project", [["fetch", remote]], activity: .pulling) { fetched in
            guard fetched.ok else { return failed("Could not fetch from \(remote)", fetched, retry: ["fetch", remote]) }
            popup.reload {
                guard let fresh = popup.model?.currentRef else { return }
                guard fresh.behind > 0 else { return toast("Already up to date") }
                confirmAgents("Updating") {
                    if fresh.ahead == 0 {
                        integrate("Update \(fresh.name)", ["merge", "--ff-only", "--autostash", "@{upstream}"], activity: .pulling)
                        return
                    }
                    GitPrompt.ask("“\(fresh.name)” and “\(upstream)” have both changed",
                                  info: "\(fresh.ahead) commit\(fresh.ahead == 1 ? "" : "s") here, \(fresh.behind) there. Rebase puts yours on top of theirs; Merge joins them with a merge commit.",
                                  buttons: ["Rebase", "Merge", "Cancel"], over: window) { choice in
                        if choice == 0 { integrate("Rebase \(fresh.name)", ["rebase", "--autostash", "@{upstream}"], activity: .pulling) }
                        if choice == 1 { integrate("Merge \(upstream)", ["merge", "--no-edit", "--autostash", "@{upstream}"], activity: .pulling) }
                    }
                }
            }
        }
    }

    func merge(_ branch: String) {
        confirmAgents("Merging") { integrate("Merge \(branch)", ["merge", "--no-edit", "--autostash", branch]) }
    }

    func rebase(onto branch: String) {
        confirmAgents("Rebasing") { integrate("Rebase onto \(branch)", ["rebase", "--autostash", branch]) }
    }

    /// A merge, rebase or fast-forward: on conflicts, says so and offers an agent or a terminal.
    private func integrate(_ title: String, _ args: [String], activity: GitWriter.Activity? = nil) {
        run(title, [args], activity: activity) { result in
            if result.ok, result.failure != .conflicts { return toast(result.failure == .nothingToDo ? "Already up to date" : "\(title): done") }
            guard result.failure == .conflicts || popup.model?.inProgress != nil else { return failed("\(title) failed", result, retry: args) }
            conflicts(title)
        }
    }

    private func conflicts(_ title: String) {
        GitPrompt.ask("\(title) stopped on conflicts", info: "The conflicted files are marked in the sidebar. Resolve them, then choose Continue in the branch popup (⌥⌘B), or Abort to go back.",
                      buttons: ["Ask Agent to Resolve", "Open Terminal", "OK"], over: window) { choice in
            if choice == 0 { askAgent("Resolve the git conflicts in this repository (`git status` lists them), keeping what both sides meant, then stage the resolved files. Don't commit or push.") }
            if choice == 1 { runInTerminal(["status"]) }
        }
    }

    /// Continue, Skip or Abort what is in progress.
    func inProgress(_ option: [String]) {
        guard let progress = model?.inProgress else { return }
        let command: [String]
        switch progress {
        case .rebase: command = ["rebase"] + option
        case .merge: command = ["merge"] + (option == ["--skip"] ? ["--abort"] : option)
        case .cherryPick: command = ["cherry-pick"] + option
        case .revert: command = ["revert"] + option
        case .bisect: command = ["bisect", "reset"]
        }
        let doing = option == ["--abort"] ? "Abort" : option == ["--skip"] ? "Skip" : "Continue"
        confirmAgents("\(doing)ing") {
            run("\(progress.title): \(doing)", [command]) { result in
                if result.ok, popup.model?.inProgress == nil { return toast("\(progress.title.components(separatedBy: " ").first ?? "Done"): done") }
                if result.ok { return toast("Next step: resolve, then Continue") }
                result.failure == .conflicts ? conflicts(progress.title) : failed("\(doing) failed", result, retry: command)
            }
        }
    }

    func push(branch: BranchRef? = nil) {
        guard let ref = branch ?? model?.currentRef, !ref.isRemote else {
            return GitPrompt.ask("Not on a branch", info: "HEAD is detached: New Branch… first.", buttons: ["OK"], over: window) { _ in }
        }
        let remotes = model?.remoteNames ?? []
        guard !remotes.isEmpty else {
            return GitPrompt.ask("This repository has no remote", info: "Add one first, in a terminal: git remote add origin <url>.", buttons: ["OK"], over: window) { _ in }
        }
        let remote = ref.upstream.flatMap { $0.split(separator: "/").first.map(String.init) }.flatMap { remotes.contains($0) ? $0 : nil }
            ?? (remotes.contains("origin") ? "origin" : remotes[0])
        let upstreamName = ref.upstream.map { String($0.dropFirst(remote.count + 1)) }
        let go = { (target: String) in
            let publishing = ref.upstream == nil || ref.upstreamGone || target != upstreamName
            let range = publishing ? [ref.name, "--not", "--remotes"] : ["\(remote)/\(target)..\(ref.name)"]
            run("Outgoing commits", [["log", "--format=%h %s", "--max-count=10"] + range]) { log in
                let commits = log.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = publishing ? "Publish “\(ref.name)” to \(remote)/\(target)?" : "Push “\(ref.name)” to \(remote)/\(target)?"
                GitPrompt.ask(title, info: commits.isEmpty ? "Nothing new to send; \(publishing ? "it creates the branch there." : "it’s up to date.")" : commits,
                              buttons: [publishing ? "Publish" : "Push", "Cancel"], over: window) { choice in
                    guard choice == 0 else { return }
                    var args = ["push", "--porcelain"]
                    if publishing { args.append("--set-upstream") }
                    args += [remote, target == ref.name ? ref.name : "refs/heads/\(ref.name):refs/heads/\(target)"]
                    run("Push \(ref.name)", [args], activity: .pushing) { result in
                        if result.ok { return toast("Pushed \(ref.name) to \(remote)/\(target)") }
                        guard result.failure == .pushRejected else { return failed("Push failed", result, retry: args) }
                        GitPrompt.ask("\(remote)/\(target) has commits you don’t have", info: "Update first brings them in. Force push replaces them with yours.",
                                      buttons: ["Update First", "Force Push…", "Cancel"], over: window) { next in
                            if next == 0 { updateProject() }
                            if next == 1 { forcePush(ref, remote: remote, target: target) }
                        }
                    }
                }
            }
        }
        if let upstreamName, !ref.upstreamGone, upstreamName != ref.name {
            GitPrompt.ask("“\(ref.name)” tracks \(remote)/\(upstreamName)", info: "Push it to a branch of its own name, or to the one it tracks?",
                          buttons: ["Push to \(remote)/\(ref.name)", "Push to \(remote)/\(upstreamName)", "Cancel"], over: window) { choice in
                if choice == 0 { go(ref.name) }
                if choice == 1 { go(upstreamName) }
            }
        } else {
            go(upstreamName ?? ref.name)
        }
    }

    /// Only after the commits it discards are shown, with the lease set to exactly what was shown, and
    /// never for the default branch or main, master and release/*.
    private func forcePush(_ ref: BranchRef, remote: String, target: String) {
        if ["main", "master", model?.defaultBranch].contains(target) || target.hasPrefix("release/") {
            return GitPrompt.ask("Force push to \(target) is off", info: "\(target) is shared: update first, or push to a branch of your own.", buttons: ["OK"], over: window) { _ in }
        }
        run("Commits force push would discard", [["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(target)"],
                                                 ["log", "--format=%h %s", "--max-count=12", "\(ref.name)..\(remote)/\(target)"]]) { result in
            let lines = result.output.split(separator: "\n").map(String.init)
            guard result.ok, let sha = lines.first, sha.count >= 40 else { return failed("Could not read \(remote)/\(target)", result, retry: nil) }
            let discarded = lines.dropFirst().joined(separator: "\n")
            GitPrompt.ask("Force push discards these commits on \(remote)/\(target)", info: discarded.isEmpty ? "(none known locally)" : discarded,
                          buttons: ["Force Push", "Cancel"], destructive: 0, style: .warning, over: window) { choice in
                guard choice == 0 else { return }
                let args = ["push", "--porcelain", "--force-with-lease=refs/heads/\(target):\(sha)", remote, "refs/heads/\(ref.name):refs/heads/\(target)"]
                run("Force push \(ref.name)", [args], activity: .pushing) { pushed in
                    if pushed.ok { return toast("Force-pushed \(ref.name) to \(remote)/\(target)") }
                    if pushed.failure == .leaseFailed {
                        return GitPrompt.ask("\(remote)/\(target) changed since you looked", info: "Nothing was overwritten. Fetch, look at the new commits, and try again.",
                                             buttons: ["Fetch", "OK"], over: window) { choice in if choice == 0 { fetch() } }
                    }
                    failed("Force push failed", pushed, retry: args)
                }
            }
        }
    }

    // MARK: commit

    func commit() {
        guard let controller, let git = GitWriter.git, model != nil else { return }
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let staged = BranchModel.stagedFiles(at: root, git: git)
            DispatchQueue.main.async {
                let snapshot = controller.sidebar.git.snapshot
                let changed = (snapshot?.files.filter { $0.value != .ignored }.map(\.key) ?? [])
                    + (snapshot?.wholeFolders.filter { $0.value == .untracked }.map { $0.key + "/" } ?? [])
                let untracked = Set((snapshot?.files.filter { $0.value == .untracked }.map(\.key) ?? [])
                                    + (snapshot?.wholeFolders.filter { $0.value == .untracked }.map { $0.key + "/" } ?? []))
                CommitSheet.present(over: controller, branch: model?.current, staged: staged, changed: changed.sorted(), untracked: untracked,
                                    onAgent: { askAgent("Commit the current changes with a clear message (look at the diff first). Don't push.") }) { message, files, amend, andPush in
                    commit(message: message, files: files, amend: amend, andPush: andPush)
                }
            }
        }
    }

    /// `files` nil: what is staged; else these paths are staged first.
    private func commit(message: String, files: [String]?, amend: Bool, andPush: Bool) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-commit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let messageFile = folder.appendingPathComponent("message")
        let listFile = folder.appendingPathComponent("paths")
        try? message.write(to: messageFile, atomically: true, encoding: .utf8)
        var steps: [[String]] = []
        if let files {
            try? Data(files.joined(separator: "\0").utf8).write(to: listFile)
            steps.append(["add", "--all", "--pathspec-from-file=" + listFile.path, "--pathspec-file-nul"])
        }
        steps.append(amend && message.isEmpty ? ["commit", "--amend", "--no-edit"] : ["commit", "-F", messageFile.path] + (amend ? ["--amend"] : []))
        run(amend ? "Amend commit" : "Commit", steps) { result in
            try? FileManager.default.removeItem(at: folder)
            guard result.ok else {
                if result.failure == .hookFailed {
                    return GitPrompt.ask("A git hook stopped the commit", info: Self.tail(result.output), buttons: ["Open Terminal", "Show Git Commands", "OK"], over: window) { choice in
                        if choice == 0 { runInTerminal(["commit"]) }
                        if choice == 1 { GitCommandsWindowController.shared.present() }
                    }
                }
                return failed("Could not commit", result, retry: nil)
            }
            let sha = result.output.range(of: #"\[[^\]]* ([0-9a-f]{7,})\]"#, options: .regularExpression)
                .map { String(result.output[$0]).components(separatedBy: " ").last?.dropLast() ?? "" }.map(String.init) ?? ""
            if andPush { return push() }
            GitToast.show("Committed\(sha.isEmpty ? "" : " " + sha)", in: window, button: "Undo") { undoCommit() }
        }
    }

    /// Back to before the commit, with its changes staged: only while no remote has it.
    private func undoCommit() {
        guard let git = GitWriter.git else { return }
        let root = self.root
        DispatchQueue.global().async {
            let published = BranchModel.headIsPublished(at: root, git: git)
            DispatchQueue.main.async {
                if published {
                    return GitPrompt.ask("That commit is already on a remote", info: "Undoing it now would rewrite shared history, so Next Term leaves it.", buttons: ["OK"], over: window) { _ in }
                }
                run("Undo commit", [["reset", "--soft", "HEAD~1"]]) { result in
                    result.ok ? toast("Commit undone: its changes are staged") : failed("Could not undo the commit", result, retry: nil)
                }
            }
        }
    }

    // MARK: people and agents

    /// Types a request into an agent's tab in this folder (without pressing Return): the agent does it,
    /// in front of you.
    func askAgent(_ prompt: String) {
        guard let controller else { return }
        let tab = agentsHere().first ?? controller.tabs.first { $0.status.running && $0.status.kind == .agent }
        guard let tab else {
            return GitPrompt.ask("No agent is open here", info: "Start one in a tab (claude, codex…), then ask again.", buttons: ["OK"], over: window) { _ in }
        }
        controller.show(tab)
        tab.view.typeText(prompt)
        toast("Written in “\(tab.title)”: press Return to send")
    }

    /// A new tab in the worktree with the git command typed and waiting for Return.
    func runInTerminal(_ args: [String]) {
        guard let controller else { return }
        let tab = controller.addTab(directory: root)
        let command = GitWriter.commandLine(args)
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            tries += 1
            if tab.status.integrated || tries > 25 {
                timer.invalidate()
                tab.view.typeIn(command)
            }
        }
    }

    private static func tail(_ output: String, lines: Int = 12) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Says what went wrong in plain words, with git's own last lines, and what can be done now.
    private func failed(_ title: String, _ result: GitWriter.Result, retry: [String]?) {
        var info = Self.tail(result.output)
        var person = false
        switch result.failure {
        case .authentication?:
            info = "Git needs your password, passphrase or key, and Next Term doesn’t ask for it yet. In a terminal, git can ask.\n\n" + info
            person = true
        case .hostKey?:
            info = "ssh doesn’t know this server’s key yet, or it changed. Check it in a terminal before accepting it.\n\n" + info
            person = true
        case .signing?:
            info = "Signing needs a passphrase prompt: install pinentry-mac, or commit in a terminal.\n\n" + info
            person = true
        case let .lockHeld(path)?:
            info = "Another git command is running in this repository, or one that stopped left its lock file\(path.map { " (\($0))" } ?? ""). Try again in a moment."
        case .network?:
            info = "The remote couldn’t be reached.\n\n" + info
        case .nothingToDo?:
            return toast(Self.tail(result.output, lines: 1))
        default:
            person = retry != nil
        }
        var buttons = ["OK", "Show Git Commands"]
        if person, retry != nil { buttons.append("Open Terminal") }
        GitPrompt.ask(title, info: info, buttons: buttons, style: .warning, over: window) { choice in
            if choice == 1 { GitCommandsWindowController.shared.present() }
            if choice == 2, let retry { runInTerminal(retry) }
        }
    }
}
