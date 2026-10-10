import Foundation

// The agent tools for Import Settings and Shortcuts… (claudedocs/2026-10-10-importer-everything-plan, "MCP tools for
// agents"): an agent lists the apps found and previews an import with the same rows the window shows; only the
// user's Apply in Next Term's own window changes anything. Their own list, not controlTools, so the remote door's
// list of write tools stays as it is; local only; not always loaded (they are used once in a while).

extension MCPServer {
    private static let sourceArgument = #""source": {"type": "string", "description": "A source's id (or name) from list_import_sources."}"#
    private static let fileArguments = #""path": {"type": "string", "description": "Instead of source: a settings file in an open project, relative to it or absolute; read_file's rules apply."}, "format": {"type": "string", "enum": ["vscode-settings", "vscode-keybindings"], "description": "With path: what the file is (a VS Code settings.json or keybindings.json)."}, "project": {"type": "string", "description": "With a relative path: an open project's folder or name."}"#
    private static let importReason = #""reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words in the import window."}"#
    private static let requestArgument = #""request_id": {"type": "string", "description": "A pending request's id, to keep waiting for the user's answer."}"#

    /// The import tools (W1.11). list_import_sources and preview_import only read; apply_import and undo_import
    /// ask the user on the Mac, in the import window itself, and change nothing on an agent's say alone.
    public static let importTools: [Tool] = [
        Tool(name: "list_import_sources", title: "List apps to import settings from",
             description: "The editors and terminals on this Mac whose settings Next Term's Import Settings and Shortcuts… can bring over (VS Code and editors built on it, JetBrains IDEs, Zed, terminal apps and more): an id for each, its name, family (editors or terminals), version, whether the app is still installed, when it was last used, the shortcut set it suggests, what it can bring, and whether it was not used lately. Also the shortcut set in use, the last import with its undo_id, and the file formats preview_import reads. To find the apps, Next Term looks only at folders, dates and the apps' version files, plus which keymap a JetBrains IDE uses, where its idea.properties moves its settings, and whether Terminal's default profile was changed; nothing else in a settings file is read, and no setting's value is returned. Use this and preview_import instead of reading those apps' files yourself, which sit next to tokens, licence keys and account data. include_targets adds the Next Term settings and commands an import can set. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {"include_targets": {"type": "boolean", "description": "Also list Next Term's settings (with what each takes) and commands (with their keys now) that an import can set. Default false."}}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15, alwaysLoad: false),
        Tool(name: "preview_import", title: "Preview an import",
             description: "What importing from one source would change, as Import Settings and Shortcuts… shows it: the shortcut set, the user's own shortcuts (the key now and the new one), settings, recent projects, and what is not brought over with why (by name only). Each row has an id for apply_import and says whether it starts ticked. plan_id names this preview; changes_if_applied counts what the ticked rows change; up_to_date says nothing differs from Next Term now. Only allowlisted values are read, and values that can hold secrets are named, never read. Nothing changes. With path and format it reads a VS Code settings.json or keybindings.json in an open project instead; a file never sets hidden files, where new tabs open or recent projects, since an agent may have written it. Use this, not the apps' files. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {\#(sourceArgument), \#(fileArguments)}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 30, alwaysLoad: false),
        Tool(name: "apply_import", title: "Ask to import settings",
             description: "Asks the user to import from a source (or a file, as preview_import takes it). The user is asked on the Mac first, in Next Term's own import window: it opens with the rows you name ticked (items: row ids from preview_import; default, the preview's ticked rows) and the others unticked, under a banner naming you, with your reason. Only the user's Apply changes anything, and they may change the rows. Answers within about 50 seconds: applied (the rows applied, the ones the user ticked or unticked, and undo_id), declined, stopped (the user chose Decline and Stop Asking), busy (another request, or the user's own import window, is open), up_to_date (nothing would change; no window opens), changed_since_preview (plan_id no longer matches; preview again), or pending with a request_id: call again with only request_id to keep waiting. The window closes as a decline after 10 minutes. A request the user declined answers declined at once until Next Term quits. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {\#(sourceArgument), \#(fileArguments), "items": {"type": "array", "items": {"type": "string"}, "maxItems": 300, "description": "Row ids from preview_import to tick: preset, set:<setting>, key:<command>, recents. Default: the rows the preview ticks."}, "plan_id": {"type": "string", "description": "preview_import's plan_id: refused if the plan changed since."}, \#(importReason), \#(requestArgument)}, "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60, alwaysLoad: false),
        Tool(name: "undo_import", title: "Ask to undo the last import",
             description: "Asks the user to undo the last import, as Settings › Import › Undo Import does: the shortcuts, settings and recent projects it changed go back to what they were, including any the user changed by hand since (the ask names them). The user is asked on the Mac first. undo_id must be the last import's (list_import_sources gives it); an older one answers stale_undo_id. Answers within about 50 seconds: undone (with what was put back), nothing_to_undo, stale_undo_id, declined, stopped, busy, or pending with a request_id: call again with only request_id to keep waiting. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {"undo_id": {"type": "string", "description": "The last import's undo_id, from list_import_sources or apply_import."}, \#(importReason), \#(requestArgument)}, "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60, alwaysLoad: false),
    ]

    public static func isImportTool(_ name: String) -> Bool { importTools.contains { $0.name == name } }
}
