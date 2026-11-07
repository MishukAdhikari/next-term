import AppKit
import CryptoKit
import NextTermCore

/// The approval panel and Always (NEXTTERM_SELFTEST_ONLY=secretsApproval, and in the secrets part): every state of the
/// panel with a screenshot of each (a tab agent's command, a command refused Always with its reason, a hub server at a
/// URL, two keys, mcp-remote with "Use as an MCP Server", a key that asks every time), each Remember choice, and Always
/// answering the next request in its scope with no panel while one outside it asks. Then a relaunch (the key and values
/// dropped) asks Touch ID once and no panel, a removal raises the vault's floor so the old file put back answers
/// nothing, and a file an agent wrote answers nothing. On the self-test's own temporary vault and folders only: the
/// agent stands in by its label and an identity of a system file, so no real agent, ~/.claude or ~/.codex is read.
extension SelfTest {
    static func secretsApprovalChecks() async {
        #if DEBUG
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }
        guard store.folder.url.path.hasPrefix(NSTemporaryDirectory()) || store.folder.url.path.hasPrefix(canonicalPath(NSTemporaryDirectory())),
              let presence = store.presence as? StandInPresence else {
            return check(false, "secrets approval: the self-test's store is on a temporary folder, with the stand-in presence check",
                         store.folder.url.path)
        }
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-secrets-approval-\(getpid())")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A repository with a linked worktree beside it, as git makes them; and a folder outside both.
        let repo = base.appendingPathComponent("app").path
        let worktree = base.appendingPathComponent("app-wt").path
        let src = repo + "/src"
        let outside = base.appendingPathComponent("elsewhere").path
        for folder in [src, outside] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try? Data("x\n".utf8).write(to: URL(fileURLWithPath: src + "/a.txt"))
        let git = GitRunner.locateGit() ?? "/usr/bin/git"
        let made = approvalGit(git, ["init", "-q"], in: repo) && approvalGit(git, ["add", "."], in: repo)
            && approvalGit(git, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "one"], in: repo)
            && approvalGit(git, ["worktree", "add", "-q", worktree, "-b", "side"], in: repo)
        check(made, "secrets approval: a repository with a linked worktree, made with git")
        let list = base.appendingPathComponent("mcp.json").path
        try? Data("{\"servers\":{}}\n".utf8).write(to: URL(fileURLWithPath: list))

        for (name, asks) in [("APPROVAL_KEY", false), ("SECOND_KEY", false), ("EVERY_KEY", true), ("API_TOKEN", false)] {
            _ = try? await store.perform(.add(name: name, purpose: "the approval panel\u{2019}s checks, \(name.lowercased())", purposeBy: .user,
                                              origin: .settings, writeOnly: false, value: SecretBytes(utf8: secretsValue("approval")),
                                              asksEveryUse: asks))
        }
        guard let stamp = SecretFileStamp.of("/usr/bin/true") else { return check(false, "secrets approval: a system file stands in") }
        let identity = SecretAgentIdentity(path: "/usr/bin/true", stamp: stamp, team: nil)
        let curl = ["curl", "-sS", "https://api.example.com/v1/status"]

        // A request as the socket builds one, from Codex in front of tab 2 of the project, with its Always offer.
        func command(_ words: [String], names: [String] = ["APPROVAL_KEY"], envNames: [String: String] = [:], folder: String = src,
                     warnings: [String] = []) -> SecretRequests.Request {
            let keys = names.map { SecretRequests.Key(name: $0, envName: envNames[$0] ?? $0) }
            let map = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0.envName) })
            let binding = SecretBinding(source: .wrapper, asker: "wrapper:approval:" + words.joined(separator: " "), program: "codex",
                                        command: words, keys: map, folder: folder)
            let request = SecretRequests.Request(binding: binding, keys: keys, command: words.map(SecretApprovalPanel.escaped).joined(separator: " "),
                                                 argv: words, folder: folder, warnings: warnings, agentWords: nil,
                                                 askedBy: approvalFacts(project: repo), program: words.first ?? "", isRemote: false)
            let resolved = SecretAlwaysFacts.resolve(words.first ?? "", path: "/usr/bin:/bin", folder: folder)
            request.always = SecretAlways.offer(agent: "Codex", identity: identity, door: .wrapper, words: words, keys: map, folder: folder,
                                                path: nil, resolved: resolved, warned: [:], warnings: warnings, summary: request.command)
            return request
        }
        let server = MCPHubServer(name: "docs", transport: .http, url: "https://mcp.example.com/mcp",
                                  headers: ["Authorization": "Bearer ${secret:API_TOKEN}"])
        // A hub server's need, from a tab in `folder`.
        func hub(folder: String) -> SecretRequests.Request {
            let binding = SecretBinding(source: .tool, asker: "approval-tab", program: server.name, command: ["mcp", server.name, server.url],
                                        keys: ["API_TOKEN": "API_TOKEN"], folder: folder, target: "mcp:" + list)
            let request = SecretRequests.Request(binding: binding, keys: [SecretRequests.Key(name: "API_TOKEN", envName: "API_TOKEN")],
                                                 command: server.url, argv: [], folder: folder, warnings: [], agentWords: nil,
                                                 askedBy: approvalFacts(project: repo), program: server.name, isRemote: false)
            request.reachesURL = true
            request.always = SecretAlways.offer(agent: "Codex", identity: identity, server: server, list: list,
                                                keys: ["API_TOKEN": "API_TOKEN"], folder: folder)
            return request
        }

        // 1. A fixed command from the agent in front of its tab: Remember offers the lasting choices and Always.
        let first = command(curl)
        let firstAnswers = SecretsAnswers()
        requests.ask(first) { firstAnswers.take($0) }
        guard let panel = first.panel, let window = panel.window else { return check(false, "secrets approval: a tab agent's command shows the panel") }
        let titles = panel.rememberPopUp?.itemTitles ?? []
        check(window.title == "Codex wants to use APPROVAL_KEY" && first.always?.refusal == nil
              && titles == ["Only this time", "For 15 minutes", "Until the Mac locks", "", "Always in app", "Always in this folder"]
              && panel.selectedHow == .once && panel.allowButton.keyEquivalent == "\r",
              "secrets approval: a fixed command offers Only this time (chosen), the lasting choices, then Always in the project and the folder",
              "\(window.title): \(titles), \(first.always?.refusal ?? "")")
        let card = texts(window.contentView)
        check(card.contains("Codex in a Next Term tab in app") && card.contains("app \u{203A} src") && card.contains("Who") && card.contains("For"),
              "secrets approval: the card says who (the agent, in a Next Term tab in the project), the key, what for and where", card)
        await screenshot(window, suffix: "-approval-command")
        var notes: [SecretRequests.How: Bool] = [:]
        for how in [SecretRequests.How.fifteenMinutes, .untilLock, .alwaysFolder, .alwaysProject, .once] {
            panel.durationChoice[how]?.performClick(nil)
            notes[how] = panel.selectedHow == how
        }
        check(notes.values.allSatisfy { $0 } && notes.count == 5, "secrets approval: each Remember choice can be chosen", "\(notes)")
        panel.durationChoice[.alwaysProject]?.performClick(nil)
        await screenshot(window, suffix: "-approval-always-chosen")
        let callsBefore = presence.calls
        panel.allowButton.performClick(nil)
        let allowed = await wait(10) { secretsAllowed(firstAnswers.last)?.how == .always }
        let floor = store.held?.floor(of: SecretAlwaysFile.name) ?? 0
        check(allowed && presence.calls == callsBefore + 1 && SecretAlways.grants.count == 1 && floor >= 1
              && FileManager.default.fileExists(atPath: store.folder.path(SecretAlwaysFile.name)),
              "secrets approval: Always in app gives the key in one Touch ID, keeps the grant sealed and raises the vault's floor",
              "allowed \(allowed), \(presence.calls - callsBefore) checks, \(SecretAlways.grants.count) grants, floor \(floor)")

        // 2. The same command again, in its scope: no panel, no Touch ID.
        let again = command(curl)
        let againAnswers = SecretsAnswers()
        let calls = presence.calls
        requests.ask(again) { againAnswers.take($0) }
        check(again.panel == nil && secretsAllowed(againAnswers.last)?.how == .always && presence.calls == calls,
              "secrets approval: Always answers the same command in its scope with no panel and no Touch ID")

        // 3. Another command, or the same one in a folder outside the scope: the panel asks.
        let elsewhere = command(curl, folder: outside)
        requests.ask(elsewhere) { _ in }
        let changed = command(curl + ["--verbose"])
        let asksOutside = elsewhere.panel != nil
        elsewhere.panel?.declineButton.performClick(nil)
        await pause(0.2)
        requests.ask(changed) { _ in }
        let asksChanged = changed.panel != nil
        changed.panel?.declineButton.performClick(nil)
        check(asksOutside && asksChanged, "secrets approval: outside its scope, or with another argument, the panel asks again",
              "outside \(asksOutside), changed \(asksChanged)")
        await pause(0.2)

        // 4. A command Always is never offered for, with its reason.
        let unpinned = ["npx", "-y", "@acme/mcp-server"]
        let refused = command(unpinned, warnings: SecretRun.warnings(argv: unpinned))
        requests.ask(refused) { _ in }
        if let refusedWindow = refused.panel?.window {
            let shown = texts(refusedWindow.contentView)
            let refusedTitles = refused.panel?.rememberPopUp?.itemTitles ?? []
            check(shown.contains("Always isn\u{2019}t offered: npx -y fetches new code each time.") && !refusedTitles.contains { $0.hasPrefix("Always") },
                  "secrets approval: npx -y gets no Always, and the panel says why in a line", "\(refusedTitles)")
            await screenshot(refusedWindow, suffix: "-approval-refused")
        } else {
            check(false, "secrets approval: a refused command still shows the panel")
        }
        refused.panel?.declineButton.performClick(nil)
        await pause(0.2)

        // 5. Two keys.
        let two = command(curl, names: ["APPROVAL_KEY", "SECOND_KEY"])
        requests.ask(two) { _ in }
        check(two.panel?.window?.title == "Codex wants to use 2 keys", "secrets approval: two keys are \u{201C}2 keys\u{201D} in the title",
              two.panel?.window?.title ?? "")
        if let twoWindow = two.panel?.window { await screenshot(twoWindow, suffix: "-approval-two-keys") }
        two.panel?.declineButton.performClick(nil)
        await pause(0.2)

        // 6. mcp-remote: no Always for npx, and "Use as an MCP Server" to make it a URL server, where Always is safe.
        let bridge = ["npx", "-y", "mcp-remote@0.15.2", "https://mcp.example.com/mcp", "--header", "Authorization: Bearer ${NXTRM_API_TOKEN}"]
        let remote = command(bridge, names: ["API_TOKEN"], envNames: ["API_TOKEN": "NXTRM_API_TOKEN"])
        requests.ask(remote) { _ in }
        check(remote.panel?.serverButton?.title == "Use as an MCP Server\u{2026}" && remote.always?.bridge?.url == "https://mcp.example.com/mcp",
              "secrets approval: mcp-remote offers Use as an MCP Server", remote.always?.refusal ?? "")
        if let remoteWindow = remote.panel?.window { await screenshot(remoteWindow, suffix: "-approval-mcp-remote") }
        remote.panel?.declineButton.performClick(nil)
        await pause(0.2)

        // 7. A hub server at a URL: Always in the project holds in its linked worktree too; outside, it asks.
        let fromSrc = hub(folder: src)
        let hubAnswers = SecretsAnswers()
        requests.ask(fromSrc) { hubAnswers.take($0) }
        if let hubWindow = fromSrc.panel?.window {
            let shown = texts(hubWindow.contentView)
            check(shown.contains("docs \u{00B7} https://mcp.example.com/mcp") && fromSrc.panel?.durationChoice[.alwaysProject] != nil,
                  "secrets approval: a hub server shows its name and URL, and offers Always", shown)
            await screenshot(hubWindow, suffix: "-approval-hub")
        }
        fromSrc.panel?.durationChoice[.alwaysProject]?.performClick(nil)
        fromSrc.panel?.allowButton.performClick(nil)
        _ = await wait(10) { secretsAllowed(hubAnswers.last) != nil }
        let fromWorktree = hub(folder: worktree)
        let worktreeAnswers = SecretsAnswers()
        requests.ask(fromWorktree) { worktreeAnswers.take($0) }
        let fromOutside = hub(folder: outside)
        requests.ask(fromOutside) { _ in }
        check(fromWorktree.panel == nil && secretsAllowed(worktreeAnswers.last)?.how == .always && fromOutside.panel != nil,
              "secrets approval: Always in app answers the hub server from its linked worktree with no panel, and asks outside it")
        fromOutside.panel?.declineButton.performClick(nil)
        await pause(0.2)

        // 8. A key that asks every time: Always is offered, and the panel says it becomes once each launch.
        let every = command(curl, names: ["EVERY_KEY"])
        let everyAnswers = SecretsAnswers()
        requests.ask(every) { everyAnswers.take($0) }
        let everyTitles = every.panel?.rememberPopUp?.itemTitles ?? []
        every.panel?.durationChoice[.alwaysFolder]?.performClick(nil)
        let everyShown = every.panel.map { texts($0.window?.contentView) } ?? ""
        check(everyTitles == ["Only this time", "", "Always in app", "Always in this folder"]
              && everyShown.contains("will ask once each time Next Term opens"),
              "secrets approval: a key that asks every time is offered Always, which the panel says asks once each launch", "\(everyTitles)")
        if let everyWindow = every.panel?.window { await screenshot(everyWindow, suffix: "-approval-every-time") }
        every.panel?.allowButton.performClick(nil)
        _ = await wait(10) { secretsAllowed(everyAnswers.last)?.how == .always }
        let everyAgain = command(curl, names: ["EVERY_KEY"])
        let everyAgainAnswers = SecretsAnswers()
        requests.ask(everyAgain) { everyAgainAnswers.take($0) }
        check(everyAgain.panel == nil && secretsAllowed(everyAgainAnswers.last)?.how == .always,
              "secrets approval: then that one command uses it with no panel until Next Term quits")

        // 9. A relaunch: no key or value held. The next request asks for Touch ID once, with no panel.
        SecretAlways.resetForSelfTest()
        let relaunched = command(curl)
        let relaunchedAnswers = SecretsAnswers()
        let beforeRelaunch = presence.calls
        requests.ask(relaunched) { relaunchedAnswers.take($0) }
        let answeredAfterRelaunch = await wait(10) { secretsAllowed(relaunchedAnswers.last)?.how == .always }
        check(answeredAfterRelaunch && relaunched.panel == nil && presence.calls == beforeRelaunch + 1,
              "secrets approval: after a relaunch, Always asks for Touch ID once and shows no panel",
              "\(presence.calls - beforeRelaunch) checks, panel \(relaunched.panel != nil)")

        // 10. Settings › Secrets lists each grant under its key; Remove there (a Touch ID that raises the floor), then the old
        // file put back: it answers nothing.
        let path = store.folder.path(SecretAlwaysFile.name)
        let old = FileManager.default.contents(atPath: path)
        let first_ = SecretAlways.grants.first { $0.summary == first.command }
        AppDelegate.shared.showSecrets(nil)
        var removedInSettings = false
        if let controller = SecretsWindowController.shared, let settings = controller.window {
            let view = controller.secretsView
            view.reloadAlways()
            settings.layoutIfNeeded()
            let listed = texts(view.alwaysBox)
            check(listed.contains("Always: Codex \u{00B7} curl -sS https://api.example.com/v1/status \u{00B7} in app and its worktrees")
                  && listed.contains("Always: Codex \u{00B7} docs \u{00B7} https://mcp.example.com/mcp \u{00B7} in app and its worktrees")
                  && listed.contains("Last used") && listed.contains("EVERY_KEY"),
                  "secrets approval: Settings \u{203A} Secrets lists each Always approval under its key, with when it was last used", listed)
            view.alwaysBox.scrollToVisible(view.alwaysBox.bounds) // the list in sight, below the keys and settings
            await screenshot(settings, suffix: "-approval-settings")
            let remove = approvalButtons(view.alwaysBox).first { $0.identifier?.rawValue == first_?.id }
            remove?.performClick(nil)
            removedInSettings = await wait(10) { !SecretAlways.grants.contains { $0.id == first_?.id } }
            settings.close()
        }
        let raised = store.held?.floor(of: SecretAlwaysFile.name) ?? 0
        check(removedInSettings, "secrets approval: Remove in Settings \u{203A} Secrets removes it")
        if let old { try? old.write(to: URL(fileURLWithPath: path)) }
        SecretAlways.resetForSelfTest()
        let rolledBack = command(curl)
        requests.ask(rolledBack) { _ in }
        let asksAfterRollback = await wait(10) { rolledBack.panel != nil }
        check(first_ != nil && raised > floor && asksAfterRollback,
              "secrets approval: a removed grant stays removed: the old always.json put back is older than the vault's floor, so the panel asks",
              "floor \(floor) → \(raised), panel \(asksAfterRollback)")
        rolledBack.panel?.declineButton.performClick(nil)
        await pause(0.2)

        // 11. A file an agent wrote, sealed with a key of its own: nothing in it answers.
        let forgedGrant = SecretAlwaysGrant(agent: "Codex", identity: identity, door: .wrapper, keys: ["SECOND_KEY": "SECOND_KEY"],
                                            marks: ["SECOND_KEY": store.held?.entry(named: "SECOND_KEY")?.valueMark ?? ""],
                                            definition: command(curl, names: ["SECOND_KEY"]).always?.definition.digest ?? "",
                                            summary: "forged", scope: SecretAlwaysScope.at(repo, kind: .project)!)
        if let forged = try? SecretAlwaysFile.encode(SecretAlwaysFile.Body(grants: [forgedGrant], sequence: 999), key: SymmetricKey(size: .bits256)) {
            try? forged.write(to: URL(fileURLWithPath: path))
        }
        SecretAlways.resetForSelfTest()
        let byForgery = command(curl, names: ["SECOND_KEY"])
        requests.ask(byForgery) { _ in }
        let asksForForgery = await wait(10) { byForgery.panel != nil }
        check(asksForForgery, "secrets approval: a grant an agent wrote into always.json answers nothing: the panel asks")
        byForgery.panel?.declineButton.performClick(nil)
        await pause(0.2)
        try? FileManager.default.removeItem(atPath: path)
        #else
        note("secrets approval: skipped in a release build")
        #endif
    }

    /// Every button in `view`, deepest last.
    static func approvalButtons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(approvalButtons)
    }

    /// Next Term's facts about Codex in front of tab 2 of `project`.
    static func approvalFacts(project: String) -> SecretRequests.AskedBy {
        var facts = SecretRequests.AskedBy()
        facts.agent = "Codex"
        facts.checkedNxtrm = true
        facts.tab = "tab 2"
        facts.project = project
        facts.pid = 4242
        facts.executable = "/usr/bin/true"
        return facts
    }

    static func approvalGit(_ git: String, _ arguments: [String], in folder: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder, "GIT_CONFIG_NOSYSTEM": "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
