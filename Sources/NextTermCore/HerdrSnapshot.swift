import Foundation

/// herdr's whole session in one read (`api snapshot`, plan 040 U6, U8, U9): its workspaces, each workspace's tabs, each
/// tab's panes with where they sit and whether the tab is zoomed, and what integrations report for them (a workspace's
/// tokens, a pane's title and state labels). Read only: Next Term shows it, never reports into it.
public struct HerdrSnapshot: Equatable, Sendable {
    public struct Workspace: Equatable, Sendable {
        public var id: String
        public var label: String?
        public var focused: Bool
        /// Display-only values an integration reported for it (`workspace report-metadata --token`).
        public var tokens: [String: String]
        /// The checkout herdr keeps it on, for a worktree's workspace.
        public var checkout: String?
        public var linkedWorktree: Bool
        public var tabs: [Tab]
    }

    public struct Tab: Equatable, Sendable {
        public var id: String
        public var label: String?
        public var focused: Bool
        public var zoomed: Bool
        public var panes: [Pane]
    }

    public struct Pane: Equatable, Sendable {
        public var id: String
        public var label: String?
        /// What an integration reported (`pane report-metadata --title`), else none.
        public var title: String?
        public var status: String
        public var directory: String?
        public var focused: Bool
        /// Its place in the tab, in herdr's cells.
        public var rect: (x: Int, y: Int, width: Int, height: Int)?
        public var stateLabels: [String: String]

        public static func == (a: Pane, b: Pane) -> Bool {
            a.id == b.id && a.label == b.label && a.title == b.title && a.status == b.status && a.directory == b.directory
                && a.focused == b.focused && a.stateLabels == b.stateLabels
                && a.rect?.x == b.rect?.x && a.rect?.y == b.rect?.y && a.rect?.width == b.rect?.width && a.rect?.height == b.rect?.height
        }
    }

    public var workspaces: [Workspace]
    public var version: String?

    /// The snapshot in herdr's answer (`{"result": {"snapshot": {…}}}`), or nil when it is not one.
    public static func parse(_ json: String) -> HerdrSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any], let snapshot = result["snapshot"] as? [String: Any],
              let workspaces = snapshot["workspaces"] as? [[String: Any]] else { return nil }
        let tabs: [[String: Any]] = snapshot["tabs"] as? [[String: Any]] ?? []
        let panes: [[String: Any]] = snapshot["panes"] as? [[String: Any]] ?? []
        let layouts: [[String: Any]] = snapshot["layouts"] as? [[String: Any]] ?? []
        func text(_ object: [String: Any], _ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func strings(_ value: Any?) -> [String: String] { (value as? [String: Any])?.compactMapValues { $0 as? String } ?? [:] }
        var layoutOf: [String: [String: Any]] = [:]
        for layout in layouts { if let tab = layout["tab_id"] as? String { layoutOf[tab] = layout } }
        func paneModel(_ pane: [String: Any], layout: [String: Any]?) -> Pane? {
            guard let id = pane["pane_id"] as? String else { return nil }
            let placed = (layout?["panes"] as? [[String: Any]])?.first { $0["pane_id"] as? String == id }
            var rect: (x: Int, y: Int, width: Int, height: Int)?
            if let r = placed?["rect"] as? [String: Any], let x = r["x"] as? Int, let y = r["y"] as? Int,
               let width = r["width"] as? Int, let height = r["height"] as? Int {
                rect = (x, y, width, height)
            }
            return Pane(id: id, label: text(pane, "label"), title: text(pane, "title"), status: pane["agent_status"] as? String ?? "unknown",
                        directory: text(pane, "cwd"), focused: pane["focused"] as? Bool ?? false, rect: rect,
                        stateLabels: strings(pane["state_labels"]))
        }
        let models: [Workspace] = workspaces.compactMap { workspace in
            guard let id = workspace["workspace_id"] as? String else { return nil }
            let own: [Tab] = tabs.filter { $0["workspace_id"] as? String == id }.compactMap { tab in
                guard let tabID = tab["tab_id"] as? String else { return nil }
                let layout = layoutOf[tabID]
                let inTab: [Pane] = panes.filter { $0["tab_id"] as? String == tabID }.compactMap { paneModel($0, layout: layout) }
                return Tab(id: tabID, label: text(tab, "label"), focused: tab["focused"] as? Bool ?? false,
                           zoomed: layout?["zoomed"] as? Bool ?? false, panes: inTab)
            }
            let worktree = workspace["worktree"] as? [String: Any]
            return Workspace(id: id, label: text(workspace, "label"), focused: workspace["focused"] as? Bool ?? false,
                             tokens: strings(workspace["tokens"]), checkout: worktree.flatMap { text($0, "checkout_path") },
                             linkedWorktree: worktree?["is_linked_worktree"] as? Bool ?? false, tabs: own)
        }
        return HerdrSnapshot(workspaces: models, version: snapshot["version"] as? String)
    }

    /// The workspace that holds a herdr tab, and the tab.
    public func tab(_ id: String) -> (workspace: Workspace, tab: Tab)? {
        for workspace in workspaces { if let tab = workspace.tabs.first(where: { $0.id == id }) { return (workspace, tab) } }
        return nil
    }

    public func workspace(_ id: String) -> Workspace? { workspaces.first { $0.id == id } }

    /// Every pane in the session.
    public var paneCount: Int { workspaces.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.panes.count } } }

    /// What list_tabs gives with herdr_layout: each workspace with its tabs, each tab with its panes, ids as Next Term
    /// names them (`<tab id>/ws:w1`, `<tab id>/tab:w1:t1`, `<tab id>/w1:p1`; HerdrTarget.container) so the tab tools
    /// take them.
    public func listing(tabID: String) -> [[String: Any]] {
        workspaces.map { workspace in
            var entry: [String: Any] = ["id": HerdrTarget.container(tabID: tabID, workspace: workspace.id), "workspace": workspace.id,
                                        "focused": workspace.focused]
            if let label = workspace.label { entry["label"] = label }
            if !workspace.tokens.isEmpty { entry["tokens"] = workspace.tokens }
            if let checkout = workspace.checkout { entry["checkout"] = checkout; entry["linked_worktree"] = workspace.linkedWorktree }
            entry["tabs"] = workspace.tabs.map { tab -> [String: Any] in
                var row: [String: Any] = ["id": HerdrTarget.container(tabID: tabID, tab: tab.id), "tab": tab.id, "focused": tab.focused,
                                          "zoomed": tab.zoomed]
                if let label = tab.label { row["label"] = label }
                row["panes"] = tab.panes.map { pane -> [String: Any] in
                    var item: [String: Any] = ["id": HerdrTarget(tabID: tabID, pane: pane.id).id, "pane": pane.id, "state": pane.status,
                                               "focused": pane.focused]
                    if let label = pane.label { item["label"] = label }
                    if let title = pane.title { item["title"] = title }
                    if let directory = pane.directory { item["directory"] = directory }
                    if !pane.stateLabels.isEmpty { item["state_labels"] = pane.stateLabels }
                    if let rect = pane.rect { item["place"] = ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height] }
                    return item
                }
                return row
            }
            return entry
        }
    }
}

extension HerdrTarget {
    /// A herdr tab's or workspace's id over MCP (plan 040 D3): the Next Term tab's id, a slash, and `tab:` or `ws:` with
    /// herdr's own id, so the tab tools take it as they take an agent's.
    public static func container(tabID: String, tab: String) -> String { tabID.lowercased() + "/tab:" + tab }
    public static func container(tabID: String, workspace: String) -> String { tabID.lowercased() + "/ws:" + workspace }

    /// What a target names when it is a herdr tab or workspace: nil for a pane.
    public var containerKind: (kind: Container, id: String)? {
        if pane.hasPrefix("tab:") { return (.tab, String(pane.dropFirst(4))) }
        if pane.hasPrefix("ws:") { return (.workspace, String(pane.dropFirst(3))) }
        if pane.hasPrefix("session:") { return (.session, String(pane.dropFirst(8))) }
        return nil
    }

    public enum Container: String, Sendable {
        case tab, workspace, session
    }

    /// One of herdr's sessions' id over MCP (plan 040 U10): the Next Term tab that shows herdr there, `/session:` and
    /// the session's name.
    public static func container(tabID: String, session: String) -> String { tabID.lowercased() + "/session:" + session }
}
