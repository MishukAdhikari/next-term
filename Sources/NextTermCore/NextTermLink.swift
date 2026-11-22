import Foundation

/// `nextterm://` links, for launchers (Raycast, Alfred, the Shortcuts app's Open URLs, a Stream Deck): each one a quick
/// action that takes no typing in Next Term.
///
///     nextterm://open?path=/Users/me/Code/app   that folder as a project (as `nxtrm` opens it)
///     nextterm://tab?id=<tab id>                that tab in front, with the keyboard (list_tabs and `nxtrm call` give ids)
///     nextterm://attention                      the next tab whose agent waits for you
///     nextterm://goto                           Go to Anything, over the window in front
///     nextterm://agent?path=…&agent=claude      an agent in a new tab there, once the user says yes on the Mac
///
/// A web page can open a link too, so a link never runs anything unasked: starting an agent asks first, and the agent
/// is one of the known ones, never a command the link spells out. Paths are absolute or start with ~.
public enum NextTermLink: Equatable, Sendable {
    case open(path: String)
    case tab(id: String)
    case attention
    case goTo
    case agent(path: String, agent: String)

    public static let scheme = "nextterm"

    /// The agents a link may start, by the command that starts each.
    public static let agents: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini CLI", "cmd": "Command Code",
    ]

    /// The link's action, or why it can't be followed.
    public static func parse(_ url: URL, home: String = NSHomeDirectory()) -> Result<NextTermLink, Refusal> {
        guard url.scheme?.lowercased() == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(Refusal("That isn\u{2019}t a nextterm:// link."))
        }
        // nextterm://open?… names the action as the host; nextterm:open?… as the path.
        let action = (parts.host ?? parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        func folder() -> Result<String, Refusal> {
            guard let raw = value("path") else { return .failure(Refusal("The link names no folder (path=).")) }
            let path = raw == "~" ? home : raw.hasPrefix("~/") ? home + raw.dropFirst(1) : raw
            guard path.hasPrefix("/") else { return .failure(Refusal("The link\u{2019}s folder isn\u{2019}t a full path: \(raw)")) }
            return .success((path as NSString).standardizingPath)
        }
        switch action {
        case "open":
            return folder().map { .open(path: $0) }
        case "tab":
            guard let id = value("id"), UUID(uuidString: id) != nil else { return .failure(Refusal("The link names no tab (id=).")) }
            return .success(.tab(id: id.lowercased()))
        case "attention": return .success(.attention)
        case "goto", "go-to", "search": return .success(.goTo)
        case "agent":
            let agent = (value("agent") ?? "claude").lowercased()
            guard agents[agent] != nil else {
                return .failure(Refusal("A link can start \(agents.keys.sorted().joined(separator: ", ")); not \(agent)."))
            }
            return folder().map { .agent(path: $0, agent: agent) }
        default:
            return .failure(Refusal("Next Term has no \u{201C}\(action)\u{201D} link."))
        }
    }

    public struct Refusal: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }
}
