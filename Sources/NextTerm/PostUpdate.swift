import AppKit
import NextTermCore

/// Post Update's work: today's three sources gathered off the main thread, and the three ways the update leaves, each
/// on the user's click with the text masked first. Copy puts it on the pasteboard, Save writes a new file in the
/// window's checkout, and Send types it with no Return into an agent tab AgentReadiness says is ready. Next Term sends
/// it nowhere itself: no record line is written, nothing is opened, and nothing read or written is logged.
@MainActor
enum PostUpdate {
    /// The most handoff files read for one update.
    nonisolated static let handoffLimit = 20

    /// Builds today's draft for `project` (the window's checkout) and calls `done` on the main thread. git runs in the
    /// project's main checkout; handoffs are read from the window's own handoff folder.
    static func gather(project: String, now: Date = Date(), done: @escaping @MainActor (UpdateDraft) -> Void) {
        let settings = TaskSettings(defaults: .standard)
        let folder = settings.handoffFolder(for: project)
        let key = TaskSettings.projectKey(project)
        let mask = SecretMask.current
        let name = (project as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let calendar = Calendar.current
            let day = TaskDay(now, calendar: calendar)
            let handoffs: [UpdateDraft.HandoffSource] = folder.map {
                todaysHandoffs(project: project, folder: $0, day: day, mask: mask)
            } ?? []
            let tasks: [TaskRecord.Entry] = TaskRecordStore.shared.today(project: key, now: now)
            let commits = TodayCommits.read(project: project, git: GitRunner.locateGit(), now: now,
                                            calendar: calendar, mask: { mask.mask($0) })
            let draft = UpdateDraft.build(project: name, handoffs: handoffs, tasks: tasks, commits: commits,
                                          mask: { mask.mask($0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(draft) }
            }
        }
    }

    /// Today's handoffs in `folder`: names starting with the day and ending in `.md`, newest first, at most
    /// `handoffLimit`, each read only as a plain file by its own name and masked. A folder that is a link now is not
    /// listed at all.
    nonisolated static func todaysHandoffs(project: String, folder: String, day: TaskDay,
                                           mask: SecretMask) -> [UpdateDraft.HandoffSource] {
        guard HandoffFile.folderIsPlain(folder, in: project) else { return [] }
        let url = URL(fileURLWithPath: project, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let listed = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        let prefix = day.description + "-"
        let files: [URL] = (listed ?? []).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(".md")
        }
        func modified(_ file: URL) -> Date {
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let newest: [URL] = files.sorted { modified($0) > modified($1) }
        var sources: [UpdateDraft.HandoffSource] = []
        for file in newest.prefix(handoffLimit) {
            let relative = folder + "/" + file.lastPathComponent
            guard case .text(let handoff) = HandoffFile.read(relative, folder: folder, in: project, mask: mask) else {
                continue
            }
            sources.append(UpdateDraft.HandoffSource(file: relative, handoff: handoff))
        }
        return sources
    }

    /// Where Send posts by default: the tracker the project's tasks go to through an agent, else nothing.
    static func defaultPlace(project: String) -> String {
        let settings = TaskSettings(defaults: .standard)
        if case .throughAgent(let tracker) = settings.destination(for: TaskSettings.projectKey(project)) {
            return SecretMask.current.mask(tracker)
        }
        return ""
    }
}

// MARK: the three ways out

extension PostUpdate {
    /// The pasteboard Copy writes to: the self-test's own during the self-test, never the user's.
    static var pasteboard: NSPasteboard {
        #if DEBUG
        if let testPasteboard { return testPasteboard }
        #endif
        return .general
    }

    #if DEBUG
    static var testPasteboard: NSPasteboard?
    #endif

    /// `text` masked, and whether masking changed it.
    static func masked(_ text: String) -> (text: String, changed: Bool) {
        let result = SecretMask.current.masked(text)
        return (result.text, result.count > 0)
    }

    /// Puts `text` (masked by the caller) on the pasteboard as plain text.
    static func copy(_ text: String) {
        let board = pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Saves `text` (masked by the caller) as today's update in `checkout`; the path relative to it, or why not.
    static func save(_ text: String, in checkout: String, now: Date = Date()) -> Result<String, UpdateFile.Failure> {
        let day = TaskDay(now, calendar: .current)
        do {
            return .success(try UpdateFile.save(text, in: checkout, day: day))
        } catch let failure as UpdateFile.Failure {
            return .failure(failure)
        } catch {
            return .failure(.notWritten)
        }
    }

    /// Types the request for `text` (masked by the caller) into `tab` with no Return; nil once typed, else why not.
    /// Readiness is checked again inside the typing.
    static func send(_ text: String, to place: String, into tab: TerminalTab,
                     in controller: TerminalWindowController) -> String? {
        if UpdateDraft.isTooLong(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return tooLong }
        let title = SecretMask.current.mask(tab.title)
        guard tab.remote == nil else { return "“\(title)” is on a server. Nothing was typed." }
        // Where to post is typed too, so a key pasted there is masked like the draft.
        let masked = SecretMask.current.mask(place)
        guard let request = UpdateDraft.request(text: text, to: masked) else { return "Say where to post it." }
        return TaskAgentRequest.type(request, tasks: 1, into: tab, in: controller)
    }

    static let tooLong = "Too long to type into a prompt. Copy it instead."

    /// The window's agent tabs on this Mac, ready or greyed with why, as Send lists them.
    static func choices(in controller: TerminalWindowController) -> [TaskAgentRequest.Choice] {
        TaskAgentRequest.choices(in: controller).filter { $0.tab.remote == nil }
    }
}
