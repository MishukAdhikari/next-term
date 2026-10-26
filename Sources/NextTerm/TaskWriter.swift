import AppKit
import NextTermCore

/// The one writer of tasks in the app, for Tasks › Add Task… and add_task alike, so both give the same bytes for the
/// same draft: where a task goes and what its file holds (`plan`), the file written create-only (`write`), and the
/// notice with Undo. It never opens the file.
@MainActor
enum TaskWriter {
    /// A task about to be written: where, as what, under which name.
    struct Plan {
        let draft: TaskDraft
        let resolution: TodoFolder.Resolution
        let created: Date
        /// The file's text, with stored keys masked.
        let text: String
        /// The names it may take, the planned one first.
        let names: [String]
        /// The same title went to this folder within the last minute.
        let duplicate: Bool

        var plannedName: String { names.first ?? "" }
        /// "todo/2026-10-15-finish-the-login-fix.md in next-term", or "~/Notes/Todo/2026-10-15-….md".
        var shown: String { TodoFolder.shownFile(plannedName, in: resolution) }
        /// "todo/", as the notice says it.
        var shownFolder: String { TaskWriter.shownFolder(resolution) }
    }

    /// Why a task can't be planned. Nothing was written.
    enum Refusal: Error, Equatable {
        /// A window with no project, and no folder for those in Settings › Tasks.
        case noProject
        /// An absolute folder that is not there, as shown ("~/Notes/Todo").
        case missing(String)
        /// Settings › Tasks names a folder that can't be used, with why.
        case unusable(String)
    }

    /// The plan for `draft` in `project` (the window's; nil for a window with no project), added at `created`. The
    /// folder is looked in for a taken name and, with `duplicates`, the same title added within a minute, only when
    /// `looking` or when it is not in a protected place: a look in one waits for the user's Add or Approve.
    static func plan(_ draft: TaskDraft, project: String?, created: Date = Date(), looking: Bool = false,
                     duplicates: Bool = true) -> Result<Plan, Refusal> {
        let resolution = TodoFolder.resolve(project: project, settings: TaskSettings(defaults: .standard))
        let folder: URL
        switch resolution {
        case .inProject(let url, _, _), .shared(let url, _): folder = url
        case .missing(let url): return .failure(.missing(TodoFolder.shown(url.path)))
        case .noProject: return .failure(.noProject)
        case .refused(let why): return .failure(.unusable(why))
        }
        var outside: (name: String, path: String)?
        if case .shared(_, let root?) = resolution { outside = ((root as NSString).lastPathComponent, root) }
        let text = TodoFile.render(draft, created: created, timeZone: .current, outsideProject: outside)
        var names = TodoFile.names(created: created, title: draft.title, timeZone: .current)
        let mayLook = looking || mayLookBeforeAsking(resolution)
        var duplicate = false
        if mayLook, FileManager.default.fileExists(atPath: folder.path) {
            let free = names.firstIndex { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            names.removeFirst(free ?? names.count)
            if duplicates { duplicate = TodoFolder.recentDuplicate(slug: TodoFile.slug(draft.title), in: folder, now: created) }
        }
        return .success(Plan(draft: draft, resolution: resolution, created: created, text: text, names: names, duplicate: duplicate))
    }

    /// The folder may be listed before the user answers: it is in the project, or outside the protected places.
    static func mayLookBeforeAsking(_ resolution: TodoFolder.Resolution) -> Bool {
        guard case .shared(let url, _) = resolution else { return true }
        return !ProtectedPlaces.current.holds(url.path)
    }

    /// Writes the planned file, create-only, and returns it with the folder made for it, if one was.
    static func write(_ plan: Plan) throws -> (file: URL, madeFolder: URL?) {
        let made = topMissingFolder(plan.resolution)
        let file = try TodoFolder.create(plan.text, names: plan.names, in: plan.resolution)
        return (file, made)
    }

    /// The highest folder a task in the project makes: `docs` for a `docs/todo` not there yet.
    private static func topMissingFolder(_ resolution: TodoFolder.Resolution) -> URL? {
        guard case .inProject(let url, let root, true) = resolution else { return nil }
        var top: URL?
        var folder = url
        while folder.path.count > root.count, !FileManager.default.fileExists(atPath: folder.path) {
            top = folder
            folder = folder.deletingLastPathComponent()
        }
        return top
    }

    /// "todo/", "docs/todo/" or "~/Notes/Todo/".
    nonisolated static func shownFolder(_ resolution: TodoFolder.Resolution) -> String {
        switch resolution {
        case .inProject(let url, let root, _): return String(url.path.dropFirst(root.count + 1)) + "/"
        case .shared(let url, _), .missing(let url): return TodoFolder.shown(url.path) + "/"
        case .noProject, .refused: return ""
        }
    }

    // MARK: where you are

    /// Where a task is added: the tab's branch (its agent's, else the window's), its title, its agent and the command
    /// that resumes that agent's session, with `addedBy`. Only `addedBy` unless `whereYouAre`. Stored keys are masked.
    static func context(of tab: TerminalTab?, in controller: TerminalWindowController?, addedBy: String, whereYouAre: Bool) -> TaskContext {
        var context = TaskContext(addedBy: addedBy)
        if whereYouAre {
            let fields: [String: Any] = tab.flatMap { tab in controller.map { AgentPlaces.shared.fields(of: tab, in: $0) } } ?? [:]
            context.branch = fields["branch"] as? String ?? controller?.sidebar.git.snapshot?.branch
            if let tab {
                context.tab = tab.title
                if let agent = agent(of: tab) {
                    context.agent = agent
                    context.resume = resumeCommand(tab, agent)
                }
            }
        }
        return context.masked { SecretMask.current.mask($0) }
    }

    /// The agent running in a local tab, by its kind.
    static func agent(of tab: TerminalTab) -> AgentKind? { tab.localAgent }

    /// The line that resumes the agent's session in the tab, when its session's id can be read (as a restore reads it).
    private static func resumeCommand(_ tab: TerminalTab, _ agent: AgentKind) -> String? {
        guard let process = tab.view.process else { return nil }
        let evidence = ProcessInspector.agentEvidence(ptyFileDescriptor: process.childfd, shellPid: process.shellPid,
                                                      status: tab.status, home: RestorePlanning.agentHome)
        guard let evidence, let id = evidence.sessionID else { return nil }
        let kind = evidence.agent.kind ?? agent
        return kind.resumeCommand(id: id, cwd: evidence.sessionFolder ?? tab.liveDirectory, fork: false)
    }

    // MARK: undo

    /// "Added to todo/" at the bottom of `window`, with Undo: the files still as written go to the Trash, and the folder
    /// made for them with them while it is empty. A file edited since stays, and the notice says so.
    static func offerUndo(_ files: [(url: URL, text: String)], madeFolder: URL?, shownFolder: String, in window: NSWindow?) {
        guard !files.isEmpty else { return }
        let text = files.count == 1 ? "Added to \(shownFolder)" : "Added \(files.count) tasks to \(shownFolder)"
        GitToast.show(text, in: window, button: "Undo") {
            MainActor.assumeIsolated { undo(files, madeFolder: madeFolder, in: window) }
        }
    }

    static func undo(_ files: [(url: URL, text: String)], madeFolder: URL?, in window: NSWindow?) {
        var kept = 0
        for file in files {
            guard TodoFolder.isUnchanged(file.url, file.text) else {
                kept += 1
                continue
            }
            try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        }
        if let madeFolder, let first = files.first { removeEmpty(from: first.url.deletingLastPathComponent(), upTo: madeFolder) }
        guard kept > 0 else { return }
        GitToast.show(kept == 1 ? "The task was edited since, so it stays." : "\(kept) tasks were edited since, so they stay.", in: window)
    }

    /// Removes `folder` and the folders above it up to `top`, each only while it is empty.
    private static func removeEmpty(from folder: URL, upTo top: URL) {
        var folder = folder
        while folder.path.hasPrefix(top.path), rmdir(folder.path) == 0 {
            if folder.path == top.path { return }
            folder = folder.deletingLastPathComponent()
        }
    }
}
