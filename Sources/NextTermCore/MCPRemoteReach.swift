import Foundation

/// What a call through a remote connection (plan 004's door) may not reach for now (plan 010a U11): herdr's agents and
/// herdr's own machines, by their ids, and the tools plan 010a adds, until the door names each in an option of its own.
/// A call on this Mac's own socket (no connection, no remote requester) is never refused here.
public enum MCPRemoteReach {
    /// The tools only this Mac's own agents may call for now.
    public static let localOnlyTools: Set<String> = ["edit_host", "end_session", "rename_tab", "start_agent"]

    public static let text = "Only an agent on this Mac can do that for now: calls through a remote connection reach no herdr "
        + "agent's id, and not edit_host, end_session, rename_tab or start_agent."

    /// Why a call through a remote connection is refused, or nil: one of the tools above, or any tab tool given a herdr
    /// agent's id (one of herdr's machines' included).
    public static func refusal(_ tool: String, _ arguments: [String: Any]) -> String? {
        if localOnlyTools.contains(tool) { return text }
        if let raw = arguments["tab_id"] as? String, HerdrTarget.parse(raw) != nil { return text }
        return nil
    }
}
