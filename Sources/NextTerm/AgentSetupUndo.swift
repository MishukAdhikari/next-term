import AppKit
import NextTermCore

/// Next Term › Undo Agent Setup…: puts back what the last apply_setup changed (AgentSetupSnapshot), after an alert that
/// says what goes back and names what the user changed by hand since. Settings go back through settings_set's own path
/// and the layout through set_layout's, so each applies at once as from Settings or the View menu; the import goes back
/// through Undo Import while it is still the last import. Kept in UserDefaults, so the item stays across relaunches until
/// it is used or a later setup takes its place.
@MainActor
enum AgentSetupUndo {
    private static let key = "agentSetupSnapshot"
    /// Posted when the kept setup changes, for the menu item.
    nonisolated static let changed = Notification.Name("NextTermAgentSetupChanged")

    static var last: AgentSetupSnapshot? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AgentSetupSnapshot.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The menu item as the kept setup has it: shown only while there is one with something left to put back (a setup
    /// that was only an import, undone or replaced since, has nothing), its tooltip the change log line.
    static func refresh(_ item: NSMenuItem?) {
        let kept = last.flatMap { $0.canUndo(importIsLast: importIsLast($0)) ? $0 : nil }
        item?.isHidden = kept == nil
        item?.toolTip = kept?.logLine()
    }

    /// The settings and layout fields the setup changed, with their values now.
    static func now(_ snapshot: AgentSetupSnapshot) -> (settings: [String: MCPSettings.Value], layout: [String: String]) {
        var settings: [String: MCPSettings.Value] = [:]
        for entry in snapshot.settings {
            if let setting = MCPSettings.setting(entry.name) { settings[entry.name] = MCPWriteControl.value(of: setting) }
        }
        var layout = MCPSetupControl.layoutNow(nil)
        for project in snapshot.perWindowProjects {
            guard let controller = window(of: project, in: snapshot) else { continue }
            for (field, value) in MCPSetupControl.layoutNow(controller) where AgentSetup.perWindowFields.contains(field) { layout[field] = value }
        }
        return (settings, layout)
    }

    /// The window a setup's per-window fields went to, while it stays open in this run, with the setup's id: a window
    /// with no project, such as the home folder's that Set up with your agent opens, can't be found by its project.
    private static weak var setupWindow: TerminalWindowController?
    private static var setupWindowSetup: String?

    /// Keeps the window `snapshot`'s per-window fields went to, for Undo in this run.
    static func remember(_ controller: TerminalWindowController?, for snapshot: AgentSetupSnapshot) {
        setupWindow = controller
        setupWindowSetup = snapshot.id
    }

    /// The open window a per-window field went to: the one kept for this setup while it is open, else the project's
    /// (nil project: only the kept one).
    static func window(of project: String?, in snapshot: AgentSetupSnapshot) -> TerminalWindowController? {
        let open = AppDelegate.shared.controllers
        if setupWindowSetup == snapshot.id, let kept = setupWindow, kept.project == project, open.contains(where: { $0 === kept }) {
            return kept
        }
        guard let project else { return nil }
        return open.first { $0.project == project }
    }

    /// Whether the setup's import is still the one Undo Import would undo.
    static func importIsLast(_ snapshot: AgentSetupSnapshot) -> Bool {
        guard let id = snapshot.importUndoID, let current = ImportCoordinator.shared.last else { return false }
        return MCPImport.undoID(current) == id
    }

    /// The menu's action: asks first, naming what goes back.
    static func confirmAndUndo() {
        guard let snapshot = last else { return }
        // Only an import, undone or replaced since: nothing is left to put back.
        guard snapshot.canUndo(importIsLast: importIsLast(snapshot)) else { return last = nil }
        let current = now(snapshot)
        let alert = NSAlert()
        alert.messageText = "Undo the agent’s setup?"
        alert.informativeText = snapshot.undoMessage(changedSince: snapshot.changedSince(settings: current.settings, layout: current.layout),
                                                     importIsLast: importIsLast(snapshot))
        alert.addButton(withTitle: "Undo Agent Setup")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        undo(snapshot)
    }

    /// Puts back every value the setup changed: the import first (the newest change), then the layout, then the settings.
    static func undo(_ snapshot: AgentSetupSnapshot) {
        if importIsLast(snapshot) { ImportCoordinator.shared.undo() }
        MCPWriteControl.applyLayout(snapshot.layoutBefore(perWindow: false), in: nil, asked: true)
        for project in snapshot.perWindowProjects {
            let before = snapshot.layoutBefore(perWindow: true, project: project)
            guard let controller = window(of: project, in: snapshot) else {
                // The window is gone, but showing or hiding its sidebar also set the one new windows take: that goes back.
                if let shown = before.sidebarShown { AppDelegate.shared.sidebarVisible = shown }
                continue
            }
            MCPWriteControl.applyLayout(before, in: controller, asked: true)
        }
        for entry in snapshot.settings {
            guard let setting = MCPSettings.setting(entry.name) else { continue }
            MCPWriteControl.apply(setting, entry.before)
        }
        last = nil
    }
}

extension AppDelegate {
    @objc func undoAgentSetup(_ sender: Any?) {
        MainActor.assumeIsolated { AgentSetupUndo.confirmAndUndo() }
    }

    @objc func agentSetupChanged(_ notification: Notification?) {
        MainActor.assumeIsolated { AgentSetupUndo.refresh(undoAgentSetupItem) }
    }
}
