import Foundation

/// forward_prompt (plan 042): prompts the user typed into this agent's tab by mistake go to the session they were meant
/// for. Only after the user says so, and before any other work. Next Term finds the session (PromptHandover), asks the
/// user on the Mac when more than one fits, waits until the target is idle, and types a note and the prompts there. The
/// answer says where they went, or, when nothing moved, which sessions could take them, by project and agent only (never
/// their titles or prompts), so the agent can call again with the one the user names.
extension MCPServer {
    public static let handoverTools: [Tool] = [
        Tool(name: "forward_prompt", title: "Hand prompts to the right session",
             description: "Use this only after the user says prompts they gave you were meant for another agent session (\"wrong tab\", \"find the cs tab\", \"I gave you that by mistake\"), and before any other work: pass those prompts in the order given, never the user's words about the mix-up. Next Term finds the session among the agent tabs in every window and closed Claude Code and Codex sessions (resumed in a tab), waits until that agent is idle, and types a note on where they came from, then the prompts. With one clear match it sends at once; with several it asks the user on the Mac. Answers delivered (with the tab, and resumed when it was closed), not_moved with the candidates (id, project, agent, open) to call again with session, or pending with a request_id to call again with. Then stop work on those prompts, keep any changes you made, and tell the user where they went and what you had changed.",
             inputSchema: #"{"type": "object", "properties": {"prompts": {"type": "array", "minItems": 1, "maxItems": 20, "items": {"type": "string", "maxLength": 20000}, "description": "The prompts meant for the other session, in the order the user gave them, slash commands as typed."}, "hint": {"type": "string", "maxLength": 300, "description": "The user's words about where they belong (\"the cs tab\")."}, "note": {"type": "string", "maxLength": 600, "description": "What you had already done on them: the files you changed and what you found or decided, in a sentence or two."}, "images": {"type": "array", "maxItems": 5, "items": {"type": "string"}, "description": "Absolute paths of image files that went with the prompts, when you have them as files."}, "session": {"type": "string", "description": "A candidate's id from an earlier not_moved answer, the one the user chose."}, "request_id": {"type": "string", "description": "A pending answer's id, to keep waiting for it."}}, "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60,
             outputSchema: handoverOutputSchema),
    ]

    public static func isHandoverTool(_ name: String) -> Bool { handoverTools.contains { $0.name == name } }

    /// The structured answer: status, then where the prompts went or what could take them.
    static let handoverOutputSchema = #"{"type": "object", "properties": {"status": {"type": "string", "enum": ["delivered", "not_moved", "pending"]}, "tab_id": {"type": "string"}, "project": {"type": "string"}, "agent": {"type": "string"}, "resumed": {"type": "boolean"}, "candidates": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "project": {"type": "string"}, "agent": {"type": "string"}, "open": {"type": "boolean"}}, "required": ["id", "project", "agent", "open"]}}, "request_id": {"type": "string"}, "note": {"type": "string"}}, "required": ["status"]}"#

    /// The arguments forward_prompt takes; any other is refused.
    public static let handoverArguments: Set<String> = ["prompts", "hint", "note", "images", "session", "request_id"]
}
