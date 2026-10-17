import AppKit
import NextTermCore

/// Open in New Worktree… (AE1-AE11 of claudedocs/2026-10-09-worktree-from-switch-guard-plan.md), in a
/// repository of its own named xCloud in a ~/Code of its own, with a remote and a stand-in Claude Code and
/// Codex working in it. The guard's three buttons and its words, the sheet (prefill, the short part
/// selected, the path line, -2, a taken name, "/" as "-"), the worktree in its own window titled
/// "xCloud ▸ 7027-sso" and kept out of Recent Projects while the agents' checkout keeps its HEAD and
/// changes, a remote-only branch, a held one, .worktreeinclude, the ignored files copied (AE12) or linked and
/// removed with only the links going (AE13), a hook that fails, Remove Worktree… refused while a window is open
/// there, the dead end under an agent, and Open in New Window twice.
/// The sheets and windows need the app in front: without it the section is skipped with a note.
extension SelfTest {
    static func worktreeChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared, let git = GitRunner.locateGit(), let front = c.window else { return }
        guard await bringToFront(front) else {
            return note("Open in New Worktree (AE1-AE11): skipped, \(notFrontmost(front)): its sheets and new windows need the app in front")
        }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-worktrees-\(getpid())"
        try? fm.removeItem(atPath: base)
        let code = base + "/Code", repo = code + "/xCloud", origin = base + "/origin.git", theirs = base + "/theirs"
        let bin = base + "/bin", hooks = base + "/hooks"
        for folder in [repo, bin, hooks] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        @discardableResult func sh(_ dir: String, _ args: String...) -> String { gitIn(git, dir, args) }
        func write(_ path: String, _ text: String) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

        // xCloud: on fix/7611-3ds-confirm-bypass with uncommitted changes, other branches, a remote with a branch
        // only there, and a branch held by a sibling worktree. Hooks from a folder of its own (a global
        // core.hooksPath would hide .git/hooks).
        write(repo + "/a.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        write(repo + "/.gitignore", ".env\n*.log\n")
        sh(repo, "init", "-q")
        sh(repo, "config", "core.hooksPath", hooks)
        sh(repo, "add", "-A")
        sh(repo, "commit", "-qm", "One")
        for name in ["fix/7027-sso", "fix/7050-pr", "feat/aichat", "fix/hooked", "fix/included", "mishuk/assistant-mcp-runner"] { sh(repo, "branch", name) }
        sh(repo, "switch", "-q", "-c", "fix/conflicting")
        write(repo + "/a.txt", "theirs\n" + ((2...20).map { "line \($0)" }.joined(separator: "\n")) + "\n")
        sh(repo, "commit", "-qam", "Change the first line")
        sh(repo, "switch", "-q", "-c", "fix/7611-3ds-confirm-bypass", "main")
        sh(base, "init", "-q", "--bare", origin)
        sh(repo, "remote", "add", "origin", origin)
        sh(repo, "push", "-q", "-u", "origin", "fix/7611-3ds-confirm-bypass", "mishuk/assistant-mcp-runner")
        sh(base, "clone", "-q", origin, theirs)
        // From a branch origin has: its HEAD names main, which was never pushed, so the clone checks nothing out, and a
        // branch made there has no commit to push.
        sh(theirs, "switch", "-q", "--no-track", "-c", "rakib/new-panel", "origin/fix/7611-3ds-confirm-bypass")
        sh(theirs, "commit", "-q", "--allow-empty", "-m", "New panel")
        sh(theirs, "push", "-q", "origin", "rakib/new-panel")
        sh(repo, "fetch", "-q", "origin")
        sh(repo, "worktree", "add", "-q", code + "/xcloud-wt-aichat", "mishuk/assistant-mcp-runner")
        // The agents' work in progress: the first and last lines.
        write(repo + "/a.txt", "mine\n" + ((2...19).map { "line \($0)" }.joined(separator: "\n")) + "\nlast\n")
        let changes = sh(repo, "diff", "--stat")
        let head = sh(repo, "rev-parse", "--abbrev-ref", "HEAD")

        let savedLocation = app.worktreeLocation
        app.worktreeLocation = .beside
        let recentBefore = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        let holder = app.openWindow(directory: repo, project: canonicalPath(repo))
        var agentTabs: [TerminalTab] = []
        var made: [String] = []
        defer {
            app.worktreeLocation = savedLocation
            for tab in agentTabs { tab.view.send(txt: "\u{03}") }
        }
        guard let window = holder.window else { return }
        if !holder.isSidebarVisible { holder.toggleProjectSidebar(nil) } // the branch popup opens under its header

        // Stand-ins for Claude Code and Codex, working in the repository's root.
        let script = "#!/bin/sh\n\(stopsOnCtrlC)\nwhile true; do printf '\\r\\342\\234\\273 Working (esc to interrupt) %s' \"$SECONDS\"; \(standInWait("0.3")); done\n"
        for program in ["claude", "codex"] {
            fm.createFile(atPath: bin + "/" + program, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        }
        func startAgent(_ program: String, named name: String) async -> TerminalTab {
            let tab = holder.tabs.count == 1 && agentTabs.isEmpty ? holder.tabs[0] : holder.addTab(directory: repo)
            tab.userTitle = name
            _ = await wait(20) { tab.status.integrated }
            tab.view.send(txt: "PATH=\(ShellQuote.quote(bin)):$PATH \(program)\r")
            _ = await wait(10) { tab.status.running && tab.status.kind == .agent }
            agentTabs.append(tab)
            return tab
        }
        let claude = await startAgent("claude", named: "✳ Slack thread discussion")
        check(claude.status.running && claude.status.kind == .agent, "worktrees: a stand-in Claude Code works in xCloud", claude.status.command)

        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        func sheetButtons(_ w: NSWindow?) -> [NSButton] { w?.attachedSheet?.contentView.map(buttons) ?? [] }
        func press(_ title: String, in w: NSWindow? = nil, within seconds: Double = 8) async -> Bool {
            let w = w ?? window
            guard await wait(seconds, { sheetButtons(w).contains { $0.title == title } }),
                  let button = sheetButtons(w).first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        func actions() async -> GitActions? {
            var made: GitActions?
            holder.withGit(at: repo) { made = $0 }
            _ = await wait(15) { made != nil }
            return made
        }
        func worktreeWindow(_ path: String) -> TerminalWindowController? { app.controllers.first { $0.project == canonicalPath(path) } }
        func sheet() async -> WorktreeSheet? {
            _ = await wait(8) { WorktreeSheet.current != nil }
            return WorktreeSheet.current
        }
        let popup = holder.branchPopup
        func rows(_ query: String) async -> [String] {
            holder.showBranches(at: repo, query: query)
            _ = await wait(15) { !popup.isReading && popup.model.map { canonicalPath($0.root) == canonicalPath(repo) } == true }
            return popup.rowTitles
        }
        func menu(_ title: String) -> NSMenu? { popup.rowTitles.firstIndex(of: title).flatMap { popup.menu(forRow: $0) } }
        func run(_ item: NSMenuItem?) { (item?.representedObject as? MenuBlock)?.run(nil) }

        // AE1: ↩ on fix/7027-sso under a working agent. The guard: Open in New Worktree… (Return), Switch Anyway, Cancel.
        guard let first = await actions(), let target = popup.model?.local("fix/7027-sso") else {
            return check(false, "worktrees: the branch popup reads xCloud")
        }
        first.checkout(target)
        let asked = await wait(8) { sheetButtons(window).count == 3 }
        let titles = sheetButtons(window).map(\.title)
        check(asked && titles == ["Open in New Worktree…", "Switch Anyway", "Cancel"], "worktrees: the guard offers Open in New Worktree…, Switch Anyway and Cancel (AE1)",
              titles.joined(separator: ", "))
        check(sheetButtons(window).first?.keyEquivalent == "\r" && sheetButtons(window).last?.keyEquivalent == "\u{1b}",
              "worktrees: Return is Open in New Worktree…, Esc is Cancel", sheetButtons(window).map { $0.keyEquivalent.debugDescription }.joined(separator: " "))
        let guardText = sheetText(window)
        check(guardText.contains("Claude Code is working in this folder")
              && guardText.contains("In the tab “✳ Slack thread discussion”. Switching to fix/7027-sso changes the files under it."),
              "worktrees: the guard names the agent and says what switching does (AE1)", guardText)
        _ = await press("Open in New Worktree…")
        guard let named = await sheet() else { return check(false, "worktrees: Open in New Worktree… shows the folder sheet") }
        let sibling = code + "/xCloud-wt-7027-sso"
        check(named.title == "Open fix/7027-sso in a New Worktree" && named.name == "xCloud-wt-7027-sso"
              && named.pathText == RecentProjects.abbreviate(canonicalPath(code)) + "/xCloud-wt-7027-sso",
              "worktrees: the sheet is prefilled beside the repository, with the full path under it (AE1)", "\(named.title) | \(named.name) | \(named.pathText)")
        _ = await wait(2) { named.selectedText == "7027-sso" }
        check(named.selectedText == "7027-sso", "worktrees: the short part is selected, so typing replaces only that", named.selectedText.debugDescription)
        check(named.footnote.contains("List files in .worktreeinclude to copy them."), "worktrees: without a .worktreeinclude, the footnote says nothing is copied (AE7)",
              named.footnote)
        named.pressCreate()
        check(named.createTitle == "Creating…", "worktrees: Create reads “Creating…” while git works", named.createTitle)
        let opened = await wait(30) { worktreeWindow(sibling) != nil }
        made.append(sibling)
        if let w = worktreeWindow(sibling) {
            _ = await wait(5) { NSApp.keyWindow === w.window && w.window?.title.contains("xCloud ▸ 7027-sso") == true }
            check(w.projectTitle == "xCloud ▸ 7027-sso" && w.window?.title.contains("xCloud ▸ 7027-sso") == true && NSApp.keyWindow === w.window,
                  "worktrees: a window “xCloud ▸ 7027-sso” opens in front (AE1)", "\(w.projectTitle) | \(w.window?.title ?? "")")
            check(w.tabs.count == 1 && canonicalPath(w.tabs[0].directory) == canonicalPath(sibling), "worktrees: with one shell tab in the new folder",
                  w.tabs.map(\.directory).joined(separator: ", "))
        } else {
            check(opened, "worktrees: a window opens on the new worktree (AE1)", app.controllers.compactMap(\.project).joined(separator: ", "))
        }
        check(sh(sibling, "rev-parse", "--abbrev-ref", "HEAD") == "fix/7027-sso", "worktrees: the new folder is on fix/7027-sso", sh(sibling, "rev-parse", "--abbrev-ref", "HEAD"))
        check(sh(repo, "rev-parse", "--abbrev-ref", "HEAD") == head && sh(repo, "diff", "--stat") == changes && claude.status.running,
              "worktrees: xCloud keeps its HEAD, its changes and its agent (AE1)", sh(repo, "diff", "--stat"))
        check((UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []) == recentBefore, "worktrees: Recent Projects is unchanged (AE1)")
        check(await rows("").contains("worktree xCloud-wt-7027-sso"), "worktrees: xCloud's popup lists the new folder under Worktrees (AE1)",
              popup.rowTitles.joined(separator: " | "))
        popup.close()
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // Two agents: the title counts them and the line names each (D2).
        let codex = await startAgent("codex", named: "v2.9.0 / #7027 session")
        if let actions = await actions(), let pr = popup.model?.local("fix/7050-pr") {
            actions.checkout(pr)
            _ = await wait(8) { sheetButtons(window).count == 3 }
            let text = sheetText(window)
            check(text.contains("2 agents are working in this folder") && text.contains("Claude Code in “✳ Slack thread…” and Codex in “v2.9.0 / #7027 session”."),
                  "worktrees: with two agents the guard counts them and names each (D2)", text)
            _ = await press("Cancel")
        }
        codex.view.send(txt: "\u{03}")
        _ = await wait(5) { !codex.status.running }
        agentTabs.removeAll { $0 === codex }
        holder.requestClose(codex)

        // AE6: a taken name gets -2, a taken name typed back turns Create off, and "/" becomes "-".
        try? fm.createDirectory(atPath: code + "/xCloud-wt-7050-pr", withIntermediateDirectories: true)
        if let actions = await actions() {
            actions.openInNewWorktree(.branch("fix/7050-pr"))
            if let named = await sheet() {
                check(named.name == "xCloud-wt-7050-pr-2", "worktrees: a taken folder name is prefilled with -2 (AE6)", named.name)
                named.type("xCloud-wt-7050-pr")
                check(!named.canCreate && named.problemText == "Already exists in " + RecentProjects.abbreviate(canonicalPath(code)),
                      "worktrees: typing a taken name turns Create off, with the reason (AE6)", named.problemText)
                named.type("fix/x")
                check(named.name == "fix-x" && named.canCreate, "worktrees: a “/” typed by habit becomes “-”", named.name)
                named.pressCancel()
                _ = await wait(5) { WorktreeSheet.current == nil && window.attachedSheet == nil }
            } else {
                check(false, "worktrees: Open in New Worktree… shows the sheet without an agent too")
            }
        }
        // AE2: typing over the selected short part keeps the prefix; the path line follows, and Create makes that folder.
        if let actions = await actions() {
            actions.openInNewWorktree(.branch("feat/aichat"))
            if let named = await sheet() {
                _ = await wait(2) { named.selectedText == "aichat" }
                named.typeKeys("aichat2")
                let path = code + "/xCloud-wt-aichat2"
                check(named.name == "xCloud-wt-aichat2" && named.pathText.hasSuffix("/Code/xCloud-wt-aichat2") && named.canCreate,
                      "worktrees: typing “aichat2” makes the name xCloud-wt-aichat2, and the path line follows (AE2)", "\(named.name) | \(named.pathText)")
                named.pressCreate()
                check(await wait(30) { worktreeWindow(path) != nil } && sh(path, "rev-parse", "--abbrev-ref", "HEAD") == "feat/aichat",
                      "worktrees: Create makes ~/Code/xCloud-wt-aichat2 (AE2)", sh(path, "rev-parse", "--abbrev-ref", "HEAD"))
                made.append(path)
                worktreeWindow(path)?.window?.performClose(nil)
            }
        }
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // AE4: a remote-only branch: the local branch is made, tracking it, with no question.
        if let actions = await actions(), let remote = popup.model?.remotes.first(where: { $0.name == "origin/rakib/new-panel" }) {
            let target = actions.worktreeTarget(remote)
            check(target == .remoteBranch(remote: "origin", branch: "rakib/new-panel", localExists: false), "worktrees: a remote-only branch's target tracks it (AE4)",
                  String(describing: target))
            if let target {
                actions.openInNewWorktree(target)
                if let named = await sheet() {
                    check(named.name == "xCloud-wt-new-panel", "worktrees: named after the branch's last part (AE4)", named.name)
                    named.pressCreate()
                    let path = code + "/xCloud-wt-new-panel"
                    let tracking = await wait(30) { worktreeWindow(path) != nil }
                    made.append(path)
                    check(tracking && sh(path, "rev-parse", "--abbrev-ref", "HEAD") == "rakib/new-panel"
                          && sh(path, "rev-parse", "--abbrev-ref", "@{upstream}") == "origin/rakib/new-panel" && window.attachedSheet == nil,
                          "worktrees: the local rakib/new-panel tracks origin/rakib/new-panel, without another question (AE4)",
                          sh(path, "rev-parse", "--abbrev-ref", "@{upstream}"))
                    worktreeWindow(path)?.window?.performClose(nil)
                }
            }
        } else {
            check(false, "worktrees: origin/rakib/new-panel is listed")
        }
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // AE5: a remote branch whose local copy is held by xcloud-wt-aichat: no agent alert, Open Worktree.
        if let actions = await actions(), let remote = popup.model?.remotes.first(where: { $0.name == "origin/mishuk/assistant-mcp-runner" }) {
            actions.checkout(remote)
            _ = await wait(8) { window.attachedSheet != nil }
            let text = sheetText(window), offered = sheetButtons(window).map(\.title)
            check(text.contains("“mishuk/assistant-mcp-runner” is checked out in “xcloud-wt-aichat”") && offered.contains("Open Worktree")
                  && offered.first == "Remove Worktree and Switch" && !offered.contains("Switch Anyway"),
                  "worktrees: a branch held by a clean worktree gets Remove Worktree and Switch and Open Worktree, not the agent alert (AE5)",
                  "\(text) | \(offered)")
            check(actions.worktreeTarget(remote) == nil, "worktrees: and isn't offered in a new worktree (git checks a branch out once)")
            _ = await press("Cancel")
        }

        // AE7: .worktreeinclude lists .env, which is ignored: only it is copied.
        write(repo + "/.env", "SECRET=1\n")
        write(repo + "/debug.log", "ignored, not listed\n")
        write(repo + "/.worktreeinclude", ".env\n")
        if let actions = await actions() {
            actions.openInNewWorktree(.branch("fix/included"))
            if let named = await sheet() {
                check(named.footnote.contains("copies of the ignored files .worktreeinclude lists"), "worktrees: with a .worktreeinclude, the footnote says so (AE7)", named.footnote)
                named.pressCreate()
                let path = code + "/xCloud-wt-included"
                _ = await wait(30) { worktreeWindow(path) != nil }
                made.append(path)
                check(read(path + "/.env") == "SECRET=1\n" && !fm.fileExists(atPath: path + "/debug.log") && sh(repo, "diff", "--stat") == changes,
                      "worktrees: the ignored .env it lists is copied, and nothing else (AE7)",
                      ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted().joined(separator: ", "))
                worktreeWindow(path)?.window?.performClose(nil)
            }
        }
        try? fm.removeItem(atPath: repo + "/.worktreeinclude")
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // AE12: the ignored files copied. node_modules with its .bin link, vendor and .env are cloned; the log, public/hot,
        // a link out of the checkout and a worktree nested in .claude/worktrees are left out; the checkout's changes
        // stay as they were; the choice is remembered for the repository.
        let savedCopies = UserDefaults.standard.dictionary(forKey: "worktreeCopiesIgnored")
        let savedChoices = UserDefaults.standard.dictionary(forKey: "worktreeIgnoredFiles")
        let exclude = repo + "/.git/info/exclude"
        let excludeBefore = read(exclude) ?? ""
        // Every worktree reads it. /build ignores a link by that name too; node_modules/ and vendor/ only folders.
        write(exclude, excludeBefore + "vendor/\nnode_modules/\n/build\npublic/hot\npublic/storage\n.claude/worktrees/\n")
        write(repo + "/build/app.js", "built\n")
        write(repo + "/node_modules/vite/bin/vite.js", "#!/usr/bin/env node\n")
        try? fm.createDirectory(atPath: repo + "/node_modules/.bin", withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: repo + "/node_modules/.bin/vite", withDestinationPath: "../vite/bin/vite.js")
        write(repo + "/vendor/autoload.php", "<?php\n")
        write(repo + "/public/hot", "http://localhost:5173\n")
        try? fm.createSymbolicLink(atPath: repo + "/public/storage", withDestinationPath: repo + "/storage/app/public")
        let nested = repo + "/.claude/worktrees/agent-x"
        sh(repo, "worktree", "add", "-q", "-b", "agent-x", nested)
        made.append(nested)
        sh(repo, "branch", "fix/copied")
        _ = await wait(15) { holder.sidebar.git.snapshot?.wholeFolders["vendor"] == .ignored && holder.sidebar.git.snapshot?.wholeFolders["node_modules"] == .ignored }
        if let actions = await actions() {
            actions.openInNewWorktree(.branch("fix/copied"))
            if let named = await sheet() {
                check(named.ignoredTitle == "Ignored files: node_modules/, vendor/, .env…" && named.ignoredChoice == .leaveOut,
                      "worktrees: the sheet asks what to do with the ignored files, naming node_modules/, vendor/ and .env, Leave Out at first (AE12)",
                      named.ignoredTitle ?? "no choice")
                if named.canChoose(.copy) {
                    named.choose(.copy)
                    check(named.ignoredChoice == .copy && named.footnote.contains("also gets clones of what xCloud’s git ignores, .env and keys included"),
                          "worktrees: Copy chosen, the footnote says what the new folder gets (AE12)", named.footnote)
                    named.pressCreate()
                    let path = code + "/xCloud-wt-copied"
                    _ = await wait(30) { worktreeWindow(path) != nil }
                    made.append(path)
                    let link = try? fm.destinationOfSymbolicLink(atPath: path + "/node_modules/.bin/vite")
                    let absent = ["debug.log", "public/hot", "public/storage", ".claude/worktrees/agent-x"].filter { name in
                        var info = stat()
                        return lstat(path + "/" + name, &info) == 0
                    }
                    check(link == "../vite/bin/vite.js" && read(path + "/vendor/autoload.php") == "<?php\n" && read(path + "/.env") == "SECRET=1\n" && absent.isEmpty,
                          "worktrees: node_modules (its .bin link kept), vendor and .env are cloned; the log, public/hot, the link out and the nested worktree are not (AE12)",
                          "link \(link ?? "none"), present: \(absent)")
                    check(sh(repo, "diff", "--stat") == changes, "worktrees: the checkout's changes are as they were (AE12)")
                    _ = await wait(5) { GitToast.text?.contains("ignored item") == true }
                    check(GitToast.text?.contains("left out") == true && GitToast.text?.contains("php artisan storage:link") == true,
                          "worktrees: the notice counts what was copied and left out, and names storage:link (AE12)", GitToast.text ?? "no notice")
                    worktreeWindow(path)?.window?.performClose(nil)
                    window.makeKeyAndOrderFront(nil)
                    // Remembered: the next sheet in this repository has Copy chosen.
                    actions.openInNewWorktree(.branch("fix/7050-pr"))
                    if let next = await sheet() {
                        check(next.ignoredChoice == .copy, "worktrees: the choice is remembered for the repository (AE12)")
                        next.pressCancel()
                    }
                } else {
                    note("worktrees: AE12 copies skipped, the scratch folder's disk can't clone")
                }
            }
        }
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // AE13: the ignored files linked. .env and build (ignored by name, so a link is too) are one link each, relative
        // to xCloud; node_modules and vendor (ignored only as folders) are folders of their own holding a link for each
        // thing in them; what AE12 leaves out is left out; git sees no change there; the sidebar marks a link and says
        // where it leads. Remove Worktree then deletes the links only: xCloud's files are all still there.
        sh(repo, "branch", "fix/linked")
        if let actions = await actions() {
            actions.openInNewWorktree(.branch("fix/linked"))
            if let named = await sheet() {
                let lines = named.choiceLines
                check(lines.count == 3 && lines[0].hasPrefix("Copy: ") && lines[1] == "Link: shared with xCloud, so changing one changes both"
                      && lines[2].hasPrefix("Leave Out: ") && named.canChoose(.link),
                      "worktrees: the sheet offers Copy, Link and Leave Out, each saying in a line what it means (AE13)", lines.joined(separator: " | "))
                named.choose(.link)
                check(named.ignoredChoice == .link && named.footnote.contains("links to what xCloud’s git ignores") && named.footnote.contains("deletes only the links"),
                      "worktrees: Link chosen, the footnote says what is shared and that removing the worktree deletes only the links (AE13)", named.footnote)
                named.pressCreate()
                let path = code + "/xCloud-wt-linked"
                _ = await wait(30) { worktreeWindow(path) != nil }
                made.append(path)
                func target(_ name: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: path + "/" + name) }
                func kind(_ name: String) -> mode_t? {
                    var info = stat()
                    return lstat(path + "/" + name, &info) == 0 ? info.st_mode & S_IFMT : nil
                }
                // .bin's link leads out of .bin: made again as it is, in a folder of its own, so it leads within the new worktree.
                let links = [".env": "../xCloud/.env", "build": "../xCloud/build", "node_modules/vite": "../../xCloud/node_modules/vite",
                             "node_modules/.bin/vite": "../vite/bin/vite.js", "vendor/autoload.php": "../../xCloud/vendor/autoload.php"]
                let wrong = links.filter { target($0.key) != $0.value }.map(\.key).sorted()
                let folders = kind("node_modules") == S_IFDIR && kind("node_modules/.bin") == S_IFDIR && kind("vendor") == S_IFDIR
                check(wrong.isEmpty && folders && read(path + "/node_modules/.bin/vite") == "#!/usr/bin/env node\n",
                      "worktrees: .env and build are one link each, relative; node_modules and vendor are folders holding a link for each thing in them, .bin's link made again as it is (AE13)",
                      "wrong: \(wrong)")
                let absent = ["debug.log", "public/hot", "public/storage", ".claude/worktrees/agent-x"].filter { kind($0) != nil }
                let status = sh(path, "status", "--porcelain")
                check(absent.isEmpty && status.isEmpty, "worktrees: what Copy leaves out isn't linked, and git sees no change there (AE13)",
                      "present: \(absent), status: \(status)")
                _ = await wait(5) { GitToast.text?.contains("ignored item") == true }
                check(GitToast.text?.contains("; linked ") == true, "worktrees: the notice counts what was linked (AE13)", GitToast.text ?? "no notice")
                if let linked = worktreeWindow(path) {
                    let sidebar = linked.sidebar
                    _ = await wait(10) { sidebar.root?.children?.contains { $0.name == "build" } == true }
                    sidebar.outline.layoutSubtreeIfNeeded()
                    let node = sidebar.root?.children?.first { $0.name == "build" }
                    let cell = node.flatMap { sidebar.outline.view(atColumn: 0, row: sidebar.outline.row(forItem: $0), makeIfNecessary: true) as? FileCellView }
                    check(cell?.showsLinkMark == true && cell?.tipText.contains("Linked to " + canonicalPath(repo) + "/build") == true,
                          "worktrees: the sidebar marks the link and says where it leads (AE13)", cell?.tipText ?? "no row")
                    linked.window?.performClose(nil)
                    _ = await wait(5) { worktreeWindow(path) == nil }
                }
                window.makeKeyAndOrderFront(nil)
                actions.openInNewWorktree(.branch("fix/7050-pr"))
                if let next = await sheet() {
                    check(next.ignoredChoice == .link, "worktrees: Link is remembered for the repository (AE13)")
                    next.pressCancel()
                }
                // Removed: the links go, and what they led to stays.
                _ = await rows("")
                run(menu("worktree xCloud-wt-linked")?.items.first { $0.title == "Remove Worktree…" })
                if await press("Remove", within: 10) {
                    let removed = await wait(15) { !fm.fileExists(atPath: path) }
                    let kept = read(repo + "/.env") == "SECRET=1\n" && read(repo + "/build/app.js") == "built\n"
                        && read(repo + "/node_modules/vite/bin/vite.js") == "#!/usr/bin/env node\n" && read(repo + "/vendor/autoload.php") == "<?php\n"
                        && (try? fm.destinationOfSymbolicLink(atPath: repo + "/node_modules/.bin/vite")) == "../vite/bin/vite.js"
                    check(removed && kept, "worktrees: Remove Worktree deletes the links and never what they lead to: xCloud's files are all there (AE13)",
                          ((try? fm.contentsOfDirectory(atPath: repo)) ?? []).sorted().joined(separator: ", "))
                    if removed { made.removeAll { $0 == path } }
                } else {
                    check(false, "worktrees: Remove Worktree… asks before it removes the linked worktree (AE13)", sheetText(window))
                }
                popup.close()
            }
        }
        if let savedCopies { UserDefaults.standard.set(savedCopies, forKey: "worktreeCopiesIgnored") } else { UserDefaults.standard.removeObject(forKey: "worktreeCopiesIgnored") }
        if let savedChoices { UserDefaults.standard.set(savedChoices, forKey: "worktreeIgnoredFiles") } else { UserDefaults.standard.removeObject(forKey: "worktreeIgnoredFiles") }
        write(exclude, excludeBefore)
        for name in ["node_modules", "vendor", "public", "build"] { try? fm.removeItem(atPath: repo + "/" + name) }
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // AE8: a post-checkout hook exits 1 after the folder is made: its window opens, with the hook's words over it.
        write(hooks + "/post-checkout", "#!/bin/sh\necho hook says no\nexit 1\n")
        chmod(hooks + "/post-checkout", 0o755)
        if let actions = await actions() {
            actions.openInNewWorktree(.branch("fix/hooked"))
            if let named = await sheet() {
                named.pressCreate()
                let path = code + "/xCloud-wt-hooked"
                let shown = await wait(30) { worktreeWindow(path)?.window?.attachedSheet != nil }
                made.append(path)
                let hooked = worktreeWindow(path)?.window
                check(shown && hooked.map(sheetText)?.contains("hook says no") == true,
                      "worktrees: when a hook fails after the folder is made, its window opens with the hook's output (AE8)", hooked.map(sheetText) ?? "no window")
                if let hooked { await endSheets(over: hooked) }
                hooked?.performClose(nil)
            }
        }
        try? fm.removeItem(atPath: hooks + "/post-checkout")
        GitToast.dismiss()
        window.makeKeyAndOrderFront(nil)

        // AE3: the other callers' words, Update Anyway and Continue Anyway.
        sh(theirs, "fetch", "-q", "origin")
        sh(theirs, "switch", "-q", "-c", "fix/7611-3ds-confirm-bypass", "origin/fix/7611-3ds-confirm-bypass")
        write(theirs + "/b.txt", "theirs\n")
        sh(theirs, "add", "b.txt")
        sh(theirs, "commit", "-qm", "Theirs")
        sh(theirs, "push", "-q", "origin", "fix/7611-3ds-confirm-bypass")
        if let actions = await actions() {
            actions.updateProject()
            let offered = await wait(20) { sheetButtons(window).contains { $0.title == "Update Anyway" } }
            check(offered && sheetButtons(window).map(\.title) == ["Update Anyway", "Cancel"] && sheetText(window).contains("Updating changes the files under it."),
                  "worktrees: Update Project under an agent asks “Update Anyway”, with no worktree button (AE3)", sheetButtons(window).map(\.title).joined(separator: ", "))
            _ = await press("Cancel")
        }
        // A cherry-pick stopped on a conflict, then Continue.
        sh(repo, "switch", "-q", "-c", "conflict-base", "main")
        write(repo + "/c.txt", "ours\n")
        sh(repo, "add", "c.txt")
        sh(repo, "commit", "-qm", "Ours")
        sh(repo, "switch", "-q", "-c", "conflict-theirs", "main")
        write(repo + "/c.txt", "theirs\n")
        sh(repo, "add", "c.txt")
        sh(repo, "commit", "-qm", "Theirs")
        sh(repo, "switch", "-q", head)
        let ourC = sh(repo, "rev-parse", "conflict-base"), theirC = sh(repo, "rev-parse", "conflict-theirs")
        sh(repo, "cherry-pick", ourC)
        sh(repo, "cherry-pick", theirC)
        if let actions = await actions(), popup.model?.inProgress == .cherryPick {
            actions.inProgress(["--continue"])
            let offered = await wait(8) { sheetButtons(window).contains { $0.title == "Continue Anyway" } }
            check(offered && sheetText(window).contains("Continuing changes the files under it."),
                  "worktrees: Continue under an agent asks “Continue Anyway”, “Continuing changes the files under it.” (AE3)", sheetText(window))
            _ = await press("Cancel")
        } else {
            check(false, "worktrees: a cherry-pick stopped on its conflict", sh(repo, "status", "--short"))
        }
        sh(repo, "cherry-pick", "--abort")
        sh(repo, "reset", "-q", "--keep", "HEAD~1")

        // AE10: Switch Anyway, and git refuses over the agent's changes: the follow-up offers Open in New Worktree….
        if let actions = await actions(), let conflicting = popup.model?.local("fix/conflicting") {
            actions.checkout(conflicting)
            _ = await press("Switch Anyway")
            let refused = await wait(15) { sheetText(window).contains("Your changes would be overwritten") }
            check(refused && sheetButtons(window).map(\.title) == ["Open in New Worktree…", "Cancel"],
                  "worktrees: when git refuses over the agent's changes, the follow-up offers Open in New Worktree… (AE10)",
                  sheetText(window) + " | " + sheetButtons(window).map(\.title).joined(separator: ", "))
            _ = await press("Cancel")
            check(sh(repo, "rev-parse", "--abbrev-ref", "HEAD") == head && sh(repo, "diff", "--stat") == changes, "worktrees: and nothing moved")
        }

        // AE11: Open in New Window twice on a row: one window.
        _ = await rows("")
        if let item = menu("worktree xCloud-wt-7027-sso")?.items.first(where: { $0.title == "Open in New Window" }) {
            worktreeWindow(sibling)?.window?.performClose(nil)
            _ = await wait(5) { worktreeWindow(sibling) == nil }
            run(item)
            _ = await wait(10) { worktreeWindow(sibling) != nil }
            _ = await rows("")
            run(menu("worktree xCloud-wt-7027-sso")?.items.first { $0.title == "Open in New Window" })
            await pause(1)
            let count = app.controllers.filter { $0.project == canonicalPath(sibling) }.count
            check(count == 1 && NSApp.keyWindow === worktreeWindow(sibling)?.window, "worktrees: Open in New Window twice brings one window forward (AE11)", "\(count) windows")
            check((UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []) == recentBefore, "worktrees: and leaves Recent Projects alone (D10)")
        } else {
            check(false, "worktrees: a worktree row has Open in New Window", menu("worktree xCloud-wt-7027-sso")?.items.map(\.title).joined(separator: ", ") ?? "no row")
        }
        popup.close()
        window.makeKeyAndOrderFront(nil)

        // AE9: Remove Worktree… is refused while its window is open, with Go There; once it is closed, it goes and the branch stays.
        _ = await rows("")
        run(menu("worktree xCloud-wt-7027-sso")?.items.first { $0.title == "Remove Worktree…" })
        let refused = await wait(10) { sheetText(window).contains("can’t be removed now") }
        check(refused && sheetText(window).contains("The window “xCloud ▸ 7027-sso” is open on it."), "worktrees: Remove Worktree… is refused while a window is open on it (AE9)",
              sheetText(window))
        _ = await press("Go There")
        check(await wait(5) { NSApp.keyWindow === worktreeWindow(sibling)?.window }, "worktrees: Go There brings that window forward (AE9)")
        worktreeWindow(sibling)?.window?.performClose(nil)
        _ = await wait(5) { worktreeWindow(sibling) == nil }
        window.makeKeyAndOrderFront(nil)
        _ = await rows("")
        run(menu("worktree xCloud-wt-7027-sso")?.items.first { $0.title == "Remove Worktree…" })
        if await press("Remove", within: 10) {
            let removed = await wait(15) { !fm.fileExists(atPath: sibling) }
            check(removed && !sh(repo, "branch", "--list", "fix/7027-sso").isEmpty, "worktrees: then Remove Worktree… deletes the folder and keeps the branch (AE9)",
                  sh(repo, "worktree", "list"))
            _ = await rows("7027")
            let delete = menu("fix/7027-sso")?.items.first { $0.title == "Delete…" }
            check(delete?.isEnabled == true, "worktrees: and the branch's Delete… is on again (AE9)", menu("fix/7027-sso")?.items.map(\.title).joined(separator: ", ") ?? "no row")
            made.removeAll { $0 == sibling }
        } else {
            check(false, "worktrees: Remove Worktree… asks before it removes a clean worktree", sheetText(window))
        }
        popup.close()
        GitToast.dismiss()

        // Done: the agent stopped, the windows closed, the worktrees and the folders gone.
        for tab in agentTabs { tab.view.send(txt: "\u{03}") }
        _ = await wait(5) { agentTabs.allSatisfy { !$0.status.running } }
        agentTabs = []
        for path in made { worktreeWindow(path)?.window?.performClose(nil) }
        holder.window?.performClose(nil)
        _ = await wait(5) { !app.controllers.contains { $0 === holder } }
        for path in made + [code + "/xcloud-wt-aichat"] { sh(repo, "worktree", "remove", "--force", path) }
        try? fm.removeItem(atPath: base)
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// A git command's output in `dir`, with an author of its own.
    private static func gitIn(_ git: String, _ dir: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
