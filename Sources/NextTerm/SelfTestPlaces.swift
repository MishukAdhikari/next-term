import AppKit
import NextTermCore

/// Where agents work, in a repository of its own with a worktree nested in it under .claude/worktrees, and a
/// stand-in Claude Code that moves its own process there while its shell stays in the repository's root.
/// The branch popup credits it to that worktree, and a checkout in the main one doesn't warn about it
/// (AE10); its tab gets the place mark only once the move has held, the header says "this tab:
/// fix/7027-sso", "this tab:" kept whole as the branch is cut, then the glyph, then nothing in a narrower
/// sidebar, and list_tabs says it is elsewhere (AE3, AE9). A switch from the branch popup marks the other
/// agent, which had a turn, with "you switched it", and not the one in the worktree, which had one too; Keep
/// Going from the tab's right-click menu clears that (AE2a). A Claude Code whose record says its shell cd'd
/// into the worktree is there, though its process stays in the root; a cd within the main checkout marks
/// nothing (AE11). Session records are made by hand, in a home of its own.
extension SelfTest {
    static func placeChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared, let git = GitRunner.locateGit() else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-places-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/xCloud", nested = repo + "/.claude/worktrees/pr-7050", bin = base + "/bin"
        let controlA = base + "/control-a", controlB = base + "/control-b", controlC = base + "/control-c"
        for folder in [repo, bin, controlA, controlB, controlC, base + "/home"] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        @discardableResult func sh(_ args: String...) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sh("init", "-q")
        try? "hi\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("add", "a.txt")
        sh("commit", "-qm", "One")
        sh("switch", "-q", "-c", "fix/7611-3ds")
        sh("branch", "fix/7050-pr")
        sh("worktree", "add", "-q", "-b", "fix/7027-sso", nested)
        // A stand-in for Claude Code: it works in the folder its control file names, once that appears, and
        // shows Claude's working hint while its working file is there.
        let script = """
        #!/bin/sh
        \(stopsOnCtrlC)
        while true; do
          if [ -f "$CTL/dir" ]; then cd "$(cat "$CTL/dir")"; rm -f "$CTL/dir"; fi
          if [ -f "$CTL/working" ]; then printf '\\r\\342\\234\\273 Working (esc to interrupt) %s' "$SECONDS"; else printf '\\r\\033[K> %s' "$SECONDS"; fi
          \(standInWait("0.3"))
        done

        """
        fm.createFile(atPath: bin + "/claude", contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        SessionStore.home = base + "/home"
        let holder = app.openWindow(directory: repo, project: canonicalPath(repo))
        var opened: [TerminalTab] = []
        defer {
            for tab in opened { tab.view.send(txt: "\u{03}") }
            SessionStore.home = sessionsHome
        }
        if !holder.isSidebarVisible { holder.toggleProjectSidebar(nil) }
        func index(_ tab: TerminalTab) -> Int { holder.groups.firstIndex { $0.contains(tab) } ?? -1 }
        func tip(_ tab: TerminalTab) -> String { holder.tabBar.toolTip(at: index(tab)) ?? "" }
        func marked(_ tab: TerminalTab) -> Bool { holder.tabBar.showsPlaceMark(at: index(tab)) }
        func start(_ tab: TerminalTab, control: String, named name: String) async {
            tab.userTitle = name
            _ = await wait(20) { tab.status.integrated }
            tab.view.send(txt: "CTL=\(ShellQuote.quote(control)) PATH=\(ShellQuote.quote(bin)):$PATH claude\r")
            _ = await wait(10) { tab.status.running && tab.status.kind == .agent }
        }

        // Claude Code in tab "seven": started in the root, then in the nested worktree, its shell still in the root.
        guard let seven = holder.tabs.first else { return check(false, "places: the repository's window has a tab") }
        opened.append(seven)
        await start(seven, control: controlA, named: "seven")
        // Placed in the root first, by Next Term's own look once a second: a first sight counts at once (an agent
        // started in a worktree is marked without a wait), and only a move from there waits to hold.
        func place(_ tab: TerminalTab) -> String? { AgentPlaces.shared.places[tab.id.uuidString].map { canonicalPath($0.checkout.path) } }
        let placed = await wait(10) { place(seven) == canonicalPath(repo) }
        check(seven.status.running && seven.status.kind == .agent && placed, "places: a stand-in Claude Code runs in the repository's root",
              "\(seven.status.command), placed in \(place(seven) ?? "nothing yet")")
        // The hold is counted from the move, which can't come before the control file that asks for it: no mark
        // until 3 s after it, watched from then on, however late the app is seen to have the move.
        let asked = Date()
        try? nested.write(toFile: controlA + "/dir", atomically: true, encoding: .utf8)
        var early: TimeInterval?
        func watchHold() { if early == nil, marked(seven) { early = Date().timeIntervalSince(asked) } }
        let moved = await wait(5) {
            watchHold()
            return canonicalPath(AgentPlaces.shared.agentFolder(of: seven)) == canonicalPath(nested)
        }
        check(moved && canonicalPath(seven.liveDirectory) == canonicalPath(repo),
              "places: the agent's folder is its own process's, not its shell's", "agent \(AgentPlaces.shared.agentFolder(of: seven)), shell \(seven.liveDirectory)")
        while early == nil, Date().timeIntervalSince(asked) < 2.8 {
            watchHold()
            await pause(0.05)
        }
        check(early == nil, "places: a move is not marked before it has held for 3 seconds",
              early.map { String(format: "marked %.1f s after the move was asked for: ", $0) + tip(seven) } ?? "")
        check(await wait(12) { marked(seven) }, "places: the tab of an agent in another checkout gets the place mark", tip(seven))
        check(tip(seven).contains("Claude Code works in worktree pr-7050, on fix/7027-sso. This window shows xCloud, on fix/7611-3ds."),
              "places: its tooltip names the agent, its worktree and branch, and what the window shows", tip(seven))
        check(holder.tabBar.spokenLabel(at: index(seven))?.contains("works in worktree pr-7050") == true,
              "places: VoiceOver says it too", holder.tabBar.spokenLabel(at: index(seven)) ?? "")

        // The header: "this tab: fix/7027-sso" after the branch, the glyph alone when narrow.
        let header = holder.sidebar.header
        holder.show(seven)
        let frame = header.frame, inset = header.inset
        header.inset = 70 // beside the window's buttons, as a sidebar on the left is
        func layOut(width: CGFloat) {
            header.setFrameSize(NSSize(width: width, height: frame.height))
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
        }
        // Laid out with `spare` points beside the whole branch name: the widths come from the header's own
        // thresholds, not from the font's metrics.
        func layOut(spare: CGFloat) {
            for _ in 0..<3 { layOut(width: header.frame.width + spare - header.tabPlaceSpare) } // the ⌘B hint may come or go
        }
        _ = await wait(3) { !header.tabPlace.isHidden }
        layOut(width: 520)
        check(header.tabPlace.shownText == "this tab: fix/7027-sso" && !header.tabPlace.isTruncated && !header.titleIsTruncated,
              "places: the header says “this tab: fix/7027-sso” after the window's own branch", "“\(header.tabPlace.shownText)”, \(header.tabPlace.frame)")
        check(header.tabPlace.toolTip?.contains("works in worktree pr-7050") == true, "places: and its tooltip has the facts", header.tabPlace.toolTip ?? "")
        let full = 6 + header.tabPlace.fullWidth, readable = 6 + header.tabPlace.readableWidth, glyph = 6 + TabPlaceView.glyphWidth
        layOut(spare: (full + readable) / 2)
        check(header.tabPlace.shownText == "this tab: fix/7027-sso" && header.tabPlace.isTruncated && header.tabPlace.prefixIsWhole && !header.titleIsTruncated,
              "places: with less room the branch is cut in the middle, and “this tab:” stays whole",
              "spare \(header.tabPlaceSpare), \(header.tabPlace.frame)")
        layOut(spare: (readable + glyph) / 2)
        check(header.tabPlace.showsGlyph && header.tabPlace.shownText.isEmpty && !header.titleIsTruncated
              && header.tabPlace.frame.minX >= header.titleFrame.maxX,
              "places: in a narrow sidebar the label shrinks to the glyph and the branch keeps its name",
              "spare \(header.tabPlaceSpare), “\(header.tabPlace.shownText)”, \(header.tabPlace.frame), name \(header.titleFrame)")
        layOut(spare: glyph / 2)
        check(!header.tabPlace.showsGlyph && header.tabPlace.frame.width == 0 && !header.titleIsTruncated,
              "places: narrower still, the glyph goes too and takes nothing from the branch",
              "spare \(header.tabPlaceSpare), \(header.tabPlace.frame), name \(header.titleFrame)")
        header.inset = inset
        layOut(width: frame.width)

        // list_tabs: its checkout, branch, and that it is elsewhere.
        let listed = MCPControl.describe(seven, in: holder, caller: nil)
        check(listed["checkout"] as? String == canonicalPath(nested) && listed["branch"] as? String == "fix/7027-sso" && listed["sync"] as? String == "elsewhere",
              "places: list_tabs gives an agent tab's checkout and branch, and that it is elsewhere",
              "\(listed["checkout"] ?? "-") \(listed["branch"] ?? "-") \(listed["sync"] ?? "-")")

        // The branch popup credits it to the worktree, and a checkout in the main one asks nothing about it.
        let popup = holder.branchPopup
        holder.showBranches(at: repo, query: "")
        let row = { popup.rowTitles.first { $0.hasPrefix("worktree pr-7050") } ?? "" }
        check(await wait(15) { !popup.isReading && row().hasPrefix("worktree pr-7050 · Claude Code: ") },
              "places: the popup's worktree row lists the agent working there, whose shell is elsewhere", popup.rowTitles.joined(separator: " | "))
        popup.close()
        func actions() async -> GitActions? {
            var made: GitActions?
            holder.withGit(at: repo) { made = $0 }
            _ = await wait(15) { made != nil }
            return made
        }
        if let actions = await actions(), let target = popup.model?.local("fix/7050-pr") {
            check(actions.agentsHere().isEmpty, "places: the agent guard finds no agent in the main checkout",
                  actions.agentsHere().map(\.title).joined(separator: ", "))
            actions.checkout(target)
            let switched = await wait(10) { sh("rev-parse", "--abbrev-ref", "HEAD") == "fix/7050-pr" }
            check(switched && holder.window?.attachedSheet == nil, "places: a checkout in the main checkout doesn't warn about the agent in the worktree",
                  sh("rev-parse", "--abbrev-ref", "HEAD"))
        } else {
            check(false, "places: the branch popup reads the repository")
        }
        GitToast.dismiss()

        // Seven has a turn in the worktree: were it counted in the main checkout, a switch there would mark it.
        try? "".write(toFile: controlA + "/working", atomically: true, encoding: .utf8)
        check(await wait(10) { seven.status.state == .working }, "places: the agent in the worktree has a turn", seven.status.state.rawValue)
        await pause(2)
        try? fm.removeItem(atPath: controlA + "/working")
        _ = await wait(10) { seven.status.state != .working }

        // Claude Code in tab "five", in the root: a turn, then idle. A switch from the popup is yours.
        let five = holder.addTab(directory: repo)
        opened.append(five)
        try? "".write(toFile: controlB + "/working", atomically: true, encoding: .utf8)
        await start(five, control: controlB, named: "five")
        check(await wait(10) { five.status.state == .working }, "places: the second agent has a turn", five.status.state.rawValue)
        await pause(2)
        try? fm.removeItem(atPath: controlB + "/working")
        _ = await wait(10) { five.status.state != .working }
        await pause(1.2)
        if let actions = await actions(), let target = popup.model?.local("fix/7611-3ds"), let window = holder.window {
            check(actions.agentsHere() == [five], "places: the agent guard finds the agent in the main checkout, and only it",
                  actions.agentsHere().map(\.title).joined(separator: ", "))
            actions.checkout(target)
            func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
            func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
            let asked = await wait(8) { window.attachedSheet.flatMap { $0.contentView.map(buttons) }?.contains { $0.title == "Switching Anyway" } == true }
            let text = window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: " ") ?? ""
            check(asked && text.contains("“five”") && !text.contains("“seven”"), "places: the guard asks about the agent in the main checkout, not the one in the worktree", text)
            window.attachedSheet?.contentView.map(buttons)?.first { $0.title == "Switching Anyway" }?.performClick(nil)
            _ = await wait(10) { sh("rev-parse", "--abbrev-ref", "HEAD") == "fix/7611-3ds" }
        }
        GitToast.dismiss()
        check(await wait(12) { marked(five) && tip(five).contains("you switched it") },
              "places: an agent that had a turn is marked when you switch its branch, “you switched it”", tip(five))
        check(tip(five).contains("The chat was on fix/7050-pr; xCloud is now on fix/7611-3ds"),
              "places: its tooltip says the branch the chat was on and the one checked out now", tip(five))
        check(!tip(seven).contains("chat was on"), "places: the agent in the worktree was not switched under", tip(seven))
        let fiveListed = MCPControl.describe(five, in: holder, caller: nil)
        check(fiveListed["sync"] as? String == "switched_under" && fiveListed["chat_branch"] as? String == "fix/7050-pr" && fiveListed["switched_by"] as? String == "you",
              "places: list_tabs says it was switched under, from which branch and by whom",
              "\(fiveListed["sync"] ?? "-") \(fiveListed["chat_branch"] ?? "-") \(fiveListed["switched_by"] ?? "-")")
        holder.show(five)
        _ = await wait(3) { header.tabPlace.place?.label == "chat was on fix/7050-pr" }
        header.inset = 70
        layOut(width: 520)
        check(header.tabPlace.shownText == "chat was on fix/7050-pr" && header.tabPlace.place?.hasChoices == true,
              "places: the header says “chat was on fix/7050-pr”, and a click offers Keep Going", header.tabPlace.shownText)
        header.inset = inset
        layOut(width: frame.width)
        // Keep Going from the tab's right-click menu, without the header.
        let menu = holder.terminalTabMenu(at: index(five))
        let keep = menu?.items.firstIndex { $0.title == "Keep Going on fix/7611-3ds" }
        check(keep == 0, "places: the right-click menu of a tab switched under leads with Keep Going",
              menu?.items.map(\.title).joined(separator: ", ") ?? "no menu")
        let sevenMenu = holder.terminalTabMenu(at: index(seven))?.items.map(\.title) ?? []
        check(!sevenMenu.contains { $0.hasPrefix("Keep Going") }, "places: an agent that is only elsewhere has no Keep Going", sevenMenu.joined(separator: ", "))
        if let menu, let keep { menu.performActionForItem(at: keep) }
        check(await wait(5) { !marked(five) }, "places: Keep Going clears the mark", tip(five))

        // Claude Code in tab "eleven", its process in the root; its transcript says where its shell went.
        let eleven = holder.addTab(directory: repo)
        opened.append(eleven)
        await start(eleven, control: controlC, named: "eleven")
        let pid = tcgetpgrp(eleven.view.process.childfd)
        let id = "5e55a0de-0000-4000-8000-0000000000c3", home = base + "/home"
        let project = home + "/.claude/projects/" + AgentSessions.claudeFolderName(repo)
        try? fm.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        try? #"{"pid": \#(pid), "sessionId": "\#(id)", "cwd": "\#(repo)"}"#.write(toFile: home + "/.claude/sessions/\(pid).json", atomically: true, encoding: .utf8)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func record(_ folders: [String]) {
            let lines = folders.map { #"{"type":"assistant","cwd":"\#($0)","timestamp":"\#(stamp.string(from: Date()))"}"# + "\n" }
            try? lines.joined().write(toFile: project + "/\(id).jsonl", atomically: true, encoding: .utf8)
        }
        record([repo + "/app/Http"])
        let inApp = await wait(5) { AgentPlaces.shared.agentFolder(of: eleven) == repo + "/app/Http" }
        await pause(4)
        check(inApp && !marked(eleven), "places: a cd within the main checkout, as the agent's record says, is no move",
              AgentPlaces.shared.agentFolder(of: eleven) + " " + tip(eleven))
        record([repo + "/app/Http", nested + "/app"])
        check(await wait(12) { marked(eleven) && tip(eleven).contains("works in worktree pr-7050") },
              "places: a cd into the nested worktree, as the agent's record says, is a move there though its process stays in the root",
              AgentPlaces.shared.agentFolder(of: eleven) + " " + tip(eleven))

        for tab in opened { tab.view.send(txt: "\u{03}") }
        _ = await wait(5) { opened.allSatisfy { !$0.status.running } }
        opened = []
        holder.window?.performClose(nil)
        _ = await wait(3) { !app.controllers.contains { $0 === holder } }
        sh("worktree", "remove", "--force", nested)
        try? fm.removeItem(atPath: base)
        c.window?.makeKeyAndOrderFront(nil)
    }
}
