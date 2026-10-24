import AppKit
import NextTermCore

/// Wrap Up's work with the tabs and the files: the window's agent tabs read into WrapUpModel, the fixed handoff request
/// typed into each ticked tab that is still ready, and one timer that looks at every asked tab's named file until the
/// review. Only a tab AgentReadiness says is ready is typed into, checked again at the moment of typing, and only the
/// fixed request is sent with Return; the tab is not marked driven, and its run_with_secrets grants end as for any
/// typed input. A handoff is read only by its own name, never through a link, and masked before anything holds it.
/// Nothing here logs, and nothing reaches the network.
@MainActor
final class WrapUp {
    let project: String
    /// The handoff folder, relative to the project.
    let folder: String
    private(set) var model: WrapUpModel
    private(set) var reads: [UUID: HandoffFile.Read] = [:]
    /// Each asked tab's context, read at Ask: the tab may close before Add.
    private(set) var contexts: [UUID: TaskContext] = [:]
    /// Called after every look that changed something.
    var changed: (() -> Void)?
    private weak var controller: TerminalWindowController?
    private var timer: Timer?
    /// The day the names are for, fixed when the sheet opens.
    private let day: TaskDay

    init(controller: TerminalWindowController, project: String, folder: String, now: Date = Date()) {
        self.controller = controller
        self.project = project
        self.folder = folder
        day = TaskDay(now, calendar: .current)
        model = WrapUpModel([])
        model = WrapUpModel(facts())
    }

    deinit { timer?.invalidate() }

    var root: URL { URL(fileURLWithPath: project, isDirectory: true) }

    /// The window's tabs that run an agent, local or on a server, in tab order, as the model takes them.
    private func facts() -> [WrapUpModel.TabFacts] {
        guard let controller else { return [] }
        return TaskAgentRequest.choices(in: controller).map { choice in
            let tab = choice.tab
            let title = SecretMask.current.mask(tab.title)
            let names = HandoffName.pick(day: day, tab: tab.title, taken: { self.exists($0) }) != nil
            return WrapUpModel.TabFacts(id: tab.id, title: title, agent: choice.agent, verdict: choice.verdict,
                                        insideProject: inside(tab), namesLeft: names)
        }
    }

    /// The tab works in the project's top folder, so the path relative to the project lands where Wrap Up looks.
    private func inside(_ tab: TerminalTab) -> Bool {
        guard tab.remote == nil else { return false }
        return WrapUpModel.atProjectRoot(tabFolder: tab.liveDirectory, project: project)
    }

    /// A file or anything else by that name is in the handoff folder.
    private func exists(_ name: String) -> Bool {
        let path = root.appendingPathComponent(folder).appendingPathComponent(name).path
        return (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    func tab(_ id: UUID) -> TerminalTab? {
        controller?.tabs.first { $0.id == id }
    }

    // MARK: the timer

    /// One look a second, for every row, until `stop`.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    /// Before Ask, the tab list is read again; after, each asked tab and its file are looked at.
    func tick(now: Date = Date()) {
        let before = model
        if model.askedRows.isEmpty {
            model.refresh(facts())
        } else {
            lookAtFiles(now: now)
        }
        if model != before { changed?() }
    }

    func setTicked(_ id: UUID, _ on: Bool) {
        model.setTicked(id, on)
    }

    func skip(_ id: UUID) {
        model.skip(id)
    }

    func keepWaiting(_ id: UUID) {
        model.keepWaiting(id, now: Date())
    }

    /// At Review: whatever is still waited for is skipped, the timer stops, and every ready handoff is read once more,
    /// so what the agent rewrote after it was first read is what the review shows.
    func stopWaiting() {
        model.stopWaiting()
        stop()
        for row in model.rows where row.phase == .ready {
            guard let file = row.file else { continue }
            reads[row.id] = HandoffFile.read(file, folder: folder, in: project)
        }
    }

    /// The handoff folder is still a plain folder in the project, with no link on its way.
    var folderIsPlain: Bool { HandoffFile.folderIsPlain(folder, in: project) }
}

extension WrapUp {
    /// Asks every ticked row's tab, each checked once more now: a tab that stopped being ready is skipped with its
    /// reason and nothing is typed into it. Each gets a name no file and no other tab of this Wrap Up holds.
    func ask(now: Date = Date()) {
        var given: Set<String> = []
        let includeContext = TaskSettings(defaults: .standard).includeContext
        for row in model.rows where row.ticked {
            guard let tab = tab(row.id) else {
                model.skip(row.id, because: "closed")
                continue
            }
            if case .notReady(let reason) = AgentReadiness.shared.check(tab) {
                model.skip(row.id, because: reason.text)
                continue
            }
            guard inside(tab) else {
                model.skip(row.id, because: WrapUpModel.Block.outsideProject.text)
                continue
            }
            let taken: (String) -> Bool = { given.contains($0) || self.exists($0) }
            guard let name = HandoffName.pick(day: day, tab: tab.title, taken: taken) else {
                model.skip(row.id, because: WrapUpModel.Block.namesUsedUp.text)
                continue
            }
            let path = folder + "/" + name
            guard let request = HandoffRequest.text(path: path), type(request, into: tab) else {
                model.skip(row.id, because: "can’t be typed into now")
                continue
            }
            given.insert(name)
            contexts[row.id] = TaskWriter.context(of: tab, in: controller, addedBy: TaskContext.you,
                                                  whereYouAre: includeContext)
            model.asked(row.id, file: path, at: now)
        }
        start()
    }

    /// The request, then Return a moment later: agents take a paste as a block and only a separate Return sends it.
    /// That Return is Next Term's own line end, so the tab is not marked driven. false when the tab can't take input.
    /// As with every typed request, the prompt line is not looked at again before the Return: anything the user types
    /// into that tab in the quarter second between goes with the request.
    private func type(_ request: String, into tab: TerminalTab) -> Bool {
        guard MCPControl.canType(tab), MCPInputLine.refusal(tab) == nil else { return false }
        let typed = tab.view.typeText(request)
        SecretRequests.shared.tabGotInput(tab.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // The tab may have closed or dropped its connection in between.
            guard MCPControl.canType(tab) else { return }
            tab.submitOwnLine(typed)
        }
        return true
    }

    /// Every asked row: its tab and its named file. Only that file counts; another file in the folder is never read.
    private func lookAtFiles(now: Date) {
        // A folder made into a link since the sheet opened: nothing in it is looked at or read again.
        guard folderIsPlain else {
            for row in model.rows where row.isWaiting { model.skip(row.id, because: Self.linkedFolder) }
            return stop()
        }
        for row in model.rows where row.isWaiting {
            guard let file = row.file else { continue }
            let url = root.appendingPathComponent(file)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size: Int? = (attributes?[.size] as? NSNumber)?.intValue
            let tab = tab(row.id)
            let status = tab?.status
            let asking = status?.question != nil || status?.state == .attention
            let look = WrapUpModel.Look(exists: attributes != nil, size: size, working: status?.state == .working,
                                        gone: tab == nil, exited: tab?.exited ?? false, asking: asking, now: now)
            model.look(row.id, look)
            if model.rows.first(where: { $0.id == row.id })?.phase == .ready {
                reads[row.id] = HandoffFile.read(file, folder: folder, in: project)
            }
        }
        if !model.isWaiting { stop() }
    }

    /// The handoff at `file`, relative to the project, as a URL.
    func url(_ file: String) -> URL { root.appendingPathComponent(file) }

    static let linkedFolder = "the handoff folder is a link now"
}
