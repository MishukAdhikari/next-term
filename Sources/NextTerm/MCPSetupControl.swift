import AppKit
import NextTermCore

/// apply_setup on the app's side (AgentSetup): settings as settings_set takes them, the layout as set_layout does and an
/// import as apply_import does, asked in one window on the Mac (AgentSetupWindow) with a tickable row per change. Only
/// the rows the user ticks change, after a snapshot that Next Term › Undo Agent Setup puts back (AgentSetupUndo); the
/// import goes through ImportCoordinator, so Undo Import and undo_import work for it as for any import.
///
/// It waits as an import request does (MCPImportControl): one request open at a time across the write tools, `pending`
/// with a request id after `answerWithin` seconds, a cancel after `openFor`, a declined request answered declined at once
/// until Next Term quits, and Decline and Stop Asking from an earlier ask honoured. Local only, as the import tools are:
/// the remote door gets none of it.
@MainActor
enum MCPSetupControl {
    typealias Reply = MCPControl.Reply

    static let localOnly = "apply_setup works only for agents on this Mac: its window needs someone at the Mac. Nothing was done."

    /// The import part of a request, as prepared and selected for the window.
    struct ImportPart {
        let prepared: MCPImportControl.Prepared
        let selection: MCPImportControl.Selection
    }

    /// The layout part: the window its per-window fields go to, and the fields that differ now.
    struct LayoutPart {
        let controller: TerminalWindowController
        let change: MCPLayoutChange
    }

    /// The window asking now, if any.
    private(set) static var window: AgentSetupWindow?

    static func call(_ arguments: [String: Any], caller: TerminalTab?, approval: MCPApproval, requester: String?, connection: String?,
                     reply: @escaping Reply) {
        guard requester == nil, connection == nil else { return reply(MCPControl.fail(localOnly)) }
        let asker = MCPWriteControl.asker(connection: nil, requester: nil, caller: caller)
        let asked: AgentSetup.Asked
        switch AgentSetup.parse(arguments) {
        case .failure(let error): return reply(MCPImportControl.fail(error.text))
        case .success(let value): asked = value
        }
        if let id = asked.requestID, !id.isEmpty {
            guard let request = MCPImportControl.requests[id] else {
                return reply(MCPImportControl.fail("No request with that id; answered requests are forgotten after ten minutes."))
            }
            return MCPImportControl.wait(request, reply: reply)
        }
        if MCPWriteControl.stopped.contains(asker) {
            return reply(MCPImportControl.ok(MCPImportControl.status("stopped", MCPWriteControl.stoppedText)))
        }
        if let refused = asked.settings.lazy.compactMap({ MCPWriteControl.refusal($0.0, $0.1) }).first {
            return reply(MCPImportControl.fail(refused.replacingOccurrences(of: "nothing was changed", with: "nothing was asked")))
        }
        var layout: LayoutPart?
        if let wanted = asked.layout {
            let context = MCPWriteControl.context(asked.layoutArguments, caller: caller, approval: approval, requester: nil, connection: nil)
            switch MCPWriteControl.layoutWindow(asked.layoutArguments, context) {
            case .failure(let error): return reply(MCPImportControl.fail(error.text))
            case .success(let controller):
                switch MCPWriteControl.layoutPlan(wanted, in: controller) {
                case .failure(let error): return reply(MCPImportControl.fail(error.text))
                case .success(let plan): layout = LayoutPart(controller: controller, change: plan.change)
                }
            }
        }
        let who = SkillsMCP.describe(caller)
        guard let importAsked = asked.importAsked else {
            return ask(asked, layout: layout, importing: nil, asker: asker, who: who, reply: reply)
        }
        MCPImportControl.prepare(importAsked, caller: caller) { result in
            switch result {
            case .failure(let error): reply(MCPImportControl.fail(error.text))
            case .success(let prepared):
                switch MCPImportControl.selection(prepared, arguments: asked.importArguments ?? [:], asked: importAsked) {
                case .refused(let error): reply(MCPImportControl.fail(error.text, hiding: prepared.hiding))
                case .changedSincePreview(let planID):
                    let note = "What the app's files hold changed since that preview. Preview again; nothing was asked."
                    reply(MCPImportControl.ok(MCPImportControl.status("changed_since_preview", note, ["plan_id": planID]), hiding: prepared.hiding))
                case .ok(let selection):
                    ask(asked, layout: layout, importing: ImportPart(prepared: prepared, selection: selection), asker: asker, who: who, reply: reply)
                }
            }
        }
    }

    // MARK: the ask

    /// The rows that change something, checked so nothing is set twice, then the window as the ask.
    static func ask(_ asked: AgentSetup.Asked, layout: LayoutPart?, importing: ImportPart?, asker: String, who: String, reply: @escaping Reply) {
        let hiding = importing?.prepared.hiding ?? []
        let home = NSHomeDirectory()
        let settings = asked.settings.filter { !MCPWriteControl.same(MCPWriteControl.value(of: $0.0), $0.1) }
        var rows: [AgentSetup.Row] = settings.map { setting, value in
            AgentSetup.settingRow(setting, now: MCPWriteControl.value(of: setting), new: value, home: home)
        }
        if let layout { rows += AgentSetup.layoutRows(layout.change, place: MCPWriteControl.place(layout.controller)) }
        let importing = importing.flatMap { $0.selection.changing > 0 ? $0 : nil }
        if let importing {
            if let twice = AgentSetup.overlap(settings: settings.map(\.0.name), layout: layout?.change, importKeys: importKeys(importing)) {
                return reply(MCPImportControl.fail(twice.text, hiding: hiding))
            }
            rows.append(importRow(importing))
        }
        guard !rows.isEmpty else {
            let note = "Nothing to change: those settings, the layout and the import's rows are what Next Term has now. No window opened."
            return reply(MCPImportControl.ok(MCPImportControl.status("up_to_date", note), hiding: hiding))
        }
        let key = (["setup", asker] + rows.map { $0.id + "=" + $0.title }).joined(separator: "|")
        if MCPImportControl.declined.contains(key) {
            let note = "The user cancelled this earlier; it stays cancelled until Next Term quits."
            return reply(MCPImportControl.ok(MCPImportControl.status("declined", note), hiding: hiding))
        }
        if let open = MCPImportControl.open, open.key == key { return MCPImportControl.wait(open, reply: reply) }
        if let busy = MCPImportControl.busyReason() { return reply(MCPImportControl.ok(MCPImportControl.status("busy", busy), hiding: hiding)) }
        let request = MCPImportControl.Request(key: key, asker: asker, hiding: hiding)
        MCPImportControl.requests[request.id] = request

        var ticked = Set(rows.map(\.id))
        var notes: [String] = []
        if let importing {
            if let last = ImportCoordinator.shared.last {
                let date = DateFormatter.localizedString(from: last.date, dateStyle: .medium, timeStyle: .none)
                notes.append("Undo of your import from \(last.source) (\(date)) will no longer be available once the import is applied.")
            }
            // A project's own settings start unticked whatever the agent asked: ticked, they would apply to every window.
            if let file = importing.prepared.file, file.projectSettings {
                ticked.remove(AgentSetup.importID)
                notes.append("The import is \(file.project)’s own settings, but Next Term has no per-project settings: ticked, they apply to every window, so it starts unticked.")
            }
        }
        if let earlier = AgentSetupUndo.last {
            notes.append("Undo Agent Setup will put back this setup instead of the one from \(DateFormatter.localizedString(from: earlier.date, dateStyle: .medium, timeStyle: .short)).")
        }
        let decision = UpdateHolds.shared.open(decision: AgentSetupWindow.title) { window?.close() }
        let setup = AgentSetupWindow(.init(requester: who, agentWords: asked.reason, rows: rows, ticked: ticked, notes: notes),
                                     apply: { ticked, shown in
                                         UpdateHolds.shared.close(decision)
                                         applied(request, ticked: ticked, rows: rows, settings: settings, layout: layout, importing: importing, who: who)
                                         shown.finish()
                                         if window === shown { window = nil }
                                     },
                                     cancel: {
                                         UpdateHolds.shared.close(decision)
                                         MCPImportControl.declined.insert(key)
                                         let minutes = Int(MCPImportControl.openFor / 60)
                                         let note = request.timedOut
                                             ? "No answer on the Mac within \(minutes) minutes, so the window closed and nothing changed."
                                             : "Cancelled on the Mac; nothing changed. It stays cancelled until Next Term quits."
                                         MCPImportControl.resolve(request, MCPImportControl.status("declined", note))
                                         window = nil
                                     })
        window = setup
        setup.present()
        MCPImportControl.closeLater(request) { setup.close() }
        MCPImportControl.wait(request, reply: reply)
    }

    /// The import's row: what its ticked rows bring, from which app, and what has no equivalent.
    static func importRow(_ importing: ImportPart) -> AgentSetup.Row {
        let plan = importing.selection.shown, ticks = importing.selection.ticks
        let ids = MCPImport.rowIDs(plan)
        let preset: KeymapPreset? = ticks.contains(MCPImport.presetID) && plan.preset != KeyboardShortcuts.shared.preset ? plan.preset : nil
        let keys = plan.shortcuts.indices.filter { ticks.contains(ids.shortcuts[$0]) && plan.shortcuts[$0].allowed }.count
        let settings = plan.settings.indices.filter { ticks.contains(ids.settings[$0]) && !ImportCurrent.has(plan.settings[$0].setting) }.count
        let recents = ticks.contains(MCPImport.recentsID) ? importing.selection.recents.count : 0
        return AgentSetup.importRow(source: importing.prepared.found.name, preset: preset, keys: keys, settings: settings, recents: recents,
                                    notBroughtOver: plan.skipped.count, changes: importing.selection.changing)
    }

    /// The saved keys the import's ticked rows set, each with its row id, to check nothing else sets them too.
    static func importKeys(_ importing: ImportPart) -> [String: String] {
        let plan = importing.selection.shown, ticks = importing.selection.ticks
        let ids = MCPImport.rowIDs(plan)
        var keys: [String: String] = [:]
        if ticks.contains(MCPImport.presetID), plan.preset != KeyboardShortcuts.shared.preset { keys["keymapPreset"] = MCPImport.presetID }
        for (index, row) in plan.settings.enumerated() where ticks.contains(ids.settings[index]) {
            for key in row.setting.keys { keys[key] = ids.settings[index] }
        }
        return keys
    }

    // MARK: applying

    /// Applies the ticked rows, after a snapshot of what each changes, and answers the agent.
    static func applied(_ request: MCPImportControl.Request, ticked: Set<String>, rows: [AgentSetup.Row],
                        settings: [(MCPSettings.Setting, MCPSettings.Value)], layout: LayoutPart?, importing: ImportPart?, who: String) {
        guard request.answer == nil else { return }
        var settingEntries: [AgentSetupSnapshot.Setting] = []
        for (setting, value) in settings where ticked.contains(AgentSetup.settingID(setting.name)) {
            let before = MCPWriteControl.value(of: setting)
            MCPWriteControl.apply(setting, value)
            settingEntries.append(.init(name: setting.name, before: before, after: MCPWriteControl.value(of: setting)))
        }
        var layoutEntries: [AgentSetupSnapshot.Layout] = []
        if let layout {
            let change = AgentSetup.only(layout.change, ticked: ticked)
            let before = layoutNow(layout.controller)
            MCPWriteControl.applyLayout(change, in: layout.controller, asked: true)
            let after = layoutNow(layout.controller)
            for (field, _) in AgentSetup.layoutValues(change) {
                let perWindow = AgentSetup.perWindowFields.contains(field)
                layoutEntries.append(.init(field: field, before: before[field] ?? "", after: after[field] ?? "",
                                           project: perWindow ? layout.controller.project : nil))
            }
        }
        var importAnswer: [String: Any]?
        var importSnapshot: ImportSnapshot?
        if let importing, ticked.contains(AgentSetup.importID) {
            let selection = importing.selection
            let replaced = ImportCoordinator.shared.last
            let choice = ImportChoice(selection.shown, ticks: selection.ticks, newRecents: selection.recents)
            importSnapshot = ImportCoordinator.shared.apply(choice, plan: selection.shown, from: importing.prepared.found.name)
            var answer: [String: Any] = ["source": importing.prepared.found.name, "rows": selection.ticks.sorted(),
                                         "not_brought_over": selection.shown.skipped.count]
            if let importSnapshot {
                answer["changed"] = ImportSnapshot.titles(of: importSnapshot.touched)
                answer["undo_id"] = MCPImport.undoID(importSnapshot)
                answer["replaced_undo_of"] = MCPImport.lastImport(replaced)
            } else {
                answer["changed"] = [String]()
            }
            importAnswer = answer
        }
        let lines = rows.filter { ticked.contains($0.id) }.map(\.title)
        let snapshot = AgentSetupSnapshot.applied(agent: who, settings: settingEntries, layout: layoutEntries,
                                                  importUndoID: importSnapshot.map(MCPImport.undoID),
                                                  importSource: importSnapshot == nil ? nil : importing?.prepared.found.name, lines: lines)
        guard let snapshot else {
            let note = "The user applied, but nothing differed from Next Term's settings, so nothing changed and Undo Agent Setup is as it was."
            return MCPImportControl.resolve(request, MCPImportControl.status("up_to_date", note))
        }
        AgentSetupUndo.remember(layout?.controller, for: snapshot)
        AgentSetupUndo.last = snapshot
        var undo = "Next Term › Undo Agent Setup… puts back everything this changed."
        if let importSnapshot { undo += " undo_import with undo_id \(MCPImport.undoID(importSnapshot)) puts back the import alone." }
        var answer = MCPImportControl.status("applied", undo)
        answer["applied"] = rows.filter { ticked.contains($0.id) }.map { ["id": $0.id, "row": $0.title] }
        answer["skipped"] = rows.filter { !ticked.contains($0.id) }.map { ["id": $0.id, "row": $0.title] }
        answer["settings"] = Dictionary(settingEntries.map { ($0.name, $0.after.json) }, uniquingKeysWith: { first, _ in first })
        answer["layout"] = Dictionary(layoutEntries.map { ($0.field, $0.after) }, uniquingKeysWith: { first, _ in first })
        if let importAnswer { answer["import"] = importAnswer }
        answer["undo"] = undo
        answer["approved"] = "on this Mac"
        MCPImportControl.resolve(request, answer)
    }

    /// The layout's fields now, as a snapshot keeps them (AgentSetup.layoutValues' form).
    static func layoutNow(_ controller: TerminalWindowController?) -> [String: String] {
        let app = AppDelegate.shared!
        var values: [String: String] = [
            "terminal_position": app.terminalPosition.rawValue, "sidebar_side": app.sidebarSide.rawValue,
            "terminal_tabs": app.terminalTabs.rawValue, "window_column": app.showsWindowColumn ? "shown" : "hidden",
            "window_column_folded": String(!app.windowColumnExpanded),
        ]
        if let controller {
            values["sidebar"] = controller.isSidebarVisible ? "shown" : "hidden"
            values["terminal_folded"] = String(controller.terminalCollapsed)
        }
        return values
    }
}

extension ImportChoice {
    /// The rows `ticks` names in `plan` (MCPImport's ids), as the import window's ticks make a choice: the shortcut set
    /// when it differs, the settings, the user's own shortcuts that can be taken, and the recent projects not listed yet.
    @MainActor
    init(_ plan: ImportPlan, ticks: Set<String>, newRecents: [String]) {
        let ids = MCPImport.rowIDs(plan)
        usePreset = ticks.contains(MCPImport.presetID) && plan.preset != KeyboardShortcuts.shared.preset
        settings = plan.settings.indices.filter { ticks.contains(ids.settings[$0]) }.map { plan.settings[$0] }
        shortcuts = plan.shortcuts.indices.filter { ticks.contains(ids.shortcuts[$0]) && plan.shortcuts[$0].allowed }.map { plan.shortcuts[$0] }
        recentProjects = ticks.contains(MCPImport.recentsID) ? newRecents : []
    }
}
