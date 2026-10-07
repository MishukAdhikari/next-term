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
        _ = view // built without errors on this home

        // Unify, keeping Claude Code's version.
        guard let winner = sync?.copies.first(where: { $0.root.kind == .claude }) else { return check(false, "skills: the Claude copy is found") }
        let steps = SkillUnify.plan(sync!, winner: winner, in: inventory)
        let applied = SkillsStore.apply(steps, title: "Unify release-notes")
        if case .failure(let failure) = applied { check(false, "skills: Unify applies", failure.message) }
        let after = SkillsStore.inventory().rows.first { $0.name == "release-notes" }
        check(read(".agents/skills/release-notes/SKILL.md")?.contains("claude version") == true && isLink(".claude/skills/release-notes"),
              "skills: Unify leaves one shared copy with the chosen version, linked for Claude Code")
        check(after?.isUnified == true && SkillAgent.allCases.allSatisfy { after?.load(for: $0).used?.root.kind != nil },
              "skills: and every agent loads that one copy", after.map { r in SkillAgent.allCases.map { "\($0): \(String(describing: r.load(for: $0).used?.path))" }.joined(separator: "; ") } ?? "none")
        check(read(".codex/skills/release-notes/SKILL.md") == nil && read(".commandcode/skills/release-notes/SKILL.md") == nil,
              "skills: the other copies are gone from the agents' folders")
        check(SkillsStore.lastChange?.title == "Unify release-notes", "skills: the change is remembered for Undo")

        // Undo puts every copy back as it was.
        if case .failure(let failure) = SkillsStore.undo() { check(false, "skills: Undo applies", failure.message) }
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
            for entry in SkillsStore.lastChange?.entries ?? [] where entry.kind == .trashed {
                if let trashed = entry.other { try? manager.removeItem(atPath: trashed) }
            }
            try? manager.removeItem(at: SkillsStore.supportFolder)
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

        // Remove: the user approves; the shared copy and the Claude Code link go, and Undo brings them back.
        let removal = await ask("remove_skill", ["name": "notes-helper"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        SkillsMCP.open?.window?.approveButton.performClick(nil)
        let removed = await ask("remove_skill", ["request_id": removal["request_id"] as? String ?? ""])
        check(removed["status"] as? String == "removed" && !manager.fileExists(atPath: shared),
              "skills mcp: a removal the user approves goes through, and the agent hears so", "\(removal) \(removed)")
        _ = SkillsStore.undo()
        check(manager.fileExists(atPath: shared + "/SKILL.md"), "skills mcp: Undo puts the removed skill back")
    }

    /// Installing from a download, without the network: a commit's files as GitHub would send them.
    static func installChecks(home: String) async {
        let manager = FileManager.default
        defer {
            // What the last change moved to the Trash belongs to this test's home: empty it from the Trash.
            for entry in SkillsStore.lastChange?.entries ?? [] where entry.kind == .trashed {
                if let trashed = entry.other { try? manager.removeItem(atPath: trashed) }
            }
            try? manager.removeItem(at: SkillsStore.supportFolder)
        }
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
            return (SkillsInstaller.Fetched(resolved: resolved, info: nil, scratch: scratch, candidates: candidates,
                                            lockPath: SkillLock.path(home: home, environment: [:])), folder)
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

        guard let candidate else { return }
        if case .failure(let failure) = SkillsInstaller.install([candidate], fetched: fetched, linkForClaude: true) {
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

        if case .failure(let failure) = SkillsStore.undo() { check(false, "skills: Undo of the install applies", failure.message) }
        check(!exists(".agents/skills/demo-skill") && !exists(".claude/skills/demo-skill") && read(".commandcode/skills/demo-skill/SKILL.md")?.contains("hand-made") == true
              && (try? String(contentsOfFile: lockPath, encoding: .utf8)) == lockBefore && SkillsInstaller.records().isEmpty,
              "skills: Undo removes the install and puts back the old copy and the lock file exactly")

        // Undo refuses when the installed skill was changed since: it would overwrite that.
        let (again, _) = download()
        _ = SkillsInstaller.install(again.candidates, fetched: again, linkForClaude: false)
        try? "edited\n".write(toFile: (home as NSString).appendingPathComponent(".agents/skills/demo-skill/SKILL.md"), atomically: true, encoding: .utf8)
        let refused = SkillsStore.undo()
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

        let window = SkillsWindowController()
        check(window.window?.title == "Skills" && SkillFeatured.list.count >= 10, "skills: Window › Skills opens with the Featured list")
    }
}
