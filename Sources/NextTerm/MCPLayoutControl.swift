import AppKit
import NextTermCore

/// focus_tab, split_pane, close_pane, zoom_pane, set_layout, settings_get and settings_set: what the View
/// menu, the pane commands and a few settings do, each asked about first. A call that would change nothing
/// answers at once, without asking.
extension MCPWriteControl {
    // MARK: panes

    static func focusTab(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        let tab: TerminalTab, controller: TerminalWindowController
        switch paneTarget(arguments) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let found): (tab, controller) = (found.0, found.1)
        }
        let id = tab.id.uuidString.lowercased()
        if controller.activeTab === tab, controller.window?.firstResponder === tab.view {
            return reply(MCPControl.ok(["id": id, "focused": true, "note": "It has its window's keyboard already."]))
        }
        let ask = Ask(title: "An agent asks to move the keyboard to a tab",
                      details: "“\(tab.title)” comes to the front of \(place(controller)) and takes its keyboard: what you type in that window goes to it. The window stays where it is.")
        approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            guard let controller = MCPControl.controller(of: tab) else { return reply(MCPControl.fail("That tab closed meanwhile; nothing changed.")) }
            if let why = MCPInputLine.refusal(tab) { return reply(MCPControl.fail(why)) }
            controller.show(tab)
            reply(MCPControl.ok(["id": id, "focused": true, "approved": approved]))
        }
    }

    static func splitPane(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        let tab: TerminalTab, controller: TerminalWindowController
        switch paneTarget(arguments) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let found): (tab, controller) = (found.0, found.1)
        }
        let direction = arguments["direction"] as? String ?? "right"
        guard direction == "right" || direction == "down" else { return reply(MCPControl.fail("direction is right or down.")) }
        var directory: String?
        if let raw = arguments["directory"] {
            guard let text = raw as? String, text.hasPrefix("/") || text.hasPrefix("~") else {
                return reply(MCPControl.fail("directory is an absolute folder on this Mac."))
            }
            let path = canonicalPath((text as NSString).expandingTildeInPath)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return reply(MCPControl.fail("Not a folder: \(text)"))
            }
            directory = path
        }
        let down = direction == "down"
        let folder = directory ?? (tab.remote.map { "\(tab.directory) on \($0.host.name)" } ?? tab.directory)
        let ask = Ask(title: "An agent asks to split a pane",
                      details: "A new terminal opens \(down ? "below" : "to the right of") “\(tab.title)” in \(place(controller)), in \(folder). It doesn't take the keyboard.")
        approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            guard let controller = MCPControl.controller(of: tab) else { return reply(MCPControl.fail("That tab closed meanwhile; nothing changed.")) }
            guard let pane = controller.split(vertical: !down, from: tab, directory: directory, focus: false) else {
                return reply(MCPControl.fail("Could not split that tab."))
            }
            MCPControl.driven.insert(pane.id) // the agent that asked for it waits for its work
            reply(MCPControl.ok(["id": pane.id.uuidString.lowercased(), "beside": tab.id.uuidString.lowercased(),
                                 "directory": pane.directory, "approved": approved]))
        }
    }

    static func closePane(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        let tab: TerminalTab, controller: TerminalWindowController, group: PaneGroup
        switch paneTarget(arguments) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let found): (tab, controller, group) = found
        }
        guard group.isSplit else { return reply(MCPControl.fail("That tab is not split; close_tab closes a whole tab.")) }
        if tab === context.caller { return reply(MCPControl.fail("That is your own pane.")) }
        let force = arguments["force"] as? Bool ?? false
        let id = tab.id.uuidString.lowercased()
        let kept = tab.remote != nil && tab.isKept
        if !kept, let warning = tab.closeWarning, !force {
            return reply(MCPControl.fail("The pane is running \(warning); pass force: true to stop it and close the pane."))
        }
        var details = "Closes the pane “\(tab.title)” in \(place(controller)); the tab's other panes stay."
        if kept, let host = tab.remote?.host.name { details += " It only detaches: what runs on \(host) keeps running." }
        if !kept, let warning = tab.closeWarning { details += " This stops \(warning)." }
        approve(Ask(title: "An agent asks to close a pane", details: details), context, reply: reply) { approved, window in
            window?.finish()
            guard let controller = MCPControl.controller(of: tab), controller.group(of: tab)?.isSplit == true else {
                return reply(MCPControl.fail("That pane closed meanwhile, or its tab is no longer split; nothing changed."))
            }
            if !kept, let warning = tab.closeWarning, !force {
                return reply(MCPControl.fail("The pane started running \(warning) meanwhile; pass force: true to stop it and close the pane."))
            }
            controller.remove(tab)
            var answer: [String: Any] = ["id": id, "closed": true, "approved": approved]
            if kept { answer["detached"] = true }
            reply(MCPControl.ok(answer))
        }
    }

    static func zoomPane(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        let tab: TerminalTab, controller: TerminalWindowController, group: PaneGroup
        switch paneTarget(arguments) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let found): (tab, controller, group) = found
        }
        guard group.isSplit else { return reply(MCPControl.fail("That tab is not split; there is nothing to zoom.")) }
        if let raw = arguments["zoomed"], !MCPServer.isBoolean(raw) { return reply(MCPControl.fail("zoomed must be true or false.")) }
        let zoomed = arguments["zoomed"] as? Bool ?? true
        let id = tab.id.uuidString.lowercased()
        if zoomed ? group.zoomed === tab : group.zoomed == nil {
            return reply(MCPControl.ok(["id": id, "zoomed": zoomed, "note": "It is so already."]))
        }
        let details = zoomed ? "“\(tab.title)” fills its tab in \(place(controller)) and takes the window's keyboard; the other panes keep running behind it."
                             : "Every pane of the tab with “\(tab.title)” in \(place(controller)) comes back."
        approve(Ask(title: zoomed ? "An agent asks to zoom a pane" : "An agent asks to bring the panes back", details: details), context, reply: reply) { approved, window in
            window?.finish()
            guard let controller = MCPControl.controller(of: tab), let group = controller.group(of: tab), group.isSplit else {
                return reply(MCPControl.fail("That pane closed meanwhile, or its tab is no longer split; nothing changed."))
            }
            controller.setZoomed(zoomed ? tab : nil, in: group)
            reply(MCPControl.ok(["id": id, "zoomed": zoomed, "approved": approved]))
        }
    }

    // MARK: layout

    /// The window set_layout's per-window changes go to: the project's, the caller's, or the front one.
    private static func layoutWindow(_ arguments: [String: Any], _ context: Context) -> Result<TerminalWindowController, MCPToolError> {
        let controllers = AppDelegate.shared.controllers
        if arguments["project"] != nil {
            switch context.projects.project(arguments["project"]) {
            case .failure(let error): return .failure(error)
            case .success(let folder):
                let holders = controllers.filter { $0.project.map { folder == $0 || folder.hasPrefix($0 + "/") } ?? false }
                guard let holder = holders.max(by: { ($0.project?.count ?? 0) < ($1.project?.count ?? 0) }) else {
                    return .failure(MCPToolError("No window has \(folder) open."))
                }
                return .success(holder)
            }
        }
        if let mine = context.caller.flatMap(MCPControl.controller(of:)) { return .success(mine) }
        if let front = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? controllers.last { return .success(front) }
        return .failure(MCPToolError("No Next Term window is open."))
    }

    private static func layout(of controller: TerminalWindowController) -> [String: Any] {
        let app = AppDelegate.shared!
        var layout: [String: Any] = [
            "terminal_position": app.terminalPosition.rawValue, "sidebar_side": app.sidebarSide.rawValue,
            "sidebar": controller.isSidebarVisible ? "shown" : "hidden", "terminal_folded": controller.terminalCollapsed,
        ]
        if let project = controller.project { layout["project"] = project }
        return layout
    }

    static func setLayout(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        let wanted: MCPLayoutChange
        switch MCPLayoutChange.parse(arguments) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let change): wanted = change
        }
        let controller: TerminalWindowController
        switch layoutWindow(arguments, context) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let found): controller = found
        }
        let app = AppDelegate.shared!
        var change = MCPLayoutChange()
        var lines: [String] = []
        if let position = wanted.terminalPosition, position != app.terminalPosition.rawValue {
            change.terminalPosition = position
            lines.append("The terminal moves from \(app.terminalPosition.rawValue) to \(position), in every window.")
        }
        if let side = wanted.sidebarSide, side != app.sidebarSide.rawValue {
            change.sidebarSide = side
            lines.append("The project sidebar moves to the \(side), in every window.")
        }
        if let shown = wanted.sidebarShown, shown != controller.isSidebarVisible {
            change.sidebarShown = shown
            lines.append("The project sidebar is \(shown ? "shown" : "hidden") in \(place(controller)).")
        }
        if let folded = wanted.terminalFolded {
            if folded, controller.editorArea.isHidden {
                return reply(MCPControl.fail("The editor is closed in that window (no file is open), so the terminal fills it and can’t fold; nothing changed."))
            }
            // A new terminal position unfolds it: fold again after the move.
            if folded != controller.terminalCollapsed || (folded && change.terminalPosition != nil) {
                change.terminalFolded = folded
                lines.append("The terminal is \(folded ? "folded" : "unfolded") in \(place(controller)).")
            }
        }
        if change.isEmpty {
            var answer = layout(of: controller)
            answer["changed"] = [String]()
            return reply(MCPControl.ok(answer))
        }
        approve(Ask(title: "An agent asks to change the layout", details: lines.joined(separator: "\n")), context, reply: reply) { approved, window in
            window?.finish()
            var changed: [String] = []
            if let position = change.terminalPosition {
                app.applyImported(.terminalPosition(position))
                changed.append("terminal_position")
            }
            if let side = change.sidebarSide {
                app.applyImported(.sidebarSide(side))
                changed.append("sidebar_side")
            }
            let open = AppDelegate.shared.controllers.contains { $0 === controller }
            if open, let shown = change.sidebarShown {
                app.sidebarVisible = shown
                controller.setSidebarVisible(shown)
                changed.append("sidebar")
            }
            if open, let folded = change.terminalFolded {
                if folded { controller.collapseTerminal() } else { controller.expandTerminal() }
                changed.append("terminal_folded")
            }
            var answer = layout(of: controller)
            answer["changed"] = changed
            answer["approved"] = approved
            reply(MCPControl.ok(answer))
        }
    }

    // MARK: settings

    /// A setting's value now.
    static func value(of setting: MCPSettings.Setting) -> MCPSettings.Value {
        let app = AppDelegate.shared!
        let notifications = NotificationSettings(defaults: .standard)
        switch setting.name {
        case "font_size": return .number(Double(app.fontSize))
        case "line_height": return .number((Double(app.editorLineHeight) * 100).rounded() / 100)
        case "soft_wrap": return .flag(app.softWrap)
        case "terminal_position": return .choice(app.terminalPosition.rawValue)
        case "notify_decisions": return .flag(notifications.decisions)
        case "notify_agent_finished": return .flag(notifications.agentFinished)
        case "notify_program_alerts": return .flag(notifications.programAlerts)
        case "notification_sound": return .flag(notifications.sound)
        default: return .flag(false)
        }
    }

    /// Sets a value the way the menus and Settings do, so it applies at once.
    private static func apply(_ setting: MCPSettings.Setting, _ value: MCPSettings.Value) {
        let app = AppDelegate.shared!
        switch (setting.name, value) {
        case ("font_size", .number(let size)): app.setFontSize(CGFloat(size))
        case ("line_height", .number(let factor)): app.editorLineHeight = CGFloat(factor)
        case ("soft_wrap", .flag(let on)): app.applyImported(.softWrap(on))
        case ("terminal_position", .choice(let position)): app.applyImported(.terminalPosition(position))
        case ("notify_decisions", .flag(let on)): UserDefaults.standard.set(on, forKey: NotificationSettings.Key.decisions)
        case ("notify_agent_finished", .flag(let on)): UserDefaults.standard.set(on, forKey: NotificationSettings.Key.agentFinished)
        case ("notify_program_alerts", .flag(let on)): UserDefaults.standard.set(on, forKey: NotificationSettings.Key.programAlerts)
        case ("notification_sound", .flag(let on)): UserDefaults.standard.set(on, forKey: NotificationSettings.Key.sound)
        default: break
        }
    }

    private static func same(_ a: MCPSettings.Value, _ b: MCPSettings.Value) -> Bool {
        if case .number(let x) = a, case .number(let y) = b { return abs(x - y) < 0.001 }
        return a == b
    }

    static func settingsList() -> [String: Any] {
        let settings: [[String: Any]] = MCPSettings.allowlist.map { setting in
            ["name": setting.name, "title": setting.title, "value": value(of: setting).json, "takes": setting.takes]
        }
        return ["settings": settings, "note": "settings_set changes these, and nothing else. set_layout shows or hides the project sidebar and folds the terminal."]
    }

    static func setSettings(_ arguments: [String: Any], _ context: Context, reply: @escaping Reply) {
        let asked: [(MCPSettings.Setting, MCPSettings.Value)]
        switch MCPSettings.changes(arguments["values"]) {
        case .failure(let error): return reply(MCPControl.fail(error.text))
        case .success(let changes): asked = changes
        }
        let changes = asked.filter { !same(value(of: $0.0), $0.1) }
        guard !changes.isEmpty else { return reply(MCPControl.ok(["changed": [String](), "note": "Those values are set already."])) }
        let lines = changes.map { "\($0.0.title): \(value(of: $0.0).text) → \($0.1.text)" }
        approve(Ask(title: "An agent asks to change settings", details: lines.joined(separator: "\n")), context, reply: reply) { approved, window in
            window?.finish()
            for (setting, value) in changes { apply(setting, value) }
            var values: [String: Any] = [:]
            for (setting, _) in changes { values[setting.name] = value(of: setting).json }
            reply(MCPControl.ok(["changed": changes.map(\.0.name), "values": values, "approved": approved]))
        }
    }
}

extension TerminalWindowController {
    /// zoom_pane: `tab` fills its tab (nil: every pane comes back), as Maximize Pane does for the focused
    /// pane. The zoomed pane takes the window's keyboard, since the one that had it may be hidden now.
    /// Bringing the panes back keeps the keyboard where it is: in the pane that had it, or in the editor.
    func setZoomed(_ tab: TerminalTab?, in group: PaneGroup) {
        let paneHadKeyboard = group.panes.contains { window?.firstResponder === $0.view }
        group.zoomed = tab
        if let tab { group.focused = tab }
        group.layout()
        window?.contentView?.layoutSubtreeIfNeeded()
        if group === activeGroup, tab != nil || paneHadKeyboard { window?.makeFirstResponder(group.focused.view) }
        group.updateDimming()
        refreshVisibility()
        refresh()
    }
}
