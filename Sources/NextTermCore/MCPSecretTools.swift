import Foundation

/// Secrets' four MCP tools: names in, status out. No tool returns a stored key's value, and there is no tool
/// that gets one. They are never in `controlTools`; `MCPServer.tools` ends `controlTools + secretTools`. The app's
/// `SecretsMCP` runs them, and checks every argument itself: the three tools that ask have no `required` array, since
/// a poll sends only `request_id`.
extension MCPServer {
    /// The pattern of a key's name: capital letters, digits and `_`, starting with a letter, at most 64 characters.
    static let secretNamePattern = "^[A-Z][A-Z0-9_]{0,63}$"
    /// A key, or a key given as another variable: `NAME` or `NAME=ENVNAME`.
    static let secretPairPattern = "^[A-Z][A-Z0-9_]{0,63}(=[A-Z][A-Z0-9_]{0,63})?$"

    private static let secretReason = #""reason": {"type": "string", "description": "Why, in a sentence; shown to the user on the Mac as your words."}"#
    private static let secretRequestID = #""request_id": {"type": "string", "description": "A pending request's id, to ask for its status again. It never returns a value."}"#
    private static let secretName = #""name": {"type": "string", "pattern": "\#(secretNamePattern)", "description": "The key's name: capital letters, digits and _, starting with a letter."}"#

    public static let secretTools: [Tool] = [
        Tool(name: "list_secrets", title: "List stored keys",
             description: "The user's keys stored in Next Term's Secrets, by name: what each is for (and whether the user or an agent wrote that), whether the user or an agent added it, whether it is write-only, when it was last used, service (the provider whose key page the user linked it to, such as OpenAI; never the link itself), rotated (the day its value was last set, YYYY-MM-DD) and rotate_due (whether the rotation reminder the user set for it has passed). vault is ok, none (nothing stored yet), cant_open or tampered. No tool returns a key's value: use run_with_secrets, or nxtrm secret run in an MCP server's config.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "request_secret", title: "Ask the user to add a key",
             description: "Asks the user to type or paste a key into Next Term, in a window on the Mac that shows your reason as your words. You get back only the status and the name: saved (with replaced), declined, or pending with a request_id to ask again with; never the value. Then use the key by name with run_with_secrets.",
             inputSchema: #"{"type": "object", "properties": {\#(secretName), \#(secretReason), \#(secretRequestID)}, "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60),
        Tool(name: "store_secret", title: "Save a key you hold",
             description: "Saves a key you already hold, such as one you just created, in Next Term's Secrets, once the user allows it on the Mac with Touch ID or their password. The value is already in your conversation; Next Term masks it in what agents read through it from then on. Replacing a key the user added says so to them. You get back saved (with replaced), declined, or pending with a request_id.",
             inputSchema: #"{"type": "object", "properties": {\#(secretName), "value": {"type": "string", "maxLength": 16384, "description": "The key's value, on one line."}, \#(secretReason), \#(secretRequestID)}, "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60),
        Tool(name: "run_with_secrets", title: "Run a command with stored keys",
             description: "Runs a shell command in a Next Term tab with stored keys in that command's environment, never the tab's shell's, after the user approves on the Mac with Touch ID or their password. While the command runs, any program running as the user can read that environment, so the keys are not hidden from other programs then. A new tab opens in directory, in the window of the project that holds it (opening the project if needed): its window comes forward (Settings: agents_bring_tabs_forward), but in the window the user works in it opens behind their tab, and it never takes the user's keyboard until they click it. Or give tab_id of a tab at its shell's prompt to run there with that tab's environment. Give each key as NAME, or NAME=ENVNAME to set it as another variable. A command holding a stored key's value is refused: use its name. Answers within about 50 seconds: started with the tab's id (read its screen with read_tab; stored keys are masked there), declined, or pending with a request_id to ask again with. For a new tab the answer also has selected (whether it was the selected tab in its window when it opened), and a note when its window did not come forward. No value is ever returned.",
             inputSchema: #"{"type": "object", "properties": {"secrets": {"type": "array", "minItems": 1, "maxItems": 20, "items": {"type": "string", "pattern": "\#(secretPairPattern)"}, "description": "The keys, as NAME or NAME=ENVNAME."}, "command": {"type": "string", "maxLength": 2000, "description": "One line, run with /bin/sh -c."}, "directory": {"type": "string", "description": "The absolute folder it runs in."}, "tab_id": {"type": "string", "description": "A local tab's id from list_tabs, at its shell's prompt and not your own: the command runs there. Default: a new tab."}, \#(secretReason), \#(secretRequestID)}, "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60),
    ]

    /// What `list_secrets` says of a key's page and age, beside its name: `service`, the provider whose key page its
    /// "Where it came from" link is on (null when it has none, or one on a host no key page has); `rotated`, the day
    /// its value was last set; `rotate_due`, whether its rotation reminder has passed. Never the link: a full URL can
    /// carry an organization's or a project's id, and only the user's hands set or open one.
    public static func secretSourceFacts(_ entry: SecretVault.Entry, now: Date,
                                         calendar: Calendar = .current) -> [String: Any] {
        let service: Any = secretService(ofLink: entry.link) ?? NSNull()
        return [
            "service": service,
            "rotated": SecretAge.day(entry.lastSet, calendar: calendar),
            "rotate_due": SecretAge.due(entry: entry, now: now, calendar: calendar),
        ]
    }

    /// The provider a stored link's host belongs to (`SecretKeyPages.page(forHost:)`), for a link that still passes
    /// the link rules; nil for none. The index is read with no MAC check, as lists read it, so the rules run again here.
    public static func secretService(ofLink link: String?) -> String? {
        guard let link else { return nil }
        let none: (String) -> Bool = { (_: String) -> Bool in false }
        guard case .success(let url) = SecretLink.check(link, mask: none, value: nil),
              let host = SecretLink.host(of: url) else { return nil }
        return SecretKeyPages.page(forHost: host)?.provider
    }

    /// An answer of run_with_secrets for a tab it opened, as new_tab answers: `selected`, whether the tab was the
    /// selected one in its window when it opened (the user may have chosen it, or closed it, since; the answer comes
    /// with the decision, up to 50 seconds later or on a later `request_id` call), and the arrival's note after the
    /// answer's own.
    public static func withArrival(_ answer: [String: Any], selected: Bool, note: String?) -> [String: Any] {
        var answer = answer
        answer["selected"] = selected
        if let note {
            answer["note"] = (answer["note"] as? String).map { "\($0) \(note)" } ?? note
        }
        return answer
    }
}
