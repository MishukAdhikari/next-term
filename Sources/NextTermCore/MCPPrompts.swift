import Foundation

// The MCP prompts (claudedocs/research_first-run-setup_2026-11-02, R2): one, setup, which Claude Code lists as the slash
// command /mcp__next-term__setup. Its text is the one a user can paste into any agent, so an agent with no prompts
// support gets the same steps. Answering prompts/list and prompts/get never needs the app, as tools/list doesn't.

extension MCPServer {
    public struct Prompt: Sendable {
        public let name: String
        public let title: String
        public let description: String
        /// The user message prompts/get returns.
        public let text: String
    }

    /// Setting Next Term up from an agent: reach it, read next-term-setup, look at what the user had before, show one plan,
    /// apply it in one approval on the Mac, and end with how to undo it and three keys.
    public static let setupPrompt = """
        Set up Next Term for me using its MCP tools.
        1. Call `list_tabs` to check you can reach Next Term. If you have no Next Term tools, tell me and ask me to restart you.
        2. Read the `next-term-setup` skill with `get_skill` and follow its first-run steps.
        3. Look at what I used before with `list_import_sources` and `preview_import`, and read my current settings with `settings_get`.
        4. Show me one plan as a table: what you would import, the shortcut set, the layout, and notifications. Note anything that will not carry over.
        5. Apply it with `apply_setup` in one approval on my Mac, then tell me how to undo it.
        6. Finish with three shortcuts from `list_shortcuts` for what I will do most.
        Change nothing until I approve on the Mac, never open another agent’s MCP config files, and never print a key.
        """

    public static let prompts: [Prompt] = [
        Prompt(name: "setup", title: "Set up Next Term",
               description: "Set Next Term up the way you work: bring over what you used before, choose the shortcut set, layout and notifications, and apply it all in one approval on your Mac.",
               text: setupPrompt),
    ]

    public static func prompt(named name: String) -> Prompt? { prompts.first { $0.name == name } }

    /// prompts/list's entries. No prompt takes arguments.
    static func promptListing() -> [[String: Any]] {
        prompts.map { ["name": $0.name, "title": $0.title, "description": $0.description, "arguments": [Any]()] }
    }

    /// prompts/get's result for a prompt: its description and its text as the user's message.
    static func promptMessages(_ prompt: Prompt) -> [String: Any] {
        ["description": prompt.description,
         "messages": [["role": "user", "content": ["type": "text", "text": prompt.text]]]]
    }
}
