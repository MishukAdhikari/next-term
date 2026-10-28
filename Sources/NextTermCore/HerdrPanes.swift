import Foundation

/// herdr's `pane list`, counted: how many panes each herdr tab has, and the session in all. close_tab on an agent's id
/// reads it before asking and again just before closing. herdr 0.9.1 closes a tab with its last pane, and a workspace with
/// its last tab, while the session's server keeps running (checked on a scratch herdr of Next Term's own, 2026-10-28), so
/// the window says when the agent's herdr tab closes too, and the session's last pane is never closed from here.
public struct HerdrPanes: Equatable, Sendable {
    /// Panes by herdr tab id.
    public var byTab: [String: Int]
    /// Every pane in the session.
    public var total: Int

    public init(byTab: [String: Int], total: Int) {
        self.byTab = byTab
        self.total = total
    }

    /// herdr's JSON (`{"result": {"panes": [...]}}`, or the bare result); nil when it is not a pane list.
    public static func parse(_ json: String) -> HerdrPanes? {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let result: Any = (value as? [String: Any])?["result"] ?? value
        let list: [Any]?
        if let object = result as? [String: Any] { list = object["panes"] as? [Any] } else { list = result as? [Any] }
        guard let list else { return nil }
        var byTab: [String: Int] = [:]
        var total = 0
        for case let item as [String: Any] in list {
            total += 1
            if let tab = item["tab_id"] as? String { byTab[tab, default: 0] += 1 }
        }
        return HerdrPanes(byTab: byTab, total: total)
    }

    /// The pane is its herdr tab's only one, so closing it closes that tab too.
    public func isAlone(tab: String?) -> Bool { tab.map { byTab[$0] == 1 } ?? false }

    /// Why the pane must not be closed from here, or nil: it is the session's last.
    public var lastPaneRefusal: String? {
        total <= 1 ? "That is the last pane of its herdr session: closing it would leave the session with no workspace. Close it in herdr. Nothing was closed." : nil
    }
}
