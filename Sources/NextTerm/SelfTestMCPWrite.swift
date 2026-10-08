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
        MCPWriteControl.answerWithin = 20
        defer {
            mcp.close()
            MCPWriteControl.answerWithin = savedWait
            MCPWriteControl.proposalAnswerWithin = savedProposalWait
            MCPWriteControl.stopped = []
            MCPWriteControl.accepted = [:]
            MCPWriteControl.proposals = [:]
            MCPInputLine.rules = []
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
        if !app.controllers.contains(where: { $0.project.map { proj.path == $0 || proj.path.hasPrefix($0 + "/") } ?? false }) {
            _ = app.openFolder(proj.path, newWindow: false)
        }
        guard let pc = app.controllers.first(where: { $0.project.map { proj.path == $0 || proj.path.hasPrefix($0 + "/") } ?? false }) else {
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
        check(tags.count == MCPServer.tools.count && tags["write_file"] == "write" && tags["commit"] == "write" && tags["read_tab"] == "read"
              && tags["settings_get"] == "read", "MCP writes: every tool is listed with its read or write tag", "\(tags.count) of \(MCPServer.tools.count)")

        // write_file: Decline writes nothing; the window says who asks, in whose words, and what changes.
        let declined = await client.asked("write_file", ["path": notes, "content": "one\nTWO\n", "reason": "Fix the second line."], .decline)
        check(declined.window != nil && declined.isError && declined.text.contains("Declined on the Mac") && read("notes.txt") == "one\ntwo\n",
              "MCP writes: write_file asks on the Mac first, and Decline writes nothing", declined.text)
        check(declined.shown.contains("outside Next Term's tabs") && declined.shown.contains("“Fix the second line.”")
              && declined.shown.contains("notes.txt") && declined.shown.contains("+1 −1") && declined.unkeyed,
              "MCP writes: the window names the asker, quotes the agent and shows the change, without taking the keyboard", declined.shown)
        let approved = await client.asked("write_file", ["path": notes, "content": "one\nTWO\n"], .approve)
        check(!approved.isError && approved.json?["approved"] as? String == "on this Mac" && read("notes.txt") == "one\nTWO\n",
              "MCP writes: write_file writes the file once the user approves", approved.text)

        // No answer: refused when the wait ends, and the window goes.
        MCPWriteControl.answerWithin = 2
        let unanswered = await client.asked("write_file", ["path": notes, "content": "late\n"], .none)
        MCPWriteControl.answerWithin = 20
        check(unanswered.isError && unanswered.text.contains("No answer on the Mac within 2 seconds") && read("notes.txt") == "one\nTWO\n"
              && MCPWriteControl.pending == nil && unanswered.window?.window?.isVisible == false,
              "MCP writes: with no answer the change is refused and the window closes", unanswered.text)

        // One change waits at a time.
        let first = Task { await client.call("write_file", ["path": notes, "content": "first\n"]) }
        let shownFirst = await wait(10) { MCPWriteControl.pending?.window != nil }
        let second = await client.call("create_file", ["path": root.appendingPathComponent("second.txt").path, "content": "x"])
        MCPWriteControl.pending?.window?.declineButton.performClick(nil)
        _ = await first.value
        check(shownFirst && second.isError && second.text.contains("Another change is waiting") && read("second.txt") == nil,
              "MCP writes: a second change while one waits is refused, without a second window", second.text)

        // Refused before anyone is asked: secrets files, outside the projects, a file with unsaved edits.
        put(".env.local", "TOKEN=x\n")
        let secret = await client.call("write_file", ["path": root.appendingPathComponent(".env.local").path, "content": "TOKEN=y\n"])
        let outside = await client.call("write_file", ["path": "/etc/hosts", "content": "x"])
        check(secret.isError && secret.text.hasPrefix("Not written") && read(".env.local") == "TOKEN=x\n" && outside.isError
              && outside.text.contains("outside") && MCPWriteControl.pending == nil,
              "MCP writes: a secrets file or one outside the open projects is refused without asking", secret.text + " / " + outside.text)
        pc.openFile(URL(fileURLWithPath: notes))
        let editor = pc.editorArea.activeEditor
        editor?.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        let dirty = await wait(3) { editor?.document.isDirty == true }
        let unsaved = await client.call("write_file", ["path": notes, "content": "agent\n"])
        check(dirty && unsaved.isError && unsaved.text.contains("unsaved edits") && MCPWriteControl.pending == nil && read("notes.txt") == "one\nTWO\n",
              "MCP writes: a file with unsaved edits in the editor is never written under them", unsaved.text)
        editor?.document.reload()

        // create_file: a new file and its folders; never over one that exists.
        let created = await client.asked("create_file", ["path": root.appendingPathComponent("docs/guide.md").path, "content": "# Guide\n"], .approve)
        let exists = await client.call("create_file", ["path": notes, "content": "x"])
        check(!created.isError && read("docs/guide.md") == "# Guide\n" && exists.isError && exists.text.contains("exists already"),
              "MCP writes: create_file makes a new file once approved, and refuses one that exists", created.text + " / " + exists.text)

        // propose_edit: the editor's diff, Accept or Reject, and the tool never writes.
        let rejectCall = Task { await client.call("propose_edit", ["path": notes, "old_text": "TWO", "new_text": "two again"]) }
        let rejectPane = await proposalPane(in: pc)
        rejectPane?.decide(false)
        if let rejectPane { pc.editorArea.close(rejectPane) }
        let rejected = await rejectCall.value
        check(rejectPane?.title.contains("✻") == true && json(rejected.text)?["status"] as? String == "rejected" && read("notes.txt") == "one\nTWO\n",
              "MCP writes: propose_edit opens the change in the editor's diff, and Reject changes nothing", rejected.text)
        MCPWriteControl.proposalAnswerWithin = 1
        let slow = await client.call("propose_edit", ["path": notes, "content": "one\ntwo\nthree\n"])
        let proposalID = json(slow.text)?["proposal_id"] as? String ?? ""
        let acceptPane = await proposalPane(in: pc)
        acceptPane?.decide(true)
        if let acceptPane { pc.editorArea.close(acceptPane) }
        let decided = await client.call("propose_edit", ["proposal_id": proposalID])
        MCPWriteControl.proposalAnswerWithin = 50
        check(json(slow.text)?["status"] as? String == "pending" && json(decided.text)?["status"] as? String == "accepted" && read("notes.txt") == "one\nTWO\n",
              "MCP writes: an undecided proposal answers pending with an id, and the accept comes back on it without a write", slow.text + " / " + decided.text)
        let afterAccept = await client.call("write_file", ["path": notes, "content": "one\ntwo\nthree\n"])
        check(!afterAccept.isError && json(afterAccept.text)?["approved"] as? String == "accepted in the proposal" && read("notes.txt") == "one\ntwo\nthree\n"
              && MCPWriteControl.pending == nil, "MCP writes: write_file of the accepted change goes through without asking again", afterAccept.text)

        // stage and commit, through Git Commands.
        put("staged.txt", "s\nmore\n")
        put("other.txt", "other\n")
        let staged = await client.asked("stage", ["paths": ["staged.txt"], "project": root.path], .approve)
        let notStaged = await client.asked("stage", ["paths": ["other.txt"], "project": root.path], .decline)
        let index = git("diff", "--cached", "--name-only")
        check(!staged.isError && notStaged.isError && index == "staged.txt", "MCP writes: stage adds the named file once approved, and Decline stages nothing", index)
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
        check(refusedCommit.isError && git("rev-parse", "HEAD") == head && refusedCommit.shown.contains("on main") && refusedCommit.shown.contains("Nothing is pushed"),
              "MCP writes: a declined commit makes none, and the window showed the branch, the files and the message", refusedCommit.shown)
        let committed = await client.asked("commit", commitArguments, .approve)
        let files = git("show", "--name-only", "--format=", "HEAD")
        let sha = json(committed.text)?["committed"] as? String ?? "-"
        check(!committed.isError && git("log", "-1", "--format=%s") == "Agent change" && files == "notes.txt\nstaged.txt"
              && git("rev-parse", "HEAD").hasPrefix(sha) && json(committed.text)?["pushed"] as? Bool == false,
              "MCP writes: commit stages the named file and commits it with what was staged, once approved", committed.text + " / " + files)

        // Panes: a tab of their own in the project's window.
        let extra = pc.addTab(directory: root.path, select: false)
        _ = await wait(20) { extra.status.integrated }
        let extraID = extra.id.uuidString.lowercased()
        let front = pc.activeTab
        let noFocus = await client.asked("focus_tab", ["tab_id": extraID], .decline)
        check(noFocus.isError && pc.activeTab === front, "MCP writes: focus_tab asks first, and Decline leaves the keyboard where it is", noFocus.text)
        let focused = await client.asked("focus_tab", ["tab_id": extraID], .approve)
        check(!focused.isError && pc.activeTab === extra, "MCP writes: focus_tab puts the tab in front of its window with the keyboard", focused.text)
        let notSplit = await client.call("close_pane", ["tab_id": extraID])
        check(notSplit.isError && notSplit.text.contains("not split") && MCPWriteControl.pending == nil, "MCP writes: close_pane refuses a tab that is not split", notSplit.text)
        let noSplit = await client.asked("split_pane", ["tab_id": extraID, "direction": "down"], .decline)
        let split = await client.asked("split_pane", ["tab_id": extraID, "direction": "down"], .approve)
        let paneID = json(split.text)?["id"] as? String ?? ""
        let pane = pc.tabs.first { $0.id.uuidString.lowercased() == paneID }
        let group = pc.group(of: extra)
        check(noSplit.isError && !split.isError && group?.panes.count == 2 && pane.map { group?.contains($0) == true } == true && group?.focused === extra,
              "MCP writes: split_pane opens a pane beside the tab once approved, without taking the keyboard", split.text)
        if let pane, let group {
            let zoomed = await client.asked("zoom_pane", ["tab_id": paneID], .approve)
            check(!zoomed.isError && group.zoomed === pane, "MCP writes: zoom_pane makes the pane fill its tab", zoomed.text)
            let back = await client.asked("zoom_pane", ["tab_id": paneID, "zoomed": false], .approve)
            let again = await client.call("zoom_pane", ["tab_id": paneID, "zoomed": false])
            check(!back.isError && group.zoomed == nil && !again.isError && again.text.contains("so already") && MCPWriteControl.pending == nil,
                  "MCP writes: zoomed false brings the panes back, and asking for what is so already asks nothing", back.text)
            let kept = await client.asked("close_pane", ["tab_id": paneID, "force": true], .decline)
            let closed = await client.asked("close_pane", ["tab_id": paneID, "force": true], .approve)
            check(kept.isError && !closed.isError && !pc.tabs.contains { $0 === pane } && group.panes.count == 1,
                  "MCP writes: close_pane closes the pane once approved, and the tab stays", closed.text)
        }

        // A tab whose input line is not the user's own (update-resume's put-back line plugs in here).
        MCPInputLine.rules = [{ tab in tab === extra ? "That tab's line holds text Next Term put back; type in it first." : nil }]
        let typed = await client.call("send_to_tab", ["tab_id": extraID, "text": "echo hi"])
        let refocused = await client.call("focus_tab", ["tab_id": extraID])
        MCPInputLine.rules = []
        check(typed.isError && typed.text.contains("put back") && refocused.isError && refocused.text.contains("put back") && MCPWriteControl.pending == nil,
              "MCP writes: send_to_tab and the pane tools refuse a tab whose input line is not the user's own", typed.text)
        pc.remove(extra)
        if let front { pc.show(front) }

        // set_layout, for the project's window; a call that changes nothing asks nothing.
        let position = app.terminalPosition.rawValue
        let sidebarWasShown = pc.isSidebarVisible
        let same = await client.call("set_layout", ["terminal_position": position, "project": proj.path])
        check(!same.isError && (json(same.text)?["changed"] as? [String])?.isEmpty == true && MCPWriteControl.pending == nil,
              "MCP writes: set_layout with nothing to change answers at once", same.text)
        let hidden = await client.asked("set_layout", ["sidebar": "hidden", "project": proj.path], .approve)
        let hiddenNow = !pc.isSidebarVisible
        let shown = await client.asked("set_layout", ["sidebar": "shown", "project": proj.path], .approve)
        check(!hidden.isError && hiddenNow && !shown.isError && pc.isSidebarVisible, "MCP writes: set_layout hides and shows the project sidebar", hidden.text)
        if !pc.editorArea.isHidden {
            let folded = await client.asked("set_layout", ["terminal_folded": true, "project": proj.path], .approve)
            let foldedNow = pc.terminalCollapsed
            let unfolded = await client.asked("set_layout", ["terminal_folded": false, "project": proj.path], .approve)
            check(!folded.isError && foldedNow && !unfolded.isError && !pc.terminalCollapsed, "MCP writes: set_layout folds and unfolds the terminal", folded.text)
        }
        if let editor { pc.editorArea.close(editor) }
        if pc.isSidebarVisible != sidebarWasShown { pc.setSidebarVisible(sidebarWasShown) }

        // Settings: a short allowlist, each change asked about.
        let settings = await client.call("settings_get")
        let names = (json(settings.text)?["settings"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check(names == MCPSettings.allowlist.map(\.name) && !names.contains("agent_control"), "MCP writes: settings_get lists only the allowlist", settings.text.prefix(300).description)
        let forbidden = await client.call("settings_set", ["values": ["agent_control": false]])
        check(forbidden.isError && forbidden.text.contains("not a setting agents may change") && app.agentControl && MCPWriteControl.pending == nil,
              "MCP writes: settings_set refuses agent control without asking", forbidden.text)
        let bigger = Int(savedFont) + 1
        let noBigger = await client.asked("settings_set", ["values": ["font_size": bigger]], .decline)
        let grown = await client.asked("settings_set", ["values": ["font_size": bigger]], .approve)
        check(noBigger.isError && !grown.isError && Int(app.fontSize) == bigger && grown.shown.contains("Font size: \(Int(savedFont)) → \(bigger)"),
              "MCP writes: settings_set changes the font size once approved, showing the change", grown.shown)
        app.setFontSize(savedFont)

        // Decline and Stop Asking: that asker is refused without a window until Next Term quits.
        let stop = await client.asked("write_file", ["path": notes, "content": "stop\n"], .stop)
        let after = await client.call("write_file", ["path": notes, "content": "stop\n"])
        check(stop.isError && after.isError && after.text.contains("Decline and Stop Asking") && MCPWriteControl.pending == nil && read("notes.txt") == "one\ntwo\nthree\n",
              "MCP writes: after Decline and Stop Asking, the asker's changes are refused without a window", after.text)
        MCPWriteControl.stopped = []

        // The remote door's two policies, called as the door calls them.
        func door(_ approval: MCPApproval, _ content: String) async -> MCPServer.CallResult {
            await withCheckedContinuation { continuation in
                MCPControl.call("write_file", ["path": notes, "content": content], caller: nil, approval: approval,
                                requester: "the connection “Self-test”") { result in continuation.resume(returning: result) }
            }
        }
        let granted = await door(.preApprovedByGrant("g-selftest"), "granted\n")
        check(!granted.isError && json(granted.text)?["approved"] as? String == "by grant g-selftest" && read("notes.txt") == "granted\n"
              && MCPWriteControl.pending == nil, "MCP writes: a grant's change runs without a window, and says which grant", granted.text)
        let asking = Task { await door(.askOnMac, "asked\n") }
        let doorWindow = await wait(10) { MCPWriteControl.pending?.window != nil }
        let doorShown = texts(MCPWriteControl.pending?.window?.window?.contentView)
        MCPWriteControl.pending?.window?.declineButton.performClick(nil)
        let doorDeclined = await asking.value
        check(doorWindow && doorShown.contains("the connection “Self-test”") && doorDeclined.isError && read("notes.txt") == "granted\n",
              "MCP writes: askOnMac from the door asks on the Mac, naming the connection", doorShown)
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
        _ = await wait(10) { controller.editorArea.proposals.contains { $0.proposal?.tag.hasPrefix("mcp:") == true && !$0.isDecided } }
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
        _ = await SelfTest.wait(10) { MCPWriteControl.pending?.window != nil }
        let window = MCPWriteControl.pending?.window
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
