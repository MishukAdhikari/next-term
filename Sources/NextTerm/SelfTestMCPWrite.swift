import AppKit
import NextTermCore

/// The MCP tools that change things, called through the local socket (`nxtrm mcp`) as a local agent calls
/// them: every change asks on the Mac, and Approve, Decline, no answer and Decline and Stop Asking each do
/// what they say. They work in a repository of their own inside the self-test's project, so the other
/// checks' git state is untouched.
extension SelfTest {
    static func mcpWriteChecks(_ c: TerminalWindowController, proj: URL) async {
        let server = MCPControlServer.shared
        guard server.isRunning, let mcp = MCPTestClient(socket: server.path) else { return check(false, "MCP writes: `nxtrm mcp` starts") }
        let client = WriteClient(mcp)
        let app = AppDelegate.shared!
        let fm = FileManager.default
        let savedWait = MCPWriteControl.answerWithin
        let savedProposalWait = MCPWriteControl.proposalAnswerWithin
        let savedFont = app.fontSize
        let savedSidebar = app.sidebarVisible
        // update-resume's put-back rule, if any, stays in place for the checks after these.
        let savedRules = MCPInputLine.rules
        let savedLimit = MCPControlServer.requestLimit
        MCPWriteControl.answerWithin = 20
        defer {
            mcp.close()
            MCPWriteControl.answerWithin = savedWait
            MCPWriteControl.proposalAnswerWithin = savedProposalWait
            MCPWriteControl.stopped = []
            MCPWriteControl.accepted = [:]
            MCPWriteControl.proposals = [:]
            MCPInputLine.rules = savedRules
            MCPControlServer.requestLimit = savedLimit
            app.setFontSize(savedFont)
            app.sidebarVisible = savedSidebar
        }
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])

        // A repository of its own, inside the open project; no global hooks or signing get in.
        let root = proj.appendingPathComponent("mcp-write")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root.appendingPathComponent(".no-hooks"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func put(_ name: String, _ text: String) { try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        @discardableResult
        func git(_ args: String...) -> String {
            guard let path = GitRunner.locateGit() else { return "" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-C", root.path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        put("notes.txt", "one\ntwo\n")
        put("staged.txt", "s\n")
        git("init", "-q", "-b", "main")
        git("config", "user.name", "T")
        git("config", "user.email", "t@t")
        git("config", "commit.gpgsign", "false")
        git("config", "core.hooksPath", root.appendingPathComponent(".no-hooks").path)
        put(".gitignore", ".no-hooks/\n")
        git("add", "-A")
        git("commit", "-qm", "start")
        // The window the tools pick for a file in the project: the one whose project holds it, the innermost.
        func holders() -> [TerminalWindowController] {
            app.controllers.filter { $0.project.map { proj.path == $0 || proj.path.hasPrefix($0 + "/") } ?? false }
        }
        if holders().isEmpty { _ = app.openFolder(proj.path, newWindow: false) }
        guard let pc = holders().max(by: { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }) else {
            return check(false, "MCP writes: the self-test's project is open")
        }
        let notes = root.appendingPathComponent("notes.txt").path

        // The catalogue: every tool tagged, the write tools not read-only.
        let listed = await mcp.call(2, "tools/list", [:])
        let tools = (listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let tags = Dictionary(tools.compactMap { tool -> (String, String)? in
            guard let name = tool["name"] as? String, let scope = (tool["_meta"] as? [String: Any])?["next-term/scope"] as? String else { return nil }
            return (name, scope)
        }, uniquingKeysWith: { a, _ in a })
        let everyTagged = tags.count == MCPServer.tools.count
        let writesTagged = tags["write_file"] == "write" && tags["commit"] == "write"
        let readsTagged = tags["read_tab"] == "read" && tags["settings_get"] == "read"
        check(everyTagged && writesTagged && readsTagged, "MCP writes: every tool is listed with its read or write tag", "\(tags.count) of \(MCPServer.tools.count)")

        // write_file: Decline writes nothing; the window says who asks, in whose words, and what changes.
        let declined = await client.asked("write_file", ["path": notes, "content": "one\nTWO\n", "reason": "Fix the second line."], .decline)
        let declinedRefused = declined.isError && declined.text.contains("Declined on the Mac")
        check(declinedRefused && read("notes.txt") == "one\ntwo\n", "MCP writes: write_file asks on the Mac first, and Decline writes nothing", declined.text)
        let namesAsker = declined.shown.contains("outside Next Term's tabs")
        let quotesAgent = declined.shown.contains("“Fix the second line.”")
        let showsChange = declined.shown.contains("notes.txt") && declined.shown.contains("+1 −1")
        check(namesAsker && quotesAgent && showsChange && declined.unkeyed,
              "MCP writes: the window names the asker, quotes the agent and shows the change, without taking the keyboard", declined.shown)
        let approved = await client.asked("write_file", ["path": notes, "content": "one\nTWO\n"], .approve)
        check(approved.approvedOnMac && read("notes.txt") == "one\nTWO\n", "MCP writes: write_file writes the file once the user approves", approved.text)

        // No answer: refused when the wait ends, and the window goes.
        MCPWriteControl.answerWithin = 2
        let unanswered = await client.asked("write_file", ["path": notes, "content": "late\n"], .none)
        MCPWriteControl.answerWithin = 20
        let unansweredRefused = unanswered.isError && unanswered.text.contains("No answer on the Mac within 2 seconds")
        let windowGone = MCPWriteControl.pending == nil && unanswered.window?.window?.isVisible == false
        check(unansweredRefused && windowGone && read("notes.txt") == "one\nTWO\n",
              "MCP writes: with no answer the change is refused and the window closes", unanswered.text)

        // One change waits at a time.
        let first = Task { await client.call("write_file", ["path": notes, "content": "first\n"]) }
        let shownFirst = await wait(30) { MCPWriteControl.pending?.window != nil }
        let second = await client.call("create_file", ["path": root.appendingPathComponent("second.txt").path, "content": "x"])
        MCPWriteControl.pending?.window?.declineButton.performClick(nil)
        _ = await first.value
        let secondRefused = second.isError && second.text.contains("Another change is waiting")
        check(shownFirst && secondRefused && read("second.txt") == nil,
              "MCP writes: a second change while one waits is refused, without a second window", second.text)

        // Refused before anyone is asked: secrets files, outside the projects, git hooks, a file with unsaved edits.
        put(".env.local", "TOKEN=x\n")
        let secret = await client.call("write_file", ["path": root.appendingPathComponent(".env.local").path, "content": "TOKEN=y\n"])
        let outside = await client.call("write_file", ["path": "/etc/hosts", "content": "x"])
        let secretRefused = secret.isError && secret.text.hasPrefix("Not written") && read(".env.local") == "TOKEN=x\n"
        let outsideRefused = outside.isError && outside.text.contains("outside")
        check(secretRefused && outsideRefused && MCPWriteControl.pending == nil,
              "MCP writes: a secrets file or one outside the open projects is refused without asking", secret.text + " / " + outside.text)
        let hook = await client.call("create_file", ["path": root.appendingPathComponent(".no-hooks/pre-commit").path, "content": "echo hi\n"])
        let hookRefused = hook.isError && hook.text.contains("git hook") && read(".no-hooks/pre-commit") == nil
        check(hookRefused && MCPWriteControl.pending == nil, "MCP writes: a file in the repository's hooks folder is refused without asking", hook.text)
        pc.openFile(URL(fileURLWithPath: notes))
        let editor = pc.editorArea.activeEditor
        editor?.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        let dirty = await wait(3) { editor?.document.isDirty == true }
        let unsaved = await client.call("write_file", ["path": notes, "content": "agent\n"])
        let unsavedRefused = unsaved.isError && unsaved.text.contains("unsaved edits")
        let notesKept = read("notes.txt") == "one\nTWO\n"
        check(dirty && unsavedRefused && notesKept && MCPWriteControl.pending == nil,
              "MCP writes: a file with unsaved edits in the editor is never written under them", unsaved.text)
        editor?.document.reload()

        // create_file: a new file and its folders, only once approved; never over one that exists.
        let guide = root.appendingPathComponent("docs/guide.md").path
        let notCreated = await client.asked("create_file", ["path": guide, "content": "# Guide\n"], .decline)
        check(notCreated.isError && !fm.fileExists(atPath: guide), "MCP writes: create_file asks first, and Decline creates nothing", notCreated.text)
        let created = await client.asked("create_file", ["path": guide, "content": "# Guide\n"], .approve)
        let exists = await client.call("create_file", ["path": notes, "content": "x"])
        let existsRefused = exists.isError && exists.text.contains("exists already")
        check(created.approvedOnMac && read("docs/guide.md") == "# Guide\n" && existsRefused,
              "MCP writes: create_file makes a new file once approved, and refuses one that exists", created.text + " / " + exists.text)

        // A write near the size limit reaches the app in one request, however much JSON escapes its text
        // (quotes and slashes double); a request over the socket's limit is answered with why.
        let big = root.appendingPathComponent("big.txt").path
        let bigCall = await client.asked("create_file", ["path": big, "content": String(repeating: "\"/", count: 2_100_000)], .decline)
        let bigAsked = bigCall.isError && bigCall.text.contains("Declined on the Mac")
        check(bigAsked && !fm.fileExists(atPath: big), "MCP writes: a 4 MB write of quotes and slashes reaches Next Term and asks", String(bigCall.text.prefix(300)))
        MCPControlServer.requestLimit = 100_000
        let tooLarge = await client.call("create_file", ["path": big, "content": String(repeating: "x", count: 200_000)])
        MCPControlServer.requestLimit = savedLimit
        let tooLargeAnswered = tooLarge.isError && tooLarge.text.contains("too large")
        check(tooLargeAnswered && MCPWriteControl.pending == nil, "MCP writes: a request over the socket's limit is answered with why", tooLarge.text)

        // propose_edit: the editor's diff, Accept or Reject, and the tool never writes.
        let rejectCall = Task { await client.call("propose_edit", ["path": notes, "old_text": "TWO", "new_text": "two again"]) }
        let rejectPane = await proposalPane(in: pc)
        rejectPane?.decide(false)
        if let rejectPane { pc.editorArea.close(rejectPane) }
        let rejected = await rejectCall.value
        let shownAsProposal = rejectPane?.title.contains("✻") == true
        let wasRejected = json(rejected.text)?["status"] as? String == "rejected"
        check(shownAsProposal && wasRejected && read("notes.txt") == "one\nTWO\n",
              "MCP writes: propose_edit opens the change in the editor's diff, and Reject changes nothing", rejected.text)
        MCPWriteControl.proposalAnswerWithin = 1
        let slow = await client.call("propose_edit", ["path": notes, "content": "one\ntwo\nthree\n"])
        let proposalID = json(slow.text)?["proposal_id"] as? String ?? ""
        let acceptPane = await proposalPane(in: pc)
        let another = await client.call("propose_edit", ["path": notes, "content": "another\n"])
        let oneOpen = pc.editorArea.proposals.filter { $0.proposal?.tag.hasPrefix("mcp:") == true && !$0.isDecided }.count == 1
        check(another.isError && another.text.contains("still open") && oneOpen,
              "MCP writes: an agent has one proposal open at a time", another.text)
        acceptPane?.decide(true)
        if let acceptPane { pc.editorArea.close(acceptPane) }
        let decided = await client.call("propose_edit", ["proposal_id": proposalID])
        MCPWriteControl.proposalAnswerWithin = 50
        let wasPending = json(slow.text)?["status"] as? String == "pending"
        let nowAccepted = json(decided.text)?["status"] as? String == "accepted"
        check(wasPending && nowAccepted && read("notes.txt") == "one\nTWO\n",
              "MCP writes: an undecided proposal answers pending with an id, and the accept comes back on it without a write", slow.text + " / " + decided.text)
        let afterAccept = await client.call("write_file", ["path": notes, "content": "one\ntwo\nthree\n"])
        let writtenUnasked = !afterAccept.isError && json(afterAccept.text)?["approved"] as? String == "accepted in the proposal"
        check(writtenUnasked && read("notes.txt") == "one\ntwo\nthree\n" && MCPWriteControl.pending == nil,
              "MCP writes: write_file of the accepted change goes through without asking again", afterAccept.text)

        // stage and commit, through Git Commands.
        put("staged.txt", "s\nmore\n")
        put("other.txt", "other\n")
        let staged = await client.asked("stage", ["paths": ["staged.txt"], "project": root.path], .approve)
        let notStaged = await client.asked("stage", ["paths": ["other.txt"], "project": root.path], .decline)
        let index = git("diff", "--cached", "--name-only")
        check(staged.approvedOnMac && notStaged.isError && index == "staged.txt", "MCP writes: stage adds the named file once approved, and Decline stages nothing", index)
        let head = git("rev-parse", "HEAD")
        let others = await client.call("commit", ["message": "Agent change", "paths": ["notes.txt"], "project": root.path])
        check(others.isError && others.text.contains("staged.txt") && MCPWriteControl.pending == nil,
              "MCP writes: commit refuses when other changes are staged, unless told", others.text)
        try? "0000000000000000000000000000000000000000\n".write(to: root.appendingPathComponent(".git/MERGE_HEAD"), atomically: true, encoding: .utf8)
        let merging = await client.call("commit", ["message": "Agent change", "include_staged": true, "project": root.path])
        try? fm.removeItem(at: root.appendingPathComponent(".git/MERGE_HEAD"))
        check(merging.isError && merging.text.contains("Merging is in progress"), "MCP writes: commit refuses during a merge", merging.text)
        let commitArguments: [String: Any] = ["message": "Agent change\n\nWith a body.", "paths": ["notes.txt"], "include_staged": true, "project": root.path]
        let refusedCommit = await client.asked("commit", commitArguments, .decline)
        let showedCommit = refusedCommit.shown.contains("on main") && refusedCommit.shown.contains("Nothing is pushed")
        check(refusedCommit.isError && git("rev-parse", "HEAD") == head && showedCommit,
              "MCP writes: a declined commit makes none, and the window showed the branch, the files and the message", refusedCommit.shown)
        let committed = await client.asked("commit", commitArguments, .approve)
        let files = git("show", "--name-only", "--format=", "HEAD")
        let sha = json(committed.text)?["committed"] as? String ?? "-"
        let subject = git("log", "-1", "--format=%s")
        let isHead = git("rev-parse", "HEAD").hasPrefix(sha)
        let notPushed = json(committed.text)?["pushed"] as? Bool == false
        check(committed.approvedOnMac && subject == "Agent change" && files == "notes.txt\nstaged.txt" && isHead && notPushed,
              "MCP writes: commit stages the named file and commits it with what was staged, once approved", committed.text + " / " + files)

        // Panes: a tab of their own in the project's window.
        let extra = pc.addTab(directory: root.path, select: false)
        _ = await wait(20) { extra.status.integrated }
        let extraID = extra.id.uuidString.lowercased()
        let front = pc.activeTab
        let noFocus = await client.asked("focus_tab", ["tab_id": extraID], .decline)
        check(noFocus.isError && pc.activeTab === front, "MCP writes: focus_tab asks first, and Decline leaves the keyboard where it is", noFocus.text)
        let focused = await client.asked("focus_tab", ["tab_id": extraID], .approve)
        check(focused.approvedOnMac && pc.activeTab === extra, "MCP writes: focus_tab puts the tab in front of its window with the keyboard", focused.text)
        let notSplit = await client.call("close_pane", ["tab_id": extraID])
        check(notSplit.isError && notSplit.text.contains("not split") && MCPWriteControl.pending == nil, "MCP writes: close_pane refuses a tab that is not split", notSplit.text)
        let noSplit = await client.asked("split_pane", ["tab_id": extraID, "direction": "down"], .decline)
        let split = await client.asked("split_pane", ["tab_id": extraID, "direction": "down"], .approve)
        let paneID = json(split.text)?["id"] as? String ?? ""
        let pane = pc.tabs.first { $0.id.uuidString.lowercased() == paneID }
        let group = pc.group(of: extra)
        let twoPanes = group?.panes.count == 2
        let paneInGroup = pane.map { group?.contains($0) == true } ?? false
        let keyboardStayed = group?.focused === extra
        check(noSplit.isError && split.approvedOnMac && twoPanes && paneInGroup && keyboardStayed,
              "MCP writes: split_pane opens a pane beside the tab once approved, without taking the keyboard", split.text)
        if let pane, let group {
            let notZoomed = await client.asked("zoom_pane", ["tab_id": paneID], .decline)
            check(notZoomed.isError && group.zoomed == nil, "MCP writes: zoom_pane asks first, and Decline zooms nothing", notZoomed.text)
            let zoomed = await client.asked("zoom_pane", ["tab_id": paneID], .approve)
            check(zoomed.approvedOnMac && group.zoomed === pane, "MCP writes: zoom_pane makes the pane fill its tab", zoomed.text)
            // Typing in the editor: bringing the panes back leaves the keyboard there.
            let editorView = editor?.textView
            let inEditor = editorView.map { pc.window?.makeFirstResponder($0) == true } ?? false
            let back = await client.asked("zoom_pane", ["tab_id": paneID, "zoomed": false], .approve)
            let keyboardKept = !inEditor || pc.window?.firstResponder === editorView
            let again = await client.call("zoom_pane", ["tab_id": paneID, "zoomed": false])
            let answeredAtOnce = !again.isError && again.text.contains("so already") && MCPWriteControl.pending == nil
            check(back.approvedOnMac && group.zoomed == nil && answeredAtOnce,
                  "MCP writes: zoomed false brings the panes back, and asking for what is so already asks nothing", back.text)
            check(keyboardKept, "MCP writes: zoomed false leaves the keyboard in the editor", "in editor: \(inEditor)")
            let kept = await client.asked("close_pane", ["tab_id": paneID, "force": true], .decline)
            let closed = await client.asked("close_pane", ["tab_id": paneID, "force": true], .approve)
            let paneGone = !pc.tabs.contains { $0 === pane } && group.panes.count == 1
            check(kept.isError && closed.approvedOnMac && paneGone, "MCP writes: close_pane closes the pane once approved, and the tab stays", closed.text)
        }

        // A tab whose input line is not the user's own (update-resume's put-back line plugs in here).
        MCPInputLine.rules = savedRules + [{ tab in tab === extra ? "That tab's line holds text Next Term put back; type in it first." : nil }]
        let typed = await client.call("send_to_tab", ["tab_id": extraID, "text": "echo hi"])
        let refocused = await client.call("focus_tab", ["tab_id": extraID])
        let notClosed = await client.call("close_tab", ["tab_id": extraID, "force": true])
        MCPInputLine.rules = savedRules
        let typedRefused = typed.isError && typed.text.contains("put back")
        let focusRefused = refocused.isError && refocused.text.contains("put back")
        let closeRefused = notClosed.isError && notClosed.text.contains("put back") && pc.tabs.contains { $0 === extra }
        check(typedRefused && focusRefused && closeRefused && MCPWriteControl.pending == nil,
              "MCP writes: send_to_tab, close_tab and the pane tools refuse a tab whose input line is not the user's own", typed.text + " / " + notClosed.text)
        pc.remove(extra)
        if let front { pc.show(front) }

        // set_layout, for the project's window; a call that changes nothing asks nothing.
        let position = app.terminalPosition.rawValue
        let sidebarWasShown = pc.isSidebarVisible
        if !sidebarWasShown { pc.setSidebarVisible(true) }
        let same = await client.call("set_layout", ["terminal_position": position, "project": proj.path])
        let nothingChanged = (json(same.text)?["changed"] as? [String])?.isEmpty == true
        check(!same.isError && nothingChanged && MCPWriteControl.pending == nil, "MCP writes: set_layout with nothing to change answers at once", same.text)
        let notHidden = await client.asked("set_layout", ["sidebar": "hidden", "project": proj.path], .decline)
        check(notHidden.isError && pc.isSidebarVisible, "MCP writes: set_layout asks first, and Decline leaves the layout", notHidden.text)
        let hidden = await client.asked("set_layout", ["sidebar": "hidden", "project": proj.path], .approve)
        let hiddenNow = !pc.isSidebarVisible
        let shown = await client.asked("set_layout", ["sidebar": "shown", "project": proj.path], .approve)
        check(hidden.approvedOnMac && hiddenNow && shown.approvedOnMac && pc.isSidebarVisible, "MCP writes: set_layout hides and shows the project sidebar", hidden.text)
        if !pc.editorArea.isHidden, !pc.terminalCollapsed {
            let folded = await client.asked("set_layout", ["terminal_folded": true, "project": proj.path], .approve)
            let foldedNow = pc.terminalCollapsed
            let unfolded = await client.asked("set_layout", ["terminal_folded": false, "project": proj.path], .approve)
            check(folded.approvedOnMac && foldedNow && unfolded.approvedOnMac && !pc.terminalCollapsed, "MCP writes: set_layout folds and unfolds the terminal", folded.text)
        }
        if let editor { pc.editorArea.close(editor) }
        if pc.isSidebarVisible != sidebarWasShown { pc.setSidebarVisible(sidebarWasShown) }

        // Settings: a short allowlist, each change asked about.
        let settings = await client.call("settings_get")
        let names = (json(settings.text)?["settings"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check(names == MCPSettings.allowlist.map(\.name) && !names.contains("agent_control"), "MCP writes: settings_get lists only the allowlist", settings.text.prefix(300).description)
        let forbidden = await client.call("settings_set", ["values": ["agent_control": false]])
        let forbiddenRefused = forbidden.isError && forbidden.text.contains("not a setting agents may change")
        check(forbiddenRefused && app.agentControl && MCPWriteControl.pending == nil, "MCP writes: settings_set refuses agent control without asking", forbidden.text)
        let bigger = Int(savedFont) + 1
        let noBigger = await client.asked("settings_set", ["values": ["font_size": bigger]], .decline)
        let fontKept = Int(app.fontSize) == Int(savedFont)
        let grown = await client.asked("settings_set", ["values": ["font_size": bigger]], .approve)
        let showedFont = grown.shown.contains("Font size: \(Int(savedFont)) → \(bigger)")
        check(noBigger.isError && fontKept && grown.approvedOnMac && Int(app.fontSize) == bigger && showedFont,
              "MCP writes: settings_set changes the font size once approved, showing the change", grown.shown)
        app.setFontSize(savedFont)

        // Decline and Stop Asking: that asker is refused without a window until Next Term quits, its
        // proposals and the writing of a proposal it had accepted too.
        let proposing = Task { await client.call("propose_edit", ["path": notes, "content": "accepted before the stop\n"]) }
        let stopPane = await proposalPane(in: pc)
        stopPane?.decide(true)
        if let stopPane { pc.editorArea.close(stopPane) }
        _ = await proposing.value
        let stop = await client.asked("write_file", ["path": notes, "content": "stop\n"], .stop)
        let after = await client.call("write_file", ["path": notes, "content": "stop\n"])
        let acceptedAfter = await client.call("write_file", ["path": notes, "content": "accepted before the stop\n"])
        let proposedAfter = await client.call("propose_edit", ["path": notes, "content": "after the stop\n"])
        let refusedAfter = [after, acceptedAfter, proposedAfter].allSatisfy { $0.isError && $0.text.contains("Decline and Stop Asking") }
        let noProposal = !pc.editorArea.proposals.contains { $0.proposal?.tag.hasPrefix("mcp:") == true && !$0.isDecided }
        let notesUnchanged = read("notes.txt") == "one\ntwo\nthree\n"
        check(stop.isError && refusedAfter && noProposal && notesUnchanged && MCPWriteControl.pending == nil,
              "MCP writes: after Decline and Stop Asking, the asker's changes and proposals are refused without a window", after.text + " / " + proposedAfter.text)
        MCPWriteControl.stopped = []
        MCPWriteControl.accepted = [:]

        // The remote door's two policies, called as the door calls them.
        func door(_ approval: MCPApproval, _ content: String, connection: String? = nil) async -> MCPServer.CallResult {
            await withCheckedContinuation { continuation in
                MCPControl.call("write_file", ["path": notes, "content": content], caller: nil, approval: approval,
                                requester: "the connection “Self-test”", connection: connection) { result in continuation.resume(returning: result) }
            }
        }
        let granted = await door(.preApprovedByGrant("g-selftest"), "granted\n", connection: "g-selftest")
        let grantNamed = json(granted.text)?["approved"] as? String == "by grant g-selftest"
        let grantWrote = read("notes.txt") == "granted\n"
        check(!granted.isError && grantNamed && grantWrote && MCPWriteControl.pending == nil,
              "MCP writes: a grant's change runs without a window, and says which grant", granted.text)
        let asking = Task { await door(.askOnMac, "asked\n", connection: "g-selftest") }
        let doorWindow = await wait(30) { MCPWriteControl.pending?.window != nil }
        let doorShown = texts(MCPWriteControl.pending?.window?.window?.contentView)
        MCPWriteControl.pending?.window?.declineButton.performClick(nil)
        let doorDeclined = await asking.value
        let namedConnection = doorShown.contains("the connection “Self-test”")
        check(doorWindow && namedConnection && doorDeclined.isError && read("notes.txt") == "granted\n",
              "MCP writes: askOnMac from the door asks on the Mac, naming the connection", doorShown)

        // A remote Decline and Stop Asking stops that connection by its grant id: not another connection of
        // the same name, and not the agents on this Mac.
        let stopping = Task { await door(.askOnMac, "a\n", connection: "g-a") }
        let stopShown = await wait(30) { MCPWriteControl.pending?.window != nil }
        MCPWriteControl.pending?.window?.stopButton?.performClick(nil)
        _ = await stopping.value
        let againA = await door(.askOnMac, "a\n", connection: "g-a")
        let otherB = Task { await door(.askOnMac, "b\n", connection: "g-b") }
        let bAsked = await wait(30) { MCPWriteControl.pending?.window != nil }
        MCPWriteControl.pending?.window?.declineButton.performClick(nil)
        _ = await otherB.value
        let local = await client.asked("write_file", ["path": notes, "content": "local\n"], .decline)
        let aStopped = againA.isError && againA.text.contains("Decline and Stop Asking")
        check(stopShown && aStopped && bAsked && local.window != nil && read("notes.txt") == "granted\n",
              "MCP writes: a remote Decline and Stop Asking stops that connection only", againA.text)
        MCPWriteControl.stopped = []
    }

    /// install_skill and remove_skill from the remote door: under a grant they run without a window and
    /// name the grant; asking on the Mac, a Decline and Stop Asking pauses that connection only. Run from
    /// skillsChecks' MCP checks, on their home folder with notes-helper installed.
    static func skillsPolicyChecks(home: String) async {
        let manager = FileManager.default
        let savedFetch = SkillsMCP.fetch
        defer { SkillsMCP.fetch = savedFetch }
        SkillsMCP.declined = []
        SkillsMCP.quietUntil = [:]
        SkillsMCP.askedCount = [:]
        let grant = MCPApproval.preApprovedByGrant("g-skills")
        func door(_ tool: String, _ arguments: [String: Any], _ approval: MCPApproval, _ connection: String?) async -> [String: Any] {
            await withCheckedContinuation { continuation in
                let requester = connection == nil ? nil : "the connection “Self-test”"
                MCPControl.call(tool, arguments, caller: nil, approval: approval, requester: requester, connection: connection) { result in
                    let object = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any]
                    continuation.resume(returning: object ?? ["error": result.text, "isError": result.isError])
                }
            }
        }
        // The final answer, asked for again with the request id while it is pending.
        func settled(_ tool: String, _ first: [String: Any]) async -> [String: Any] {
            var answer = first
            for _ in 0..<20 where answer["status"] as? String == "pending" {
                answer = await door(tool, ["request_id": answer["request_id"] as? String ?? ""], grant, "g-skills")
            }
            return answer
        }
        func windowShown() -> Bool { NSApp.windows.contains { $0.isVisible && $0.windowController is AgentApprovalWindow } }
        func exists(_ path: String) -> Bool { manager.fileExists(atPath: (home as NSString).appendingPathComponent(path)) }

        // Remove, under a grant.
        let removing = await door("remove_skill", ["name": "notes-helper"], grant, "g-skills")
        let removeWindow = windowShown()
        let removed = await settled("remove_skill", removing)
        let wasRemoved = removed["status"] as? String == "removed"
        let removedByGrant = removed["approved"] as? String == "by grant g-skills"
        check(wasRemoved && removedByGrant && !removeWindow && !exists(".agents/skills/notes-helper"),
              "skills mcp: under a remote grant remove_skill removes without a window, and names the grant", "\(removing) \(removed)")
        _ = await SkillsStore.undo()

        // Install, under a grant: the one skill a source holds; never several, nor over the user's own.
        SkillsMCP.fetch = { source in
            let names = source.path.isEmpty ? ["one-skill", "two-skill"] : [(source.path as NSString).lastPathComponent]
            return fakeDownload(names, source: source, home: home)
        }
        let installing = await door("install_skill", ["source": "example-org/skills/skills/grant-demo"], grant, "g-skills")
        let installWindow = windowShown()
        let installed = await settled("install_skill", installing)
        let wasInstalled = installed["status"] as? String == "installed"
        let installedByGrant = installed["approved"] as? String == "by grant g-skills"
        check(wasInstalled && installedByGrant && !installWindow && exists(".agents/skills/grant-demo/SKILL.md"),
              "skills mcp: under a remote grant install_skill installs without a window, and names the grant", "\(installing) \(installed)")
        _ = await SkillsStore.undo()
        let several = await settled("install_skill", await door("install_skill", ["source": "example-org/many"], grant, "g-skills"))
        let severalFailed = several["status"] as? String == "failed"
        let severalSaid = (several["note"] as? String)?.contains("holds 2 skills") == true
        check(severalFailed && severalSaid && !exists(".agents/skills/one-skill"), "skills mcp: under a grant a source of several skills installs none", "\(several)")
        let mine = (home as NSString).appendingPathComponent(".codex/skills/grant-mine")
        try? manager.createDirectory(atPath: mine, withIntermediateDirectories: true)
        try? "---\nname: grant-mine\ndescription: Mine.\n---\nmine\n".write(toFile: mine + "/SKILL.md", atomically: true, encoding: .utf8)
        let over = await settled("install_skill", await door("install_skill", ["source": "example-org/skills/skills/grant-mine"], grant, "g-skills"))
        let overFailed = over["status"] as? String == "failed"
        let overSaid = (over["note"] as? String)?.contains("only they decide") == true
        let mineKept = (try? String(contentsOfFile: mine + "/SKILL.md", encoding: .utf8))?.contains("mine") == true
        check(overFailed && overSaid && mineKept && !exists(".agents/skills/grant-mine"), "skills mcp: under a grant an install never replaces the user's own skill", "\(over)")
        try? manager.removeItem(atPath: mine)

        // Asking on the Mac: a connection's Decline and Stop Asking pauses that connection by its grant id,
        // not another of the same name, and not the agents on this Mac.
        let fromA = await door("install_skill", ["source": "example-org/a-one"], .askOnMac, "g-a")
        let windowA = SkillsMCP.open?.window
        let shownA = texts(windowA?.window?.contentView)
        windowA?.stopButton?.performClick(nil)
        let againA = await door("install_skill", ["source": "example-org/a-two"], .askOnMac, "g-a")
        let fromB = await door("install_skill", ["source": "example-org/b-one"], .askOnMac, "g-b")
        let windowB = SkillsMCP.open?.window
        windowB?.declineButton.performClick(nil)
        let local = await door("install_skill", ["source": "example-org/local-one"], .askOnMac, nil)
        let windowLocal = SkillsMCP.open?.window
        windowLocal?.declineButton.performClick(nil)
        let askedA = fromA["status"] as? String == "pending" && shownA.contains("the connection “Self-test”")
        let quietA = againA["status"] as? String == "declined"
        let askedB = fromB["status"] as? String == "pending" && windowB != nil
        let askedLocal = local["status"] as? String == "pending" && windowLocal != nil
        check(askedA && quietA && askedB && askedLocal, "skills mcp: a remote Decline and Stop Asking pauses that connection only",
              "\(fromA) \(againA) \(fromB) \(local)")
    }

    /// A download of these skills without the network, as GitHub would send them.
    private static func fakeDownload(_ names: [String], source: SkillSource, home: String) -> SkillsInstaller.Fetched {
        let manager = FileManager.default
        let scratch = SkillsInstaller.downloads.appendingPathComponent(UUID().uuidString)
        let top = scratch.appendingPathComponent("files/skills-0123456").path
        var found: [SkillsGitHub.Found] = []
        for name in names {
            let folder = top + "/skills/" + name
            try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? "---\nname: \(name)\ndescription: The \(name) skill.\nlicense: MIT\n---\nUse it.\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
            found.append(SkillsGitHub.Found(path: "skills/" + name, tree: GitHash.folder(folder) ?? ""))
        }
        let resolved = SkillsGitHub.Resolved(source: source, commit: String(repeating: "0123456789", count: 4), date: nil, skills: found, truncated: false)
        let candidates = SkillsInstaller.check(found, top: top, repo: source.repo)
        return SkillsInstaller.Fetched(resolved: resolved, info: nil, scratch: scratch, candidates: candidates,
                                       lockPath: SkillLock.path(home: home, environment: [:]), inventory: SkillsStore.inventory(),
                                       editedSinceInstall: [], projects: [])
    }

    /// The text of every label in a view, for checking what a window says.
    static func texts(_ view: NSView?) -> String {
        guard let view else { return "" }
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        for sub in view.subviews {
            let text = texts(sub)
            if !text.isEmpty { found.append(text) }
        }
        return found.joined(separator: "\n")
    }

    /// The proposal propose_edit opened in the window's editor, once it shows.
    private static func proposalPane(in controller: TerminalWindowController) async -> DiffPane? {
        _ = await wait(30) { controller.editorArea.proposals.contains { $0.proposal?.tag.hasPrefix("mcp:") == true && !$0.isDecided } }
        return controller.editorArea.proposals.first { $0.proposal?.tag.hasPrefix("mcp:") == true && !$0.isDecided }
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// Tool calls over `nxtrm mcp`, and the user's answer in the approval window while a call waits.
@MainActor
private final class WriteClient {
    enum Answer { case approve, decline, stop, none }

    struct Outcome {
        let text: String
        let isError: Bool
        /// The window that asked, if one did; what it said; whether it left the keyboard alone.
        var window: AgentApprovalWindow?
        var shown = ""
        var unkeyed = false
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }
        /// The change was made after Approve on the Mac.
        var approvedOnMac: Bool { !isError && json?["approved"] as? String == "on this Mac" }
    }

    private let mcp: MCPTestClient
    private var next = 100

    init(_ mcp: MCPTestClient) { self.mcp = mcp }

    func call(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool) {
        next += 1
        let reply = await mcp.call(next, "tools/call", ["name": name, "arguments": arguments], timeout: 60)
        let result = reply?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "(no answer: \(reply ?? [:]))"
        return (text, result?["isError"] as? Bool ?? true)
    }

    /// Calls a tool that asks on the Mac, and answers the window as the user would.
    func asked(_ name: String, _ arguments: [String: Any], _ answer: Answer) async -> Outcome {
        let call = Task { await self.call(name, arguments) }
        _ = await SelfTest.wait(30) { MCPWriteControl.pending?.window != nil }
        let window = MCPWriteControl.pending?.window
        SelfTest.check(window != nil, "MCP writes: \(name) asks on the Mac before it changes anything")
        let shown = SelfTest.texts(window?.window?.contentView)
        let unkeyed = window?.window?.isKeyWindow == false && window?.approveButton.keyEquivalent.isEmpty == true
        switch answer {
        case .approve: window?.approveButton.performClick(nil)
        case .decline: window?.declineButton.performClick(nil)
        case .stop: window?.stopButton?.performClick(nil)
        case .none: break
        }
        let result = await call.value
        return Outcome(text: result.text, isError: result.isError, window: window, shown: shown, unkeyed: unkeyed)
    }
}
