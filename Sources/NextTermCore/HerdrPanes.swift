import Foundation

/// herdr's `pane list`, counted: which herdr tab and workspace each pane is in, how many panes each has, and the session
/// in all. close_tab on an agent's id reads it before asking and again just before closing. herdr 0.9.1 closes a tab with
/// its last pane, and a workspace with its last tab, while the session's server keeps running (checked on a scratch herdr
/// of Next Term's own, 2026-10-28: a one-pane tab, a one-pane workspace beside another, and the session's last pane). So
/// the window says what closes with the pane, and the session's last pane is never closed from here.
public struct HerdrPanes: Equatable, Sendable {
    /// Each pane's herdr tab and workspace, by pane id.
    public var tabOf: [String: String]
    public var workspaceOf: [String: String]
    /// Panes by herdr tab id, and by workspace id.
    public var byTab: [String: Int]
    public var byWorkspace: [String: Int]
    /// Every pane in the session.
    public var total: Int

    public init(tabOf: [String: String] = [:], workspaceOf: [String: String] = [:], byTab: [String: Int],
                byWorkspace: [String: Int] = [:], total: Int) {
        self.tabOf = tabOf
        self.workspaceOf = workspaceOf
        self.byTab = byTab
        self.byWorkspace = byWorkspace
        self.total = total
    }

    /// herdr's JSON (`{"result": {"panes": [...]}}`, or the bare result); nil when it is not a pane list.
    public static func parse(_ json: String) -> HerdrPanes? {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let result: Any = (value as? [String: Any])?["result"] ?? value
        let list: [Any]?
        if let object = result as? [String: Any] { list = object["panes"] as? [Any] } else { list = result as? [Any] }
        guard let list else { return nil }
        var panes = HerdrPanes(byTab: [:], total: 0)
        for case let item as [String: Any] in list {
            panes.total += 1
            let pane: String? = item["pane_id"] as? String
            if let tab = item["tab_id"] as? String {
                panes.byTab[tab, default: 0] += 1
                if let pane { panes.tabOf[pane] = tab }
            }
            if let workspace = item["workspace_id"] as? String {
                panes.byWorkspace[workspace, default: 0] += 1
                if let pane { panes.workspaceOf[pane] = workspace }
            }
        }
        return panes
    }

    /// The pane is its herdr tab's only one, so closing it closes that tab too.
    public func isAlone(tab: String?) -> Bool { tab.map { byTab[$0] == 1 } ?? false }

    /// The pane is its workspace's only one, so closing it closes that tab and that workspace too.
    public func isAloneInWorkspace(pane: String) -> Bool { workspaceOf[pane].map { byWorkspace[$0] == 1 } ?? false }

    /// Why the pane must not be closed from here, or nil: it is the session's last.
    public var lastPaneRefusal: String? {
        total <= 1 ? "That is the last pane of its herdr session: closing it would leave the session with no workspace. Close it in herdr. Nothing was closed." : nil
    }
}
