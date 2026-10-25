import AppKit
import NextTermCore

/// The import tools (MCPServer.importTools) on the app's side. list_import_sources and preview_import only read:
/// the apps found (DetectedApp: folders, dates and versions) and the rows the import window would show, as Core works them out
/// (MCPImport). apply_import and undo_import are requests: under either approval policy the ask is on the Mac
/// (the import window itself for an import, an approval window for Undo), and only the user's click changes
/// anything. Local only: the remote door gets none of them.
///
/// One request is open at a time, across the write tools, skill requests and imports; the user's own import window
/// open counts too (busy). A call answers within `answerWithin` seconds, with `pending` and a request id to call
/// again with when the user has not decided yet; a request left `openFor` seconds closes as a decline. Decline and
/// Stop Asking stops the asker for every write tool until Next Term quits (MCPWriteControl.stopped), and a request
/// the user declined answers declined at once for the rest of the session. Every answer goes through
/// MCPImport.text: MCPRedaction, the home folder as ~, and the apps' settings folders never named.
@MainActor
enum MCPImportControl {
    typealias Reply = MCPControl.Reply

    /// How long a call waits for the user before answering `pending`, and how long a request stays open.
    static var answerWithin: TimeInterval = 50
    static var openFor: TimeInterval = 600

    final class Request {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        /// What is asked, for spotting the same request again: "apply|<asker>|<source>|<plan id>" or "undo|<asker>|<undo id>".
        let key: String
        let asker: String
        /// Settings folders never named in its answers.
        let hiding: [String]
        var answer: [String: Any]?
        var waiters: [(token: UUID, reply: Reply)] = []
        /// Undo's ask; an import's ask is the import window.
        var approval: AgentApprovalWindow?
        var timedOut = false

        init(key: String, asker: String, hiding: [String]) {
            self.key = key
            self.asker = asker
            self.hiding = hiding
        }
    }

    /// Requests by id; answered ones are forgotten ten minutes after their answer.
    static var requests: [String: Request] = [:]
    /// The request the user is asked about now.
    static var open: Request? { requests.values.first { $0.answer == nil } }
    /// Requests the user declined (Request.key): answered declined at once until Next Term quits.
    static var declined = Set<String>()

    static let localOnly = "The import tools work only for agents on this Mac: the import window needs someone at the Mac. Nothing was done."

    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, approval: MCPApproval, requester: String?,
                     connection: String?, reply: @escaping Reply) {
        // Local only in this version: the remote door names none of these tools, and is refused if it calls one.
        guard requester == nil, connection == nil else { return reply(MCPControl.fail(localOnly)) }
        let asker = MCPWriteControl.asker(connection: nil, requester: nil, caller: caller)
        let who = SkillsMCP.describe(caller)
        switch tool {
        case "list_import_sources": list(arguments, reply: reply)
        case "preview_import": preview(arguments, caller: caller, reply: reply)
        case "apply_import": apply(arguments, caller: caller, asker: asker, who: who, reply: reply)
        case "undo_import": undo(arguments, asker: asker, who: who, reply: reply)
        default: reply(MCPControl.fail("Unknown tool \(tool)"))
        }
    }

    // MARK: answers

    static func ok(_ value: [String: Any], hiding: [String] = []) -> MCPServer.CallResult {
        MCPServer.CallResult(text: MCPImport.text(value, home: NSHomeDirectory(), hiding: hiding))
    }

    static func fail(_ text: String, hiding: [String] = []) -> MCPServer.CallResult {
        let shown = MCPImport.text(["refused": text], home: NSHomeDirectory(), hiding: hiding)
        let decoded = (try? JSONSerialization.jsonObject(with: Data(shown.utf8))) as? [String: Any]
        return MCPControl.fail(decoded?["refused"] as? String ?? text)
    }

    static func status(_ status: String, _ note: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var answer = extra
        answer["status"] = status
        answer["note"] = note
        return answer
    }

    // MARK: listing

    /// The apps found, as detection finds them: no planner runs, so no setting's value is read (DetectedApp says what is).
    static func list(_ arguments: [String: Any], reply: @escaping Reply) {
        let include: Bool
        switch MCPImport.includeTargets(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let value): include = value
        }
        let preset = KeyboardShortcuts.shared.preset
        let last = ImportCoordinator.shared.last
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = ImportSources.detect()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var answer = MCPImport.listing(apps, currentPreset: preset, last: last)
                    if include { answer["targets"] = MCPImport.targets(commands: commandTargets()) }
                    reply(ok(answer, hiding: apps.map(\.configPath)))
                }
            }
        }
    }

    /// The commands an import can give a key, with their keys now.
    static func commandTargets() -> [(id: String, title: String, key: KeyChord?)] {
        let shortcuts = KeyboardShortcuts.shared
        let keys = shortcuts.chords(under: shortcuts.preset)
        let known = Set(shortcuts.commands.map(\.id))
        return ImportShortcuts.titles.keys.sorted().filter(known.contains).map { id in
            (id, ImportShortcuts.titles[id] ?? id, keys[id] ?? nil)
        }
    }

    // MARK: the plan

    /// A source's plan, as the importer made it and as the window shows it at first (settled under its own set).
    struct Prepared {
        let found: DetectedApp
        /// The source's id, or "file:<project>/<path>".
        let id: String
        let raw: ImportPlan
        let settled: ImportPlan
        /// For a file an agent named: its path in its project, and whether it is that project's own settings.
        var file: (relative: String, project: String, projectSettings: Bool)?
        let hiding: [String]
    }

    /// The source or file the arguments name, planned off the main thread; `done` runs on the main thread.
    static func prepare(_ asked: MCPImport.Asked, caller: TerminalTab?, done: @escaping (Result<Prepared, MCPToolError>) -> Void) {
        if let path = asked.path, let format = asked.format {
            return done(prepareFile(path, format: format, project: asked.project, caller: caller))
        }
        let wanted = asked.source ?? ""
        let usKeyboard = ImportSources.usesUSKeyboard
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = ImportSources.detect()
            let found = MCPImport.source(wanted, in: apps)
            let plan = found.map { ImportSources.plan(for: $0.app, usKeyboard: usKeyboard) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let found, let plan else {
                        let ids = MCPImport.ids(of: apps).joined(separator: ", ")
                        let error = MCPToolError("No source \(wanted) on this Mac. Found: \(ids.isEmpty ? "none" : ids); list_import_sources lists them.")
                        return done(.failure(error))
                    }
                    let settled = ImportWindowController.settle(plan, under: plan.preset)
                    done(.success(Prepared(found: found.app, id: found.id, raw: plan, settled: settled, hiding: apps.map(\.configPath))))
                }
            }
        }
    }

    /// A settings file in an open project, read under read_file's rules.
    static func prepareFile(_ path: String, format: MCPImport.FileFormat, project: String?, caller: TerminalTab?) -> Result<Prepared, MCPToolError> {
        let preferred = caller.flatMap(MCPControl.controller(of:))?.project
        let projects = MCPProjects(open: AppDelegate.shared.controllers.compactMap { $0.project }, preferred: preferred)
        let file: ProjectFile
        switch projects.file(path, project: project) {
        case .failure(let error): return .failure(error)
        case .success(let found): file = found
        }
        let text: String
        switch MCPImport.read(file) {
        case .failure(let error): return .failure(error)
        case .success(let read): text = read
        }
        let projectName = (file.root as NSString).lastPathComponent
        let fileName = (file.relative as NSString).lastPathComponent
        let name = "\(fileName) in \(projectName)"
        let projectSettings = format == .vsCodeSettings && MCPImport.isProjectSettings(file.relative)
        let preset = KeyboardShortcuts.shared.preset
        let planned = MCPImport.filePlan(text: text, format: format, name: name, preset: preset, projectSettings: projectSettings,
                                         usKeyboard: ImportSources.usesUSKeyboard, home: NSHomeDirectory())
        switch planned {
        case .failure(let error): return .failure(error)
        case .success(let plan):
            let found = DetectedApp(kind: .vsCode, name: name, configPath: file.path, lastUsed: nil, preset: preset, appPath: file.path)
            let settled = ImportWindowController.settle(plan, under: plan.preset)
            var prepared = Prepared(found: found, id: "file:\(projectName)/\(file.relative)", raw: plan, settled: settled, hiding: [])
            prepared.file = (file.relative, projectName, projectSettings)
            return .success(prepared)
        }
    }

    static func context(for plan: ImportPlan) -> MCPImport.PreviewContext {
        let shortcuts = KeyboardShortcuts.shared
        let current = shortcuts.preset
        let lines = plan.preset != current ? ImportWindowController.presetLines(plan.preset) : []
        return MCPImport.PreviewContext(currentPreset: current, presetLines: lines, keysNow: shortcuts.chords(under: plan.preset),
                                        title: ImportWindowController.describe, isCurrent: ImportCurrent.has,
                                        knownRecents: AppDelegate.shared.recentProjects, home: NSHomeDirectory())
    }

    // MARK: preview

    static func preview(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let asked: MCPImport.Asked
        switch MCPImport.Asked.parse(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let value): asked = value
        }
        prepare(asked, caller: caller) { result in
            switch result {
            case .failure(let error): reply(fail(error.text))
            case .success(let prepared): reply(ok(previewAnswer(prepared), hiding: prepared.hiding))
            }
        }
    }

    static func previewAnswer(_ prepared: Prepared) -> [String: Any] {
        let planID = MCPImport.planID(prepared.raw)
        var answer = MCPImport.preview(source: prepared.found.name, plan: prepared.settled, planID: planID, context: context(for: prepared.settled))
        answer["source_id"] = prepared.id
        if let file = prepared.file {
            answer["file"] = ["path": file.relative, "project": file.project] as [String: Any]
            answer["file_note"] = file.projectSettings
                ? "These are \(file.project)'s own settings. Next Term has no per-project settings, so they would apply to every window: they start unticked."
                : "A file an agent names never sets hidden files, where new tabs open or recent projects."
        }
        return answer
    }

    // MARK: apply

    static func apply(_ arguments: [String: Any], caller: TerminalTab?, asker: String, who: String, reply: @escaping Reply) {
        let asked: MCPImport.Asked
        switch MCPImport.Asked.parse(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let value): asked = value
        }
        if let id = asked.requestID, !id.isEmpty {
            guard let request = requests[id] else { return reply(fail("No request with that id; answered requests are forgotten after ten minutes.")) }
            return wait(request, reply: reply)
        }
        if MCPWriteControl.stopped.contains(asker) { return reply(ok(status("stopped", MCPWriteControl.stoppedText))) }
        prepare(asked, caller: caller) { result in
            switch result {
            case .failure(let error): reply(fail(error.text))
            case .success(let prepared): ask(prepared, arguments: arguments, asked: asked, asker: asker, who: who, reply: reply)
            }
        }
    }

    /// Checks what the agent asked for against the plan, then opens the import window as the ask.
    static func ask(_ prepared: Prepared, arguments: [String: Any], asked: MCPImport.Asked, asker: String, who: String,
                    reply: @escaping Reply) {
        let hiding = prepared.hiding
        let current = KeyboardShortcuts.shared.preset
        let planID = MCPImport.planID(prepared.raw)
        if let given = asked.planID, !given.isEmpty, given != planID {
            let note = "What the app's files hold changed since that preview. Preview again; nothing was asked."
            return reply(ok(status("changed_since_preview", note, ["plan_id": planID]), hiding: hiding))
        }
        // Without the shortcut set, the user's own shortcuts settle against the set in use: those rows count too.
        let alternate = ImportWindowController.settle(prepared.raw, under: current)
        let recents = MCPImport.newRecents(prepared.settled, known: AppDelegate.shared.recentProjects)
        let withSet = MCPImport.offered(prepared.settled)
        let withoutSet = MCPImport.offered(alternate)
        let refused = withSet.refused.merging(withoutSet.refused) { first, _ in first }
        let named: Set<String>?
        switch MCPImport.items(arguments["items"], offered: withSet.ids.union(withoutSet.ids), refused: refused) {
        case .failure(let error): return reply(fail(error.text, hiding: hiding))
        case .success(let value): named = value
        }
        let ticks = named ?? MCPImport.defaultTicks(prepared.settled, currentPreset: current, newRecents: recents)
        let usesSet = ticks.contains(MCPImport.presetID) && prepared.settled.preset != current
        let shown = usesSet ? prepared.settled : alternate
        let changing = MCPImport.changes(shown, ticks: ticks, currentPreset: current, newRecents: recents, isCurrent: ImportCurrent.has)
        guard changing > 0 else {
            let note = "Nothing to change: what those rows hold is what Next Term has now. No window opened, and the last import's Undo is kept."
            return reply(ok(status("up_to_date", note, ["plan_id": planID]), hiding: hiding))
        }
        let key = ["apply", asker, prepared.id, planID].joined(separator: "|")
        if declined.contains(key) {
            return reply(ok(status("declined", "The user declined this earlier; it stays declined until Next Term quits."), hiding: hiding))
        }
        if let open, open.key == key { return wait(open, reply: reply) }
        if let busy = busyReason() { return reply(ok(status("busy", busy), hiding: hiding)) }
        let request = Request(key: key, asker: asker, hiding: hiding)
        requests[request.id] = request
        var notes: [String] = []
        if let last = ImportCoordinator.shared.last {
            let date = DateFormatter.localizedString(from: last.date, dateStyle: .medium, timeStyle: .none)
            notes.append("Undo of your import from \(last.source) (\(date)) will no longer be available once you apply this.")
        }
        if let file = prepared.file {
            notes.append(file.projectSettings
                ? "These are \(file.project)'s own settings, but Next Term has no per-project settings: ticked, they apply to every window, so they start unticked."
                : "Read from \(file.relative) in \(file.project), a file the agent named; such a file never sets hidden files, where new tabs open or recent projects.")
        }
        // A project's own settings start unticked whatever the agent asked: ticked, they would apply to every window.
        let windowTicks = prepared.file?.projectSettings == true ? Set<String>() : ticks
        let windowAsk = ImportWindowController.AgentAsk(who: who, reason: asked.reason, ticks: windowTicks, notes: notes) { outcome in
            MainActor.assumeIsolated { answered(request, outcome: outcome, asked: ticks, plan: prepared) }
        }
        ImportWindowController.shared.showAgentRequest(for: prepared.found, plan: prepared.raw, ask: windowAsk)
        closeLater(request) { ImportWindowController.shared.endAgentRequest() }
        wait(request, reply: reply)
    }

    /// The user's answer in the import window, as the agent gets it.
    static func answered(_ request: Request, outcome: ImportWindowController.AgentOutcome, asked: Set<String>, plan: Prepared) {
        switch outcome {
        case .declined(let stop):
            if stop { MCPWriteControl.stopped.insert(request.asker) }
            declined.insert(request.key)
            let note: String
            if request.timedOut {
                note = "No answer on the Mac within \(Int(openFor / 60)) minutes, so the window closed and nothing changed."
            } else if stop {
                note = "Declined on the Mac, and the user chose to stop your requests until Next Term quits; nothing changed."
            } else {
                note = "Declined on the Mac; nothing changed. It stays declined until Next Term quits."
            }
            resolve(request, status("declined", note))
        case .applied(let ticked, let snapshot, let replaced):
            guard let snapshot else {
                resolve(request, status("up_to_date", "The user applied, but nothing differed from Next Term's settings, so nothing changed and the last import's Undo is kept."))
                return
            }
            var answer = status("applied", "Settings › Import › Undo Import, or undo_import with this undo_id, puts these back.")
            answer["applied"] = ticked.sorted()
            answer["user_changed"] = MCPImport.userChanged(asked: asked, applied: ticked)
            answer["changed"] = ImportSnapshot.titles(of: snapshot.touched)
            answer["undo_id"] = MCPImport.undoID(snapshot)
            answer["replaced_undo_of"] = MCPImport.lastImport(replaced)
            answer["approved"] = "on this Mac"
            answer["not_brought_over"] = plan.settled.skipped.count
            resolve(request, answer)
        }
    }

    // MARK: undo

    static func undo(_ arguments: [String: Any], asker: String, who: String, reply: @escaping Reply) {
        let asked: (undoID: String?, reason: String?, requestID: String?)
        switch MCPImport.undoAsked(arguments) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let value): asked = value
        }
        if let id = asked.requestID, !id.isEmpty {
            guard let request = requests[id] else { return reply(fail("No request with that id; answered requests are forgotten after ten minutes.")) }
            return wait(request, reply: reply)
        }
        if MCPWriteControl.stopped.contains(asker) { return reply(ok(status("stopped", MCPWriteControl.stoppedText))) }
        let coordinator = ImportCoordinator.shared
        guard let last = coordinator.last else {
            return reply(ok(status("nothing_to_undo", "No import is kept for Undo: nothing was imported, or its Undo was used.")))
        }
        let undoID = MCPImport.undoID(last)
        guard asked.undoID == undoID else {
            let note = "That is not the last import: only the last one can be undone, and its undo_id is in current."
            return reply(ok(status("stale_undo_id", note, ["current": MCPImport.lastImport(last)])))
        }
        let key = ["undo", asker, undoID].joined(separator: "|")
        if declined.contains(key) {
            return reply(ok(status("declined", "The user declined this earlier; it stays declined until Next Term quits.")))
        }
        if let open, open.key == key { return wait(open, reply: reply) }
        if let busy = busyReason() { return reply(ok(status("busy", busy))) }
        let request = Request(key: key, asker: asker, hiding: [])
        requests[request.id] = request
        let date = DateFormatter.localizedString(from: last.date, dateStyle: .medium, timeStyle: .none)
        let details = "Imported from \(last.source) on \(date): \(last.summary).\n"
            + ImportCoordinator.undoMessage(changedSince: coordinator.changedSinceImport())
        let window = AgentApprovalWindow(.init(title: "An agent asks to undo your import from \(last.source)", requester: who,
                                               agentWords: asked.reason, details: details, approveTitle: "Undo Import",
                                               stopTitle: "Decline and Stop Asking"),
                                         approve: { window in undoApproved(request, undoID: undoID, window: window) },
                                         decline: { stop in
                                             if stop { MCPWriteControl.stopped.insert(asker) }
                                             declined.insert(key)
                                             let note = request.timedOut
                                                 ? "No answer on the Mac within \(Int(openFor / 60)) minutes, so nothing changed."
                                                 : "Declined on the Mac; nothing changed."
                                             resolve(request, status("declined", note))
                                         })
        request.approval = window
        window.present()
        closeLater(request) { window.close() }
        wait(request, reply: reply)
    }

    /// Undo, if the import the user saw is still the last one.
    static func undoApproved(_ request: Request, undoID: String, window: AgentApprovalWindow) {
        guard request.answer == nil else { return }
        let coordinator = ImportCoordinator.shared
        guard let last = coordinator.last, MCPImport.undoID(last) == undoID else {
            window.finish()
            resolve(request, status("stale_undo_id", "Another import or an Undo came first; nothing was undone.",
                                    ["current": MCPImport.lastImport(coordinator.last)]))
            return
        }
        let changed = coordinator.changedSinceImport()
        let keys = ImportSnapshot.titles(of: last.touched)
        coordinator.undo()
        window.finish()
        var answer = status("undone", "The settings, shortcuts and recent projects the import changed are as they were before it.")
        answer["keys"] = keys
        answer["changed_since_import"] = changed
        answer["approved"] = "on this Mac"
        resolve(request, answer)
    }

    // MARK: waiting

    /// Why another request can't be asked now (nil: it can). The same request open already is waited for instead.
    static func busyReason() -> String? {
        if open != nil { return "Another import request is waiting for the user. Ask again later." }
        if MCPWriteControl.pending != nil || SkillsMCP.open != nil {
            return "Another request is waiting for the user's answer on the Mac. Ask again once it is answered."
        }
        if ImportWindowController.shared.isOpenForUser {
            return "The user has the import window open themselves. Ask again once they close it."
        }
        return nil
    }

    /// Answers with the request's outcome, or `pending` after `answerWithin` seconds.
    static func wait(_ request: Request, reply: @escaping Reply) {
        if let answer = request.answer { return reply(ok(answer, hiding: request.hiding)) }
        let token = UUID()
        request.waiters.append((token, reply))
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin) {
            MainActor.assumeIsolated {
                guard let index = request.waiters.firstIndex(where: { $0.token == token }) else { return }
                request.waiters.remove(at: index)
                let note = "The user has not decided yet. Call again with only request_id to keep waiting."
                reply(ok(status("pending", note, ["request_id": request.id])))
            }
        }
    }

    /// Closes a request left unanswered for `openFor` seconds, as a decline.
    static func closeLater(_ request: Request, close: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + openFor) {
            MainActor.assumeIsolated {
                guard request.answer == nil else { return }
                request.timedOut = true
                close()
            }
        }
    }

    static func resolve(_ request: Request, _ answer: [String: Any]) {
        guard request.answer == nil else { return }
        request.answer = answer
        request.approval = nil
        let waiters = request.waiters
        request.waiters = []
        for waiter in waiters { waiter.reply(ok(answer, hiding: request.hiding)) }
        // The answer stays for a while, for an agent asking again with the id; then it is forgotten.
        let id = request.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { MainActor.assumeIsolated { _ = requests.removeValue(forKey: id) } }
    }
}

/// Whether Next Term has an imported value already (as the user sees it), so a request that would change nothing
/// opens no window.
enum ImportCurrent {
    static func has(_ setting: ImportedSetting) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        switch setting {
        case .fontSize(let size): return Double(app.fontSize) == size
        case .terminalFontSize(let size): return app.terminalOwnFontSize.map { Double($0) == size } ?? false
        case .editorLineHeight(let factor): return abs(Double(app.editorLineHeight) - factor) < 0.001
        case .softWrap(let on): return app.softWrap == on
        case .optionAsMeta(let on): return Preferences.optionAsMeta == on
        case .terminalPosition(let raw): return app.terminalPosition.rawValue == raw
        case .sidebarSide(let raw): return app.sidebarSide.rawValue == raw
        case .editorFontFamily(let family): return Preferences.editorFontFamily == family
        case .terminalFontFamily(let family): return Preferences.terminalFontFamily == family
        case .terminalPalette(let palette): return Preferences.terminalPalette == palette
        case .terminalScrollback(let lines): return Preferences.terminalScrollback == lines
        case .terminalStartFolder(let stored): return Preferences.terminalStartFolder.stored == stored
        case .terminalCursorShape(let raw): return Preferences.terminalCursorShape.rawValue == raw
        case .terminalCursorBlink(let on): return Preferences.terminalCursorBlinks == on
        case .trimTrailingWhitespace(let on): return Preferences.trimTrailingWhitespace == on
        case .insertFinalNewline(let on): return Preferences.insertFinalNewline == on
        case .hiddenFiles(let patterns): return Set(patterns).isSubset(of: Set(Preferences.hiddenFilePatterns))
        default: return hasWindowSetting(setting, app: app)
        }
    }

    private static func hasWindowSetting(_ setting: ImportedSetting, app: AppDelegate) -> Bool {
        switch setting {
        case .sidebarSingleClick(let on): return app.sidebarSingleClickOpens == on
        case .backgroundFetch(let raw): return BackgroundFetcher.shared.frequency.rawValue == raw
        case .diffLayout(let raw): return DiffLayout.current.rawValue == raw
        case .currentLineBlame(let on): return app.currentLineBlame == on
        case .openProjectsIn(let raw): return app.projectTarget.rawValue == raw
        case .launchOpens(let raw):
            return (UserDefaults.standard.string(forKey: LaunchSettings.Key.opens) ?? LaunchOpens.standard.rawValue) == raw
        case .tabList(let list):
            return list.isSet(tabs: app.terminalTabs.rawValue, sidebarSide: app.sidebarSide.rawValue, showsFolders: app.tabListShowsFolders)
        default: return false
        }
    }
}
