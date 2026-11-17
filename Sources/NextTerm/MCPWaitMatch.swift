import AppKit
import NextTermCore

/// wait_for_tab with `match` on a tab of this Mac (plan 040 U2): returns once the tab's screen shows the text (or the
/// regular expression, with regex: true), looked at every 250 ms, or at the wait's end with timed_out, as herdr's own
/// `pane wait-output` does for its panes.
enum MCPWaitMatch {
    /// The rows looked through: the screen and some of what scrolled off it.
    static let lines = 200

    static func wait(_ tab: TerminalTab, _ arguments: [String: Any], until deadline: TimeInterval, reply: @escaping MCPControl.Reply) {
        let pattern: String = arguments["match"] as? String ?? ""
        let regex: Bool = arguments["regex"] as? Bool ?? false
        if let refusal = ScreenMatch.refusal(pattern, regex: regex) { return reply(MCPControl.fail(refusal)) }
        look(tab, pattern: pattern, regex: regex, until: deadline, reply: reply)
    }

    private static func look(_ tab: TerminalTab, pattern: String, regex: Bool, until deadline: TimeInterval, reply: @escaping MCPControl.Reply) {
        let fields: [String: Any] = MCPControl.screenFields(tab, lines: lines)
        let screen: String = fields["screen"] as? String ?? ""
        let found: Bool = ScreenMatch.matches(screen, pattern: pattern, regex: regex)
        if found || tab.exited || TerminalTab.now >= deadline {
            var info: [String: Any] = fields
            info["id"] = tab.id.uuidString.lowercased()
            info["matched"] = found
            info["timed_out"] = !found && !tab.exited
            info["state"] = tab.status.state.rawValue
            return reply(MCPControl.ok(info))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { look(tab, pattern: pattern, regex: regex, until: deadline, reply: reply) }
    }
}
