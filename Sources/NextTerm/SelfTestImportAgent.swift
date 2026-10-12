import AppKit
import NextTermCore

/// The import tools for agents, called as a local agent outside Next Term's tabs calls them (MCPControl.call with no
/// caller): listing parses nothing, a preview has the window's rows, and apply_import's ask is the import window
/// itself, with the agent's rows ticked and a banner, where nothing changes before the user's click. Cancel, Decline
/// and Stop Asking, no answer in time (pending), a stale plan, an up-to-date plan, the user's own window (busy), a
/// stale Undo, Undo's ask and a named file outside the open projects each do what they say. The app is made up (the
/// detectors and planner are swapped, so nothing on this Mac is read) and no key is typed: the clicks are the
/// buttons' own, so these run whether or not the app is in front. Every setting, the shortcut set, the last import and the tools' state are put back.
extension SelfTest {
    static func importAgentChecks() async {
        guard let app = AppDelegate.shared else { return note("import tools for agents: skipped, no app") }
        let window = ImportWindowController.shared
        let coordinator = ImportCoordinator.shared
        let defaults = UserDefaults.standard
        let saved = (detectors: ImportSources.detectors, planner: ImportSources.planner, last: coordinator.last,
                     size: app.fontSize, wrap: app.softWrap, blink: defaults.object(forKey: "terminalCursorBlink"),
                     preset: KeyboardShortcuts.shared.preset, bindings: defaults.data(forKey: "keyBindings"),
                     wait: MCPImportControl.answerWithin, stopped: MCPWriteControl.stopped)
        defer {
            window.endAgentRequest()
            window.window?.close()
            ImportSources.detectors = saved.detectors
            ImportSources.planner = saved.planner
            MCPImportControl.answerWithin = saved.wait
            MCPImportControl.declined = []
            MCPImportControl.requests = [:]
            MCPWriteControl.stopped = saved.stopped
            app.setFontSize(saved.size)
            app.applyImported(.softWrap(saved.wrap))
            if let blink = saved.blink as? Bool { app.setTerminalCursor(blinks: blink) } else {
                defaults.removeObject(forKey: "terminalCursorBlink")
                app.setTerminalCursor()
            }
            if let bindings = saved.bindings { defaults.set(bindings, forKey: "keyBindings") } else { defaults.removeObject(forKey: "keyBindings") }
            KeyboardShortcuts.shared.preset = saved.preset
            coordinator.last = saved.last
        }
        MCPImportControl.declined = []
        MCPWriteControl.stopped = []
        KeyboardShortcuts.shared.preset = .nextTerm
        coordinator.last = nil

        // A made-up editor and its plan: three settings that differ from Next Term's now, and the VS Code set.
        let editor = DetectedApp(kind: .vsCodeFork, name: "NT Agent Editor", configPath: "/nonexistent/nt-agent-editor/User",
                                 lastUsed: Date().addingTimeInterval(-3600), appPath: "/nonexistent/NT Agent Editor.app", version: "1.2.3")
        let size = Double((saved.size >= 30 ? saved.size - 2 : saved.size + 2).rounded())
        let blinks = Preferences.terminalCursorBlinks
        let plan = ImportPlan(preset: .vsCode, settings: [
            PlannedSetting(.fontSize(size), source: "editor.fontSize \(Int(size))"),
            PlannedSetting(.softWrap(!saved.wrap), source: "editor.wordWrap"),
            PlannedSetting(.terminalCursorBlink(!blinks), source: "terminal.integrated.cursorBlinking", ticked: false),
        ], skipped: [SkippedItem("terminal.integrated.env.osx", "never imported: can hold secrets")])
        var planned = false
        ImportSources.detectors = [{ [editor] }]
        // AE1: listing never plans, so a planner that fails changes nothing.
        ImportSources.planner = { _, _ in
            planned = true
            return nil
        }
        let listed = await importToolCall("list_import_sources", ["include_targets": true])
        let sources = listed.json["sources"] as? [[String: Any]] ?? []
        let listedEditor = sources.first { $0["id"] as? String == "nt-agent-editor" }
        let targets = (listed.json["targets"] as? [String: Any])?["settings"] as? [[String: Any]] ?? []
        check(!listed.isError && listedEditor?["version"] as? String == "1.2.3" && listedEditor?["app_installed"] as? Bool == true && !planned,
              "import tools: list_import_sources lists the apps found without reading their settings", listed.text)
        check(!listed.text.contains("/nonexistent/nt-agent-editor") && !targets.isEmpty,
              "import tools: the listing never names an app's settings folder, and lists what an import can set", listed.text)
        ImportSources.planner = { _, _ in plan }

        let preview = await importToolCall("preview_import", ["source": "nt-agent-editor"])
        let planID = preview.json["plan_id"] as? String ?? ""
        let rowIDs = (preview.json["settings"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        check(!preview.isError && !planID.isEmpty && rowIDs == ["set:fontSize", "set:softWrap", "set:terminalCursorBlink"]
              && (preview.json["shortcut_set"] as? [String: Any])?["id"] as? String == "preset",
              "import tools: preview_import gives the window's rows with their ids and a plan_id", preview.text)

        // AE7: a stale plan id opens nothing.
        let stale = await importToolCall("apply_import", ["source": "nt-agent-editor", "plan_id": "p-000000000000"])
        check(stale.json["status"] as? String == "changed_since_preview" && window.agentAsk == nil,
              "import tools: a stale plan_id answers changed_since_preview and opens no window", stale.text)

        // AE5: Cancel declines, and the same request again is declined at once.
        let cancelled = await importAsked(["source": "nt-agent-editor", "items": ["set:fontSize"]]) { window.endAgentRequest() }
        let again = await importToolCall("apply_import", ["source": "nt-agent-editor", "items": ["set:fontSize"]])
        check(cancelled.json["status"] as? String == "declined" && again.json["status"] as? String == "declined" && window.agentAsk == nil
              && app.fontSize == CGFloat(saved.size), "import tools: Cancel declines, and the same request is then declined without a window",
              cancelled.text + again.text)
        MCPImportControl.declined = []

        // AE3, AE10: the window is the ask, with the agent's rows ticked and the rest not; nothing changes before Apply.
        let reason = "Bring the editor's font size over."
        var shown: [String] = []
        var states: [String: Bool] = [:]
        var unchanged = false
        var unkeyed = false
        let applied = await importAsked(["source": "nt-agent-editor", "items": ["preset", "set:fontSize"], "reason": reason,
                                         "plan_id": planID]) {
            shown = importWindowTexts(window)
            for id in ["preset", "set:fontSize", "set:softWrap", "set:terminalCursorBlink"] { states[id] = importCheckbox(window, id)?.state == .on }
            unchanged = app.fontSize == CGFloat(saved.size) && KeyboardShortcuts.shared.preset == .nextTerm && coordinator.last == nil
            let apply = importButton(window, "Apply \(KeymapPreset.vsCode.overrides.count + 1) Changes")
            unkeyed = window.window?.isKeyWindow == false && apply?.keyEquivalent.isEmpty == true
            window.applyForTest()
        }
        let text = shown.joined(separator: "\n")
        check(text.contains("outside Next Term's tabs") && text.contains("asks to bring these over from NT Agent Editor")
              && text.contains("“\(reason)”") && shown.contains("Decline and Stop Asking"),
              "import tools: apply_import opens the import window with a banner naming who asks, in their words", text)
        check(states == ["preset": true, "set:fontSize": true, "set:softWrap": false, "set:terminalCursorBlink": false],
              "import tools: the agent's rows start ticked and the others unticked", "\(states)")
        check(unchanged && unkeyed, "import tools: nothing changes before the user's Apply, and the window doesn't take the keyboard",
              "unchanged \(unchanged), unkeyed \(unkeyed)")
        let undoID = applied.json["undo_id"] as? String ?? ""
        check(applied.json["status"] as? String == "applied" && applied.json["applied"] as? [String] == ["preset", "set:fontSize"]
              && !undoID.isEmpty && app.fontSize == CGFloat(size) && KeyboardShortcuts.shared.preset == .vsCode,
              "import tools: after Apply the answer lists the rows applied and an undo_id", applied.text)

        // AE7: the same plan again changes nothing: up to date, no window, the Undo kept.
        let upToDate = await importToolCall("apply_import", ["source": "nt-agent-editor", "items": ["preset", "set:fontSize"], "plan_id": planID])
        check(upToDate.json["status"] as? String == "up_to_date" && window.agentAsk == nil && coordinator.last.map(MCPImport.undoID) == undoID,
              "import tools: a plan already applied answers up_to_date, and its Undo stays", upToDate.text)

        // AE4, AE8: the user changes the rows; the banner says the earlier import's Undo goes.
        var warned = false
        let retick = await importAsked(["source": "nt-agent-editor", "items": ["set:softWrap"]]) {
            warned = importWindowTexts(window).contains { $0.hasPrefix("Undo of your import from NT Agent Editor") }
            importCheckbox(window, "set:softWrap")?.performClick(nil)
            importCheckbox(window, "set:terminalCursorBlink")?.performClick(nil)
            window.applyForTest()
        }
        let replaced = (retick.json["replaced_undo_of"] as? [String: Any])?["undo_id"] as? String
        check(retick.json["user_changed"] as? [String] == ["set:terminalCursorBlink ticked", "set:softWrap unticked"]
              && retick.json["applied"] as? [String] == ["set:terminalCursorBlink"] && app.softWrap == saved.wrap,
              "import tools: what the user ticks is what applies, and the answer names what they changed", retick.text)
        check(warned && replaced == undoID, "import tools: the banner warns that the earlier import's Undo goes", retick.text)
        let staleUndo = await importToolCall("undo_import", ["undo_id": undoID])
        check(staleUndo.json["status"] as? String == "stale_undo_id", "import tools: undo_import with an earlier import's id answers stale_undo_id",
              staleUndo.text)

        // Undo's ask names a value changed by hand since; Decline undoes nothing, Approve undoes.
        let currentUndo = retick.json["undo_id"] as? String ?? ""
        app.setTerminalCursor(blinks: blinks)
        var asked = ""
        let declinedUndo = await importUndoAsked(["undo_id": currentUndo]) { approval in
            asked = texts(approval.window?.contentView)
            approval.declineButton.performClick(nil)
        }
        check(declinedUndo.json["status"] as? String == "declined" && asked.contains("Terminal cursor blink") && coordinator.last != nil,
              "import tools: undo_import asks on the Mac, naming what was changed since, and Decline undoes nothing", asked)
        MCPImportControl.declined = []
        let undone = await importUndoAsked(["undo_id": currentUndo]) { approval in approval.approveButton.performClick(nil) }
        check(undone.json["status"] as? String == "undone" && coordinator.last == nil && Preferences.terminalCursorBlinks == blinks,
              "import tools: an approved undo_import puts the import back", undone.text)

        // AE6: no answer in time: pending, the window stays, and the request id brings the answer later.
        MCPImportControl.answerWithin = 2
        let pending = await importToolCall("apply_import", ["source": "nt-agent-editor", "items": ["set:softWrap"]])
        let requestID = pending.json["request_id"] as? String ?? ""
        let stillOpen = window.agentAsk != nil
        let later = Task { await importToolCall("apply_import", ["request_id": requestID]) }
        window.applyForTest()
        let answered = await later.value
        MCPImportControl.answerWithin = saved.wait
        check(pending.json["status"] as? String == "pending" && stillOpen && answered.json["status"] as? String == "applied",
              "import tools: with no answer in time the call answers pending, and the request id brings the answer", pending.text + answered.text)

        // AE12: the user's own import window open: busy, and that window is left alone. A request that would change
        // nothing answers up_to_date first, and the font size and wrap are the plan's by now: the cursor blink still differs.
        window.showChooser(firstRun: false, completion: nil)
        let busy = await importToolCall("apply_import", ["source": "nt-agent-editor", "items": ["set:terminalCursorBlink"]])
        check(busy.json["status"] as? String == "busy" && window.isOpenForUser, "import tools: apply_import answers busy while the user's own import window is open",
              busy.text)
        window.window?.close()

        // One request at a time across the write tools; Decline and Stop Asking stops the agent's write tools too.
        var meanwhile: (text: String, isError: Bool) = ("", false)
        let stopped = await importAsked(["source": "nt-agent-editor", "items": ["set:terminalCursorBlink"]]) {
            meanwhile = await importRawCall("settings_set", ["values": ["soft_wrap": !app.softWrap]])
            importButton(window, "Decline and Stop Asking")?.performClick(nil)
        }
        check(meanwhile.isError && meanwhile.text.contains("Another change is waiting"),
              "import tools: another write tool waits while an import request is open", meanwhile.text)
        let afterStop = await importToolCall("apply_import", ["source": "nt-agent-editor", "items": ["set:softWrap"]])
        let settingsAfter = await importRawCall("settings_set", ["values": ["soft_wrap": !app.softWrap]])
        check(stopped.json["status"] as? String == "declined" && afterStop.json["status"] as? String == "stopped" && window.agentAsk == nil
              && settingsAfter.isError && settingsAfter.text == MCPWriteControl.stoppedText && MCPWriteControl.pending == nil,
              "import tools: after Decline and Stop Asking, apply_import and settings_set are refused without a window", afterStop.text)
        MCPWriteControl.stopped = []
        // The request declined above had this source and plan: forgotten, or the next one would answer declined at once.
        MCPImportControl.declined = []

        // A grant asks nothing of the other write tools, but an import still asks in its window: nothing changes before a click.
        var granted = MCPServer.CallResult(text: "", isError: false)
        let blinkNow = Preferences.terminalCursorBlinks
        MCPControl.call("apply_import", ["source": "nt-agent-editor", "items": ["set:terminalCursorBlink"]], caller: nil,
                        approval: .preApprovedByGrant("g-selftest")) { granted = $0 }
        let grantAsks = await wait(30) { window.agentAsk != nil }
        let grantUnchanged = Preferences.terminalCursorBlinks == blinkNow && granted.text.isEmpty
        window.endAgentRequest()
        _ = await wait(5) { !granted.text.isEmpty }
        check(grantAsks && grantUnchanged && granted.text.contains("declined"),
              "import tools: under a grant the import window still asks, and nothing changes before a click", granted.text)
        MCPImportControl.declined = []

        // AE9: a file an agent names follows read_file's rules, checked before anything is read: refused outside the
        // open projects (a settings file of the test's own, in a temp folder), or when its name says it holds secrets
        // (a made-up path); and format is required with path.
        let scratch = NSTemporaryDirectory() + "nt-import-agent-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        FileManager.default.createFile(atPath: scratch + "/settings.json", contents: Data(#"{"editor.fontSize": 20}"#.utf8))
        let outside = await importToolCall("preview_import", ["path": scratch + "/settings.json", "format": "vscode-settings"])
        let secretFile = await importToolCall("preview_import", ["path": "/nonexistent/nt-agent-editor/.env", "format": "vscode-settings"])
        let noFormat = await importToolCall("preview_import", ["path": "/nonexistent/nt-agent-editor/settings.json"])
        let outsideRefused = outside.isError && outside.text.contains("outside the projects open")
        let secretRefused = secretFile.isError && secretFile.text.hasPrefix("Not read:")
        let formatAsked = noFormat.isError && noFormat.text.contains("Give format")
        check(outsideRefused && secretRefused && formatAsked,
              "import tools: a named file outside the open projects, or one that holds secrets, is refused; path needs format",
              [outside.text, secretFile.text, noFormat.text].joined(separator: "\n"))

        // Local only: the remote door is refused, whatever its grant.
        var remote = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("apply_import", ["source": "nt-agent-editor"], caller: nil, approval: .preApprovedByGrant("g-selftest"),
                        requester: "the connection “Self-test”", connection: "g-selftest") { remote = $0 }
        _ = await wait(5) { !remote.text.isEmpty }
        check(remote.isError && remote.text == MCPImportControl.localOnly && window.agentAsk == nil,
              "import tools: the remote door gets none of them", remote.text)
    }

    // MARK: calls

    /// A tool call as a local agent outside Next Term's tabs makes it, with its answer as JSON.
    static func importToolCall(_ tool: String, _ arguments: [String: Any]) async -> (json: [String: Any], text: String, isError: Bool) {
        let result = await importRawCall(tool, arguments)
        let json = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return (json, result.text, result.isError)
    }

    static func importRawCall(_ tool: String, _ arguments: [String: Any]) async -> (text: String, isError: Bool) {
        await withCheckedContinuation { continuation in
            MCPControl.call(tool, arguments, caller: nil) { result in continuation.resume(returning: (result.text, result.isError)) }
        }
    }

    /// apply_import, answered in the import window by `answer` once it shows the agent's request.
    static func importAsked(_ arguments: [String: Any], answer: @escaping () async -> Void) async -> (json: [String: Any], text: String, isError: Bool) {
        let call = Task { await importToolCall("apply_import", arguments) }
        if await wait(30, { ImportWindowController.shared.agentAsk != nil }) {
            await pause(0.2)
            await answer()
        } else {
            check(false, "import tools: apply_import opens the import window")
        }
        return await call.value
    }

    /// undo_import, answered in its approval window.
    static func importUndoAsked(_ arguments: [String: Any], answer: @escaping (AgentApprovalWindow) -> Void) async -> (json: [String: Any], text: String, isError: Bool) {
        let call = Task { await importToolCall("undo_import", arguments) }
        if await wait(30, { MCPImportControl.open?.approval != nil }), let approval = MCPImportControl.open?.approval {
            await pause(0.2)
            answer(approval)
        } else {
            check(false, "import tools: undo_import asks in an approval window")
        }
        return await call.value
    }

    /// The import window's checkbox for a row id.
    static func importCheckbox(_ window: ImportWindowController, _ id: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.window?.contentView.flatMap(find)
    }

    /// The import window's button titled `title`.
    static func importButton(_ window: ImportWindowController, _ title: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.window?.contentView.flatMap(find)
    }
}
