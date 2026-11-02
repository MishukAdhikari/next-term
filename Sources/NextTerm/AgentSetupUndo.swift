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
            guard let controller = window(of: project) else { continue }
            for (field, value) in MCPSetupControl.layoutNow(controller) where AgentSetup.perWindowFields.contains(field) { layout[field] = value }
        }
        return (settings, layout)
    }

    /// The open window of a project, for a per-window field (nil project: none is looked for).
    static func window(of project: String?) -> TerminalWindowController? {
        guard let project else { return nil }
        return AppDelegate.shared.controllers.first { $0.project == project }
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
            guard let controller = window(of: project) else { continue }
            MCPWriteControl.applyLayout(snapshot.layoutBefore(perWindow: true, project: project), in: controller, asked: true)
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
