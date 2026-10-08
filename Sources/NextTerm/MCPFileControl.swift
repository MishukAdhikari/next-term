import AppKit
import NextTermCore

/// propose_edit, write_file, create_file, stage and commit. The checks and the writes are MCPFileTools' and
/// MCPGitTools' (off the main thread); asking, the editor and Git Commands are here.
extension MCPWriteControl {
    /// git, for the approval window's summary of a file change and the check that a file is no git hook
    /// (GitWriter has its own).
    private static let diffGit = GitRunner.locateGit()

    // MARK: propose_edit

    /// A proposed edit waiting for the user's Accept or Reject in the editor.
    final class Proposal {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let change: MCPFileChange
        var answer: [String: Any]?
        var waiters: [(token: UUID, reply: Reply)] = []

        init(change: MCPFileChange) { self.change = change }
    }

    /// Proposals by id; answered ones are forgotten ten minutes after their answer.
    static var proposals: [String: Proposal] = [:]
    /// How long propose_edit waits for the decision before it answers `pending`.
    static var proposalAnswerWithin: TimeInterval = 50
    /// Changes the user accepted in a proposal, by real path: write_file or create_file with the same text
    /// writes them without asking again, until `until` and while the file is as it was.
    static var accepted: [String: (original: String?, content: String, until: Date)] = [:]

    static func proposeEdit(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        if let id = (arguments["proposal_id"] as? String)?.lowercased(), !id.isEmpty {
            guard let proposal = proposals[id] else {
                return reply(MCPControl.fail("No proposal with that id; answered ones are forgotten after ten minutes."))
            }
            return wait(proposal, reply: reply)
        }
        let projects = context.projects
        let git = Self.diffGit
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = MCPFileTools.prepareProposal(arguments, in: projects, git: git)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch prepared {
                    case .failure(let error): reply(MCPControl.fail(error.text))
                    case .success(let change): propose(change, context, reply: reply)
                    }
                }
            }
        }
    }

    private static func propose(_ change: MCPFileChange, _ context: Context, reply: @escaping Reply) {
        guard change.changesText else {
            return reply(MCPControl.ok(["status": "unchanged", "path": change.file.relative, "note": "The file has that text already; nothing to propose."]))
        }
        guard let controller = window(for: change.file.path, context) else {
            return reply(MCPControl.fail("No Next Term window is open to show the proposal in."))
        }
        let proposal = Proposal(change: change)
        proposals[proposal.id] = proposal
        let shown = DiffPane.Proposal(original: change.original ?? "", proposed: change.content, author: author(context),
                                      tag: "mcp:" + proposal.id, client: nil)
        controller.editorArea.openProposal(for: change.file.path, proposal: shown) { accepted, _ in
            decided(proposal, accepted: accepted)
        }
        wait(proposal, reply: reply)
    }

    /// The window the proposal opens in: the caller's, the one whose project holds the file, or the front one.
    private static func window(for path: String, _ context: Context) -> TerminalWindowController? {
        if let mine = context.caller.flatMap(MCPControl.controller(of:)) { return mine }
        let holders = AppDelegate.shared.controllers.filter { $0.project.map { path.hasPrefix($0 + "/") } ?? false }
        if let holder = holders.max(by: { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }) { return holder }
        return (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? AppDelegate.shared.controllers.last
    }

    /// The name on the proposal's tab: the caller's agent (“Claude”), or “An agent”.
    private static func author(_ context: Context) -> String {
        if context.isRemote { return "A remote agent" }
        guard let tab = context.caller, tab.status.running, !tab.status.program.isEmpty else { return "An agent" }
        let program = tab.status.program
        return program.prefix(1).uppercased() + program.dropFirst()
    }

    private static func decided(_ proposal: Proposal, accepted isAccepted: Bool) {
        guard proposal.answer == nil else { return }
        let change = proposal.change
        var answer: [String: Any] = ["status": isAccepted ? "accepted" : "rejected", "path": change.file.relative, "project": change.file.root]
        if isAccepted {
            accepted[change.file.path] = (change.original, change.content, Date().addingTimeInterval(600))
            let tool = change.isNew ? "create_file" : "write_file"
            answer["note"] = "The user accepted it; the file is not written yet. Write it with \(tool), the same path and the same content: it goes through without asking again for 10 minutes, while the file is as it was."
        } else {
            answer["note"] = "The user rejected it; nothing changed."
        }
        proposal.answer = answer
        let waiters = proposal.waiters
        proposal.waiters = []
        for waiter in waiters { waiter.reply(MCPControl.ok(answer)) }
        let id = proposal.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { MainActor.assumeIsolated { _ = proposals.removeValue(forKey: id) } }
    }

    /// Answers with the decision, or `pending` after `proposalAnswerWithin` seconds.
    private static func wait(_ proposal: Proposal, reply: @escaping Reply) {
        if let answer = proposal.answer { return reply(MCPControl.ok(answer)) }
        let token = UUID()
        proposal.waiters.append((token, reply))
        DispatchQueue.main.asyncAfter(deadline: .now() + proposalAnswerWithin) {
            MainActor.assumeIsolated {
                guard let index = proposal.waiters.firstIndex(where: { $0.token == token }) else { return }
                proposal.waiters.remove(at: index)
                reply(MCPControl.ok(["status": "pending", "proposal_id": proposal.id, "path": proposal.change.file.relative,
                                     "note": "The proposal is open in Next Term and the user has not decided yet. Call again with only proposal_id to keep waiting."]))
            }
        }
    }

    /// Whether the user accepted exactly this change in a proposal (used up by the write).
    private static func takeAccepted(_ change: MCPFileChange) -> Bool {
        guard let pass = accepted[change.file.path], pass.until > Date(), pass.original == change.original, pass.content == change.content else {
            return false
        }
        accepted[change.file.path] = nil
        return true
    }

    // MARK: write_file and create_file

    static func writeFile(_ arguments: [String: Any], _ context: Context, creating: Bool, reply: @escaping Reply) {
        let projects = context.projects
        let git = Self.diffGit
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = creating ? MCPFileTools.prepareCreate(arguments, in: projects, git: git)
                                    : MCPFileTools.prepareWrite(arguments, in: projects, git: git)
            guard case .success(let change) = prepared else {
                if case .failure(let error) = prepared { reply(MCPControl.fail(error.text)) }
                return
            }
            let summary = change.changesText ? MCPFileTools.summary(change, git: git) : ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { write(change, summary: summary, context, reply: reply) }
            }
        }
    }

    /// The editor's open copy of the file, if any.
    private static func openDocument(_ path: String) -> EditorDocument? {
        AppDelegate.shared.controllers.flatMap(\.editorArea.documents).first { $0.path == path || canonicalPath($0.path) == path }
    }

    private static func write(_ change: MCPFileChange, summary: String, _ context: Context, reply: @escaping Reply) {
        var answer: [String: Any] = ["path": change.file.relative, "project": change.file.root]
        guard change.changesText else {
            answer["written"] = false
            answer["note"] = "The file has that text already; nothing was written."
            return reply(MCPControl.ok(answer))
        }
        let unsaved = MCPControl.fail("\(change.file.relative) is open in the editor with unsaved edits, so nothing was written. Use propose_edit, or ask the user to save or discard them first.")
        if openDocument(change.file.path)?.isDirty == true { return reply(unsaved) }
        let name = (change.file.root as NSString).lastPathComponent
        let ask = Ask(title: change.isNew ? "An agent asks to create a file" : "An agent asks to change a file",
                      details: "\(change.isNew ? "Creates" : "Writes") \(change.file.relative) in \(name).\n\(summary)")
        let run: (String, AgentApprovalWindow?) -> Void = { approved, window in
            window?.finish()
            // Edited while the user was asked: their edits win.
            if openDocument(change.file.path)?.isDirty == true { return reply(unsaved) }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try MCPFileTools.write(change)
                } catch {
                    return reply(MCPControl.fail((error as? MCPToolError)?.text ?? error.localizedDescription))
                }
                answer["written"] = true
                answer["created"] = change.isNew
                answer["approved"] = approved
                reply(MCPControl.ok(answer))
                // An open copy follows the file at once, not at the next look.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { openDocument(change.file.path)?.checkDisk() }
                }
            }
        }
        if takeAccepted(change) { return run("accepted in the proposal", nil) }
        approve(ask, context, reply: reply, change: run)
    }

    // MARK: stage and commit

    static func git(_ tool: String, _ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        guard let git = GitWriter.git else {
            return reply(MCPControl.fail("git is not installed (Next Term looks in /opt/homebrew/bin, /usr/local/bin and the developer tools)."))
        }
        let projects = context.projects
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = tool == "commit" ? MCPGitTools.prepareCommit(arguments, in: projects, git: git)
                                            : MCPGitTools.prepareStage(arguments, in: projects, git: git)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch prepared {
                    case .failure(let error): reply(MCPControl.fail(error.text))
                    case .success(let plan): run(plan, git: git, context, reply: reply)
                    }
                }
            }
        }
    }

    private static func run(_ plan: MCPGitPlan, git: String, _ context: Context, reply: @escaping Reply) {
        let committing = plan.message != nil
        let ask = Ask(title: committing ? "An agent asks to commit" : "An agent asks to stage files", details: MCPGitTools.summary(plan))
        approve(ask, context, reply: reply) { approved, window in
            window?.setCommitted(true)
            DispatchQueue.global(qos: .userInitiated).async {
                let problem = MCPGitTools.changedSince(plan, git: git)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let problem {
                            window?.finish()
                            return reply(MCPControl.fail(problem.text))
                        }
                        runGit(plan, approved: approved, window: window, reply: reply)
                    }
                }
            }
        }
    }

    /// The approved plan through GitWriter: in Git Commands as typed, one at a time per repository.
    private static func runGit(_ plan: MCPGitPlan, approved: String, window: AgentApprovalWindow?, reply: @escaping Reply) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-mcp-git-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var steps: [[String]] = []
        if !plan.paths.isEmpty {
            let list = folder.appendingPathComponent("paths")
            try? Data(plan.paths.joined(separator: "\0").utf8).write(to: list)
            steps.append(MCPGitTools.stageArguments(pathspecFile: list.path))
        }
        if let message = plan.message {
            let file = folder.appendingPathComponent("message")
            try? message.write(to: file, atomically: true, encoding: .utf8)
            steps.append(MCPGitTools.commitArguments(messageFile: file.path))
        }
        let title = plan.message == nil ? "Stage for an agent" : "Commit for an agent"
        let repository = plan.repository
        GitWriter.shared.run(title, in: repository.root, repository: repository.commonDir, steps: steps) { result in
            try? FileManager.default.removeItem(at: folder)
            window?.finish()
            for controller in AppDelegate.shared.controllers where controller.sidebar.git.snapshot != nil {
                controller.sidebar.git.refresh()
            }
            guard result.ok else {
                let tail = result.output.split(separator: "\n").suffix(15).joined(separator: "\n")
                let what = result.failure == .hookFailed ? "A git hook stopped it" : "git failed"
                return reply(MCPControl.fail("\(what), so nothing more changed (Git › Git Commands has the whole output):\n\(tail)"))
            }
            var answer: [String: Any] = ["project": repository.root, "files": plan.files, "approved": approved]
            if plan.message == nil {
                answer["staged"] = true
            } else {
                answer["committed"] = MCPGitTools.committedID(from: result.output) ?? NSNull()
                answer["branch"] = repository.branch ?? NSNull()
                answer["pushed"] = false
            }
            reply(MCPControl.ok(answer))
        }
    }
}
