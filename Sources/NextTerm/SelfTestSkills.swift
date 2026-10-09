import AppKit
import NextTermCore

/// The Skills library on a home folder of its own: the inventory, Settings › Skills, Unify and Undo.
/// The user's real skill folders are never read or written here.
extension SelfTest {
    static func skillsChecks() async {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-skills-\(getpid())").path
        let savedHome = SkillsStore.home
        SkillsStore.home = home
        defer {
            SkillsStore.home = savedHome
            try? FileManager.default.removeItem(atPath: home)
        }
        func skill(_ root: String, _ name: String, body: String) {
            let folder = (home as NSString).appendingPathComponent("\(root)/\(name)")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String? { try? String(contentsOfFile: (home as NSString).appendingPathComponent(path), encoding: .utf8) }
        func isLink(_ path: String) -> Bool {
            var info = stat()
            return lstat((home as NSString).appendingPathComponent(path), &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        }

        // The same skill copied by hand into three agents, and edited differently in each.
        skill(".claude/skills", "release-notes", body: "claude version")
        skill(".codex/skills", "release-notes", body: "codex version")
        skill(".commandcode/skills", "release-notes", body: "command code version")
        skill(".agents/skills", "tidy-prose", body: "shared")

        let view = SkillsSettingsView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let inventory = SkillsStore.inventory()
        let sync = inventory.rows.first { $0.name == "release-notes" }
        check(inventory.rows.count == 2 && sync?.health == .drifted, "skills: the inventory finds every agent's copies, and sees that they differ",
              inventory.rows.map { "\($0.name): \($0.health)" }.joined(separator: ", "))
        check(SkillsSettingsView.needsAttention(sync!) && SkillsSettingsView.stateText(sync!) == "3 copies differ",
              "skills: Settings › Skills marks it as needing attention", SkillsSettingsView.stateText(sync!))
        check(SkillsSettingsView.cellText(inventory.rows.first { $0.name == "tidy-prose" }!, agent: .claudeCode).0 == "—",
              "skills: a shared skill without a link is not seen by Claude Code, and says so")
        // It fits the Settings window (620 pt) without widening it, laid out as Settings shows it: a tab.
        let tabs = NSTabView()
        let tab = NSTabViewItem(identifier: "skills")
        tab.view = view
        tabs.addTabViewItem(tab)
        let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled], backing: .buffered, defer: true)
        probe.contentView = tabs
        probe.layoutIfNeeded()
        check(probe.frame.width <= 621, "skills: Settings › Skills fits the Settings window's width", "\(probe.frame.width)")
        tab.view = NSView() // the view goes on to the checks below on its own

        // Unify, keeping Claude Code's version.
        guard let winner = sync?.copies.first(where: { $0.root.kind == .claude }) else { return check(false, "skills: the Claude copy is found") }
        let steps = SkillUnify.plan(sync!, winner: winner, in: inventory, claude: .link)
        // While it runs, Settings offers nothing that would start another change (Undo would reverse
        // whatever is on top by then). Offered before it: an earlier change to undo, and the row selected.
        let shared = (home as NSString).appendingPathComponent(".agents/skills/tidy-prose")
        let claudeLink = (home as NSString).appendingPathComponent(".claude/skills/tidy-prose")
        await SkillsStore.apply([.link(at: claudeLink, to: shared)], title: "Link tidy-prose for Claude Code")
        view.selectForTest("release-notes", in: SkillsStore.inventory())
        let offered = view.undoButton.isEnabled && view.unifyButton.isEnabled
        let seen = WhileRunning()
        let watcher = seen.watch { !view.undoButton.isEnabled && !view.unifyButton.isEnabled }
        let applied = await SkillsStore.apply(steps, title: "Unify release-notes")
        NotificationCenter.default.removeObserver(watcher)
        if case .failure(let failure) = applied { check(false, "skills: Unify applies", failure.message) }
        check(offered && seen.held == true, "skills: Unify and Undo are offered, and held while a change runs",
              "offered=\(offered) held=\(String(describing: seen.held))")
        let after = SkillsStore.inventory().rows.first { $0.name == "release-notes" }
        check(read(".agents/skills/release-notes/SKILL.md")?.contains("claude version") == true && isLink(".claude/skills/release-notes"),
              "skills: Unify leaves one shared copy with the chosen version, linked for Claude Code")
        check(after?.isUnified == true && SkillAgent.allCases.allSatisfy { after?.load(for: $0).used?.root.kind != nil },
              "skills: and every agent loads that one copy", after.map { r in SkillAgent.allCases.map { "\($0): \(String(describing: r.load(for: $0).used?.path))" }.joined(separator: "; ") } ?? "none")
        check(read(".codex/skills/release-notes/SKILL.md") == nil && read(".commandcode/skills/release-notes/SKILL.md") == nil,
              "skills: the other copies are gone from the agents' folders")
        check(SkillsStore.lastChange?.title == "Unify release-notes", "skills: the change is remembered for Undo")

        // Undo puts every copy back as it was. Quitting meanwhile waits on the changes themselves (what
        // the quit path calls): when the wait returns, the Undo is on disk.
        let undoing = Task { await SkillsStore.undo() }
        var spins = 0
        while SkillsStore.running == 0, spins < 1000 { await Task.yield(); spins += 1 }
        let wasRunning = SkillsStore.running > 0
        SkillsStore.waitForChanges()
        check(wasRunning && read(".codex/skills/release-notes/SKILL.md")?.contains("codex version") == true,
              "skills: quitting during a change waits until it is on disk", "running=\(wasRunning)")
        if case .failure(let failure) = await undoing.value { check(false, "skills: Undo applies", failure.message) }
        check(read(".claude/skills/release-notes/SKILL.md")?.contains("claude version") == true && !isLink(".claude/skills/release-notes")
              && read(".codex/skills/release-notes/SKILL.md")?.contains("codex version") == true
              && read(".commandcode/skills/release-notes/SKILL.md")?.contains("command code version") == true
              && read(".agents/skills/release-notes/SKILL.md") == nil,
              "skills: Undo puts every copy back exactly, and removes what Unify made")
        check(SkillsStore.lastChange == nil, "skills: and there is nothing left to undo")

        await installChecks(home: home)
        await mcpChecks(home: home)
    }

    /// Agents asking through MCP: nothing happens without the user, one request at a time, a declined
    /// source stays declined, and a slow decision comes back as pending with an id to ask again with.
    static func mcpChecks(home: String) async {
        let manager = FileManager.default
        let savedWait = SkillsMCP.answerWithin
        SkillsMCP.answerWithin = 1
        defer {
            SkillsMCP.answerWithin = savedWait
            SkillsMCP.requests = [:]
            SkillsMCP.declined = []
            SkillsMCP.quietUntil = [:]
            SkillsMCP.askedCount = [:]
            try? manager.removeItem(at: SkillsStore.supportFolder) // its Trash folder too
        }
        func ask(_ tool: String, _ arguments: [String: Any]) async -> [String: Any] {
            await withCheckedContinuation { continuation in
                SkillsMCP.call(tool, arguments, caller: nil) { result in
                    let object = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any]
                    continuation.resume(returning: object ?? ["error": result.text, "isError": result.isError])
                }
            }
        }
        // An installed skill: a shared copy, linked for Claude Code.
        let shared = (home as NSString).appendingPathComponent(".agents/skills/notes-helper")
        try? manager.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try? "---\nname: notes-helper\ndescription: Keeps notes.\n---\nBody\n".write(toFile: shared + "/SKILL.md", atomically: true, encoding: .utf8)
        try? manager.createDirectory(atPath: (home as NSString).appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try? manager.createSymbolicLink(atPath: (home as NSString).appendingPathComponent(".claude/skills/notes-helper"), withDestinationPath: "../../.agents/skills/notes-helper")
        // Installed by Next Term: only installed skills can be asked away.
        let record = SkillRecord(name: "notes-helper", owner: "example-org", repo: "skills", path: "skills/notes-helper", ref: nil,
                                 commit: String(repeating: "a", count: 40), tree: "t", contentHash: "t", installedAt: Date(), linkedForClaude: true)
        try? manager.createDirectory(at: SkillsStore.supportFolder, withIntermediateDirectories: true)
        try? SkillRecord.encodeList([record]).write(to: URL(fileURLWithPath: SkillsInstaller.recordsFile))

        let listed = await ask("list_skills", [:])
        let skills = listed["skills"] as? [[String: Any]] ?? []
        let notes = skills.first { $0["name"] as? String == "notes-helper" }
        check((notes?["agents"] as? [String: String])?["claude-code"] == "loads", "skills mcp: list_skills shows each skill and which agent loads it", "\(listed)")

        let bad = await ask("install_skill", ["source": "https://gitlab.com/a/b"])
        check(bad["isError"] as? Bool == true, "skills mcp: a source that is not GitHub is refused at once")

        // The request waits for the user; the agent hears "pending" with an id, and nothing is fetched.
        let first = await ask("install_skill", ["source": "example-org/skills/skills/demo", "reason": "The user asked for it."])
        let request = SkillsMCP.open
        check(first["status"] as? String == "pending" && first["request_id"] as? String == request?.id,
              "skills mcp: an install request waits for the user, then answers pending with an id", "\(first)")
        let approval = request?.window
        check(approval?.approveButton.keyEquivalent.isEmpty == true && approval?.declineButton.keyEquivalent.isEmpty == true
              && approval?.window?.isKeyWindow == false && approval?.window?.isVisible == true,
              "skills mcp: the request window shows without taking the keyboard, and has no Return button")
        let busy = await ask("install_skill", ["source": "example-org/other"])
        check(busy["status"] as? String == "busy", "skills mcp: a second request while one is open is told the user is busy", "\(busy)")

        approval?.declineButton.performClick(nil)
        let answer = await ask("install_skill", ["request_id": first["request_id"] as? String ?? ""])
        let again = await ask("install_skill", ["source": "example-org/skills/skills/demo"])
        check(answer["status"] as? String == "declined" && again["status"] as? String == "declined" && SkillsMCP.open == nil,
              "skills mcp: declining answers the agent, and the same request stays declined", "\(answer) \(again)")
        // Another branch of the same repository, or another request from the same asker: still declined.
        let otherRef = await ask("install_skill", ["source": "https://github.com/example-org/skills/tree/v2/skills/demo"])
        let otherSource = await ask("install_skill", ["source": "example-org/third"])
        check(otherRef["status"] as? String == "declined" && otherSource["status"] as? String == "declined" && SkillsMCP.open == nil,
              "skills mcp: after a decline the asker is told declined for a while, whatever it asks", "\(otherRef) \(otherSource)")
        SkillsMCP.quietUntil = [:]

        let handMade = await ask("remove_skill", ["name": "plain-notes"])
        check(handMade["isError"] as? Bool == true, "skills mcp: a skill nobody installed can't be asked away")

        // Remove: the user approves; the shared copy and the Claude Code link go, and Undo brings them back.
        let removal = await ask("remove_skill", ["name": "notes-helper"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let removeWindow = SkillsMCP.open?.window
        // Once the removal is under way it can't be stopped, so Decline (which would say it was) is held.
        let declinable = removeWindow?.declineButton.isEnabled == true
        let seen = SelfTest.WhileRunning()
        let watcher = seen.watch { removeWindow?.declineButton.isEnabled == false && removeWindow?.stopButton?.isEnabled == false }
        removeWindow?.approveButton.performClick(nil)
        let removed = await ask("remove_skill", ["request_id": removal["request_id"] as? String ?? ""])
        NotificationCenter.default.removeObserver(watcher)
        check(removed["status"] as? String == "removed" && !manager.fileExists(atPath: shared),
              "skills mcp: a removal the user approves goes through, and the agent hears so", "\(removal) \(removed)")
        check(declinable && seen.held == true, "skills mcp: Decline is offered, and held once the removal runs",
              "declinable=\(declinable) held=\(String(describing: seen.held))")
        _ = await SkillsStore.undo()
        check(manager.fileExists(atPath: shared + "/SKILL.md"), "skills mcp: Undo puts the removed skill back")

        // Decline pressed while the removal is being worked out again: the agent hears "declined" and
        // nothing is removed.
        SkillsMCP.quietUntil = [:]
        let raced = await ask("remove_skill", ["name": "notes-helper"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let window = SkillsMCP.open?.window
        window?.approveButton.performClick(nil)
        window?.declineButton.performClick(nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let racedAnswer = await ask("remove_skill", ["request_id": raced["request_id"] as? String ?? ""])
        check(racedAnswer["status"] as? String == "declined" && manager.fileExists(atPath: shared + "/SKILL.md"),
              "skills mcp: a Decline during the removal's re-check removes nothing", "\(racedAnswer)")
        await skillsPolicyChecks(home: home)
    }

    /// Installing from a download, without the network: a commit's files as GitHub would send them.
    static func installChecks(home: String) async {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: SkillsStore.supportFolder) } // its Trash folder too
        func read(_ path: String) -> String? { try? String(contentsOfFile: (home as NSString).appendingPathComponent(path), encoding: .utf8) }
        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat((home as NSString).appendingPathComponent(path), &info) == 0
        }
        func download() -> (SkillsInstaller.Fetched, String) {
            let scratch = SkillsInstaller.downloads.appendingPathComponent(UUID().uuidString)
            let folder = scratch.appendingPathComponent("files/skills-0123456/skills/demo-skill").path
            try? manager.createDirectory(atPath: folder + "/scripts", withIntermediateDirectories: true)
            try? "---\nname: demo-skill\ndescription: A demo skill.\nlicense: Apache-2.0\n---\nUse it well.\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
            try? "#!/bin/sh\necho hi\n".write(toFile: folder + "/scripts/run.sh", atomically: true, encoding: .utf8)
            chmod(folder + "/scripts/run.sh", 0o755)
            let found = SkillsGitHub.Found(path: "skills/demo-skill", tree: GitHash.folder(folder) ?? "")
            let source = SkillSource(owner: "example-org", repo: "skills", path: "skills/demo-skill")
            let resolved = SkillsGitHub.Resolved(source: source, commit: String(repeating: "0123456789", count: 4), date: nil, skills: [found], truncated: false)
            let top = scratch.appendingPathComponent("files/skills-0123456").path
            let candidates = SkillsInstaller.check([found], top: top, repo: "skills")
            // The home facts, from the self-test's home, as a fetch reads them.
            let claude = SkillClaudeSettings.snapshot(home: home, keys: [])
            return (SkillsInstaller.Fetched(resolved: resolved, info: nil, scratch: scratch, candidates: candidates,
                                            lockPath: SkillLock.path(home: home, environment: [:]), inventory: SkillsStore.inventory(),
                                            editedSinceInstall: [], projects: [], claude: claude, codex: SkillServers.codexConfig(home: home)), folder)
        }

        // A hand-made copy of the name in Command Code's folder, and a lock file `npx skills` wrote.
        let handMade = (home as NSString).appendingPathComponent(".commandcode/skills/demo-skill")
        try? manager.createDirectory(atPath: handMade, withIntermediateDirectories: true)
        try? "---\nname: demo-skill\ndescription: Mine.\n---\nhand-made\n".write(toFile: handMade + "/SKILL.md", atomically: true, encoding: .utf8)
        let lockPath = SkillLock.path(home: home, environment: [:])
        let lockBefore = "{\n  \"version\": 3,\n  \"skills\": {\n    \"other\": { \"source\": \"example-org/other\", \"skillPath\": \"SKILL.md\", \"skillFolderHash\": \"abc\" }\n  }\n}\n"
        try? manager.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? lockBefore.write(toFile: lockPath, atomically: true, encoding: .utf8)

        let (fetched, _) = download()
        let candidate = fetched.candidates.first
        check(candidate?.installable == true && candidate?.review.flags.contains { $0.text.contains("executable") } == true,
              "skills: a downloaded skill matches its commit's tree hash, and its executable is flagged",
              candidate.map { "\($0.refusal ?? "-") \($0.review.flags.map(\.text))" } ?? "none")

        let sheet = SkillsReviewSheet(fetched: fetched) { _ in }
        check(sheet.installButton.title == "Replace and Install" && sheet.installButton.keyEquivalent.isEmpty && sheet.installButton.isEnabled,
              "skills: the review sheet offers Replace for a name already used, and Return never installs",
              "\(sheet.installButton.title) key=\(sheet.installButton.keyEquivalent.debugDescription) enabled=\(sheet.installButton.isEnabled)")
        check(sheet.textView.string.contains("Use it well."), "skills: the review sheet shows SKILL.md as written")
        check(!sheet.claudeLink.isHidden && sheet.choice.view.isHidden,
              "skills: a plain skill gets the checkbox for Claude Code's link, and no plugin popup",
              "checkbox hidden=\(sheet.claudeLink.isHidden) popup hidden=\(sheet.choice.view.isHidden)")

        guard let candidate else { return }
        if case .failure(let failure) = await SkillsInstaller.install([candidate], fetched: fetched, claude: ["demo-skill": .link]) {
            check(false, "skills: Install applies", failure.message)
        }
        let lock = (try? SkillLock.entries(at: lockPath).get()) ?? [:]
        check(read(".agents/skills/demo-skill/SKILL.md")?.contains("Use it well.") == true && exists(".claude/skills/demo-skill")
              && !exists(".commandcode/skills/demo-skill"),
              "skills: Install puts one shared copy in place, links it for Claude Code, and moves the old copy away")
        check(lock["demo-skill"]?.skillFolderHash == candidate.found.tree && lock["other"] != nil
              && SkillsInstaller.records().first?.commit == fetched.resolved.commit,
              "skills: the lock file of npx skills gets the entry (other entries kept), and Next Term records the commit")
        check(!manager.fileExists(atPath: fetched.scratch.path), "skills: the download is removed after installing")

        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills: Undo of the install applies", failure.message) }
        let lockAfter = try? String(contentsOfFile: lockPath, encoding: .utf8)
        check(!exists(".agents/skills/demo-skill") && !exists(".claude/skills/demo-skill") && read(".commandcode/skills/demo-skill/SKILL.md")?.contains("hand-made") == true
              && SkillLock.rawItem(lockAfter, name: "demo-skill") == nil && SkillLock.rawItem(lockAfter, name: "other") == SkillLock.rawItem(lockBefore, name: "other")
              && SkillsInstaller.records().isEmpty,
              "skills: Undo removes the install, its lock entry and record, and puts back the old copy")

        // Undo refuses when the installed skill was changed since: it would overwrite that.
        let (again, _) = download()
        _ = await SkillsInstaller.install(again.candidates, fetched: again, claude: ["demo-skill": .skip])
        try? "edited\n".write(toFile: (home as NSString).appendingPathComponent(".agents/skills/demo-skill/SKILL.md"), atomically: true, encoding: .utf8)
        let refused = await SkillsStore.undo()
        var refusedMessage = ""
        if case .failure(let failure) = refused { refusedMessage = failure.message }
        check(refusedMessage.contains("changed since") && read(".agents/skills/demo-skill/SKILL.md") == "edited\n",
              "skills: Undo refuses, and changes nothing, when the skill was edited since", refusedMessage)

        // A download whose files differ from the commit's is refused.
        let (tampered, folder) = download()
        try? "changed\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        let recheck = SkillsInstaller.check(tampered.resolved.skills, top: tampered.scratch.appendingPathComponent("files/skills-0123456").path, repo: "skills")
        check(recheck.first?.installable == false && recheck.first?.refusal?.contains("differ from the commit") == true,
              "skills: files that differ from the commit's tree are refused")
        tampered.discard()

        // The skill folders change while the review is open: Install refuses rather than doing what
        // the review never showed (a copy appearing in Codex's folder would be moved to the Trash).
        try? manager.removeItem(atPath: (home as NSString).appendingPathComponent(".agents/skills/demo-skill"))
        try? manager.removeItem(atPath: (home as NSString).appendingPathComponent(".claude/skills/demo-skill"))
        let (drift, _) = download()
        let codexCopy = (home as NSString).appendingPathComponent(".codex/skills/demo-skill")
        try? manager.createDirectory(atPath: codexCopy, withIntermediateDirectories: true)
        try? "---\nname: demo-skill\ndescription: Mine.\n---\ncodex\n".write(toFile: codexCopy + "/SKILL.md", atomically: true, encoding: .utf8)
        var driftMessage = ""
        if case .failure(let failure) = await SkillsInstaller.install(drift.candidates, fetched: drift, claude: ["demo-skill": .skip]) { driftMessage = failure.message }
        check(driftMessage.contains("changed since the review") && manager.fileExists(atPath: codexCopy + "/SKILL.md"),
              "skills: Install refuses when the skill folders changed since the review", driftMessage)
        drift.discard()
        try? manager.removeItem(atPath: codexCopy)

        // A download that no longer matches its commit ends the review: no Install button left on files that are gone.
        let (gone, goneFolder) = download()
        var answered: [String]?? = .none
        let goneSheet = SkillsReviewSheet(fetched: gone) { names in answered = .some(names) }
        try? "changed\n".write(toFile: goneFolder + "/SKILL.md", atomically: true, encoding: .utf8)
        goneSheet.installButton.performClick(nil)
        _ = await wait(10) { answered != nil }
        check(answered == .some(nil) && !manager.fileExists(atPath: gone.scratch.path),
              "skills: a review whose download changed ends instead of offering Install again", "\(String(describing: answered))")

        let window = SkillsWindowController()
        check(window.window?.title == "Skills" && SkillFeatured.list.count >= 10, "skills: Window › Skills opens with the Featured list")

        await pluginReviewChecks(home: home)
    }

    /// Looks at the window the moment a skill change starts, for checks that hold only while it runs.
    @MainActor final class WhileRunning {
        var held: Bool?

        func watch(_ test: @escaping @MainActor () -> Bool) -> NSObjectProtocol {
            NotificationCenter.default.addObserver(forName: SkillsStore.busyChanged, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated {
                    guard SkillsStore.running > 0, self.held == nil else { return }
                    self.held = test()
                }
            }
        }
    }
}
