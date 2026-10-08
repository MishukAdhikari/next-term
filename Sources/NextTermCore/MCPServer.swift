import Foundation

/// Next Term's MCP server, as AI agents see it: `nxtrm mcp`, a stdio server that hands each tool call to
/// the running app over a Unix socket. It is for orchestration: an agent (Claude, Codex, Gemini…) can see
/// every project and tab with its agent's status, start agents in new tabs, give them prompts, wait for
/// them and read their screens, and use the editor. The tool list is fixed: answering `initialize` and
/// `tools/list` never needs the app (some clients cache the list, and must see the same one every time).
public enum MCPServer {
    public static let name = "next-term"
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Set in Next Term's tabs to the running app's socket. Agents that clear the environment (Codex)
    /// fall back to the default path, which is the same unless this is a test run.
    public static let socketVariable = "NEXTTERM_MCP_SOCKET"

    /// The app's socket. From the home folder, not TMPDIR: some agents start servers without TMPDIR.
    public static func socketPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/Next Term/mcp.sock")
    }

    public static let instructions = """
        Next Term is the terminal and editor this agent may be running in. Use these tools to orchestrate \
        work across projects: list_tabs shows every open project and tab with the state of the agent in it \
        (working, done, needs attention). Start an agent with new_tab (directory plus a command such as \
        "claude" or "codex"), give it a task with send_to_tab, then wait_for_tab until it stops and \
        read_tab to see what it said. An agent that needs a decision shows state "attention", the \
        question, its choices and a question_id; answer it with answer_agent (tab_id, question_id and the \
        choice), which refuses if the question has changed since. Never type into your own tab ("you": true). \
        read_file, find_in_files, git_status and get_diff read an open project's files and changes (what \
        an agent did). get_editor_selection returns what the user has selected in the editor. Servers (VPSes) the user \
        connected are in list_hosts: new_remote_tab opens a tab on one (then use it like any tab), \
        host_sessions lists the sessions kept there, host_changes shows what changed in a git work tree there. \
        list_skills shows the user's agent skills and which agent loads each; install_skill and remove_skill \
        ask the user, who reviews and decides in Next Term (nothing changes on your say alone). \
        propose_edit shows a file edit in the editor's diff for the user to accept; write_file, create_file, \
        stage, commit, focus_tab, split_pane, close_pane, zoom_pane, set_layout and settings_set ask the user \
        on the Mac first, and change nothing when declined or unanswered.
        """

    // MARK: tools

    public struct Tool: Sendable {
        public let name: String
        public let title: String
        public let description: String
        /// JSON Schema for the arguments, as JSON text.
        public let inputSchema: String
        public let readOnly: Bool
        /// Can run commands or stop work (typing into a terminal, closing a tab).
        public let destructive: Bool
        public let idempotent: Bool
        /// Longest a call can take, for the bridge's wait (wait_for_tab sets its own).
        public let timeout: TimeInterval
        /// Reaches another machine (a server over ssh), not only this Mac.
        public var openWorld = false
    }

    private static let tabID = #""tab_id": {"type": "string", "description": "A tab's id from list_tabs."}"#
    private static let projectRef = #""project": {"type": "string", "description": "An open project's folder (as list_projects gives it) or its name. Default: your window's project, or the only one open."}"#
    private static let hostRef = #""host": {"type": "string", "description": "A host's id or name from list_hosts."}"#
    private static let keepSchema = #""keep": {"type": "string", "enum": ["off", "tmux", "herdr"], "description": "How agents are kept running on the host: off (a plain ssh shell; what runs stops when the connection drops), tmux (sessions keep running on the host while this Mac is away; needs tmux there), herdr (the user's own herdr on the host). Next Term installs neither."}"#

    public static let tools: [Tool] = [
        Tool(name: "list_tabs", title: "List projects and tabs",
             description: "Every Next Term window (one per project) and its terminal tabs: id, title, folder, the program running, and its state: idle, working (an agent is busy), done, failed, or attention (an agent waits for a decision; the question, its choices and a question_id for answer_agent are included). Remote tabs also have their host, and can be connecting (ssh is logging in; login_prompt: the user must answer ssh in that tab) or disconnected. A local agent tab has the checkout its agent works in, its branch (or detached_at), and sync: same (the window shows that checkout), elsewhere (another checkout of the window's repository), switched_under (its branch was switched under the chat: chat_branch, switched_by) or other_repository. The tab you run in has \"you\": true.",
             inputSchema: #"{"type": "object", "properties": {"project": {"type": "string", "description": "Only the window of this project folder."}}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "read_tab", title: "Read a tab's screen",
             description: "The text at the end of a tab's terminal (what the agent or command printed last), and the tab's state.",
             inputSchema: #"{"type": "object", "properties": {\#(tabID), "lines": {"type": "integer", "minimum": 1, "maximum": 2000, "description": "How many lines from the end. Default 80."}}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "wait_for_tab", title: "Wait for a tab",
             description: "Waits until the tab's agent stops working (done, or waiting for input or a decision), or until its command finishes, then returns the state and the last lines of the screen. Returns early with \"timed_out\": true; call again to keep waiting.",
             inputSchema: #"{"type": "object", "properties": {\#(tabID), "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 300, "description": "Default 50 (some clients give up on a tool after 60 seconds); call again to keep waiting."}}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 300),
        Tool(name: "list_projects", title: "List projects",
             description: "Projects open in Next Term and recently opened ones (folder paths).",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "get_editor_selection", title: "Get the editor selection",
             description: "The file open in front in the editor of your window (or the front window), with the selected text and its line range (1-based). Unsaved edits are included.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "get_open_files", title: "Get open files",
             description: "Files open in the editor, per window, with which one is in front and which have unsaved changes. A file marked preview was opened by a single click in the project sidebar, and the next file clicked there takes its place.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "read_file", title: "Read a file in a project",
             description: "Reads a text file in a project open in Next Term, as saved on disk. path is relative to the project, or absolute inside an open project; a symlink is followed only if it stays inside. Returns up to limit lines from offset (1-based) and total_lines; next_offset reads on. Binary files, files over 5 MB, and files that usually hold secrets (.env files, keys and certificates such as *.pem and *.key, ssh keys, credentials files, git's own folder) are refused with the reason. Values that look like tokens or passwords are replaced by •••.",
             inputSchema: #"{"type": "object", "properties": {"path": {"type": "string", "description": "The file: relative to the project, or absolute."}, \#(projectRef), "offset": {"type": "integer", "minimum": 1, "description": "First line to return (1-based). Default 1."}, "limit": {"type": "integer", "minimum": 1, "maximum": 2000, "description": "How many lines. Default 400."}}, "required": ["path"], "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "find_in_files", title: "Find in a project's files",
             description: "Searches an open project's files the way Find in Files does: the files git tracks plus untracked ones it does not ignore (outside git, every file except dependency and build folders), skipping binaries, files over 5 MB and files that usually hold secrets. Returns each match's path, line and column (1-based) and the line's text, sorted by path, up to max_results, with the total found. Values that look like tokens or passwords are replaced by •••.",
             inputSchema: #"{"type": "object", "properties": {"query": {"type": "string", "description": "The text to find, or a regular expression with regex: true."}, \#(projectRef), "regex": {"type": "boolean", "description": "query is a regular expression (ICU syntax). Default false."}, "case_sensitive": {"type": "boolean", "description": "Default false."}, "whole_word": {"type": "boolean", "description": "Default false."}, "glob": {"type": "string", "description": "File masks, comma-separated: \"*.ts\", \"src/**/*.swift\", and \"!*.min.js\" to leave files out."}, "max_results": {"type": "integer", "minimum": 1, "maximum": 200, "description": "Default 50."}}, "required": ["query"], "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 60),
        Tool(name: "git_status", title: "Git status of a project",
             description: "An open project's git state: the branch, its upstream with commits ahead and behind, and each changed file with its state (modified, added, deleted, renamed, untracked, conflicted), whether it has staged and unstaged changes, and the lines added and removed. Reading it never takes git's index lock.",
             inputSchema: #"{"type": "object", "properties": {\#(projectRef)}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 30),
        Tool(name: "get_diff", title: "Diff of a project's changes",
             description: "The changes to a file in an open project as a unified diff: against HEAD (staged and unstaged together, the default), only what is staged, or only what is not. Without path, every changed file in the project. Cut at max_chars. Files that usually hold secrets are left out (the answer says which), and values that look like tokens or passwords are replaced by •••. Reading it never takes git's index lock.",
             inputSchema: #"{"type": "object", "properties": {"path": {"type": "string", "description": "The file: relative to the project, or absolute. Default: every changed file."}, \#(projectRef), "which": {"type": "string", "enum": ["head", "staged", "unstaged"], "description": "head: all changes against the last commit (default); staged: what the next commit holds; unstaged: what is not staged yet."}, "context": {"type": "integer", "minimum": 0, "maximum": 20, "description": "Unchanged lines around each change. Default 3."}, "max_chars": {"type": "integer", "minimum": 1000, "maximum": 200000, "description": "Longest diff to return. Default 60000."}}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 30),
        Tool(name: "open_project", title: "Open a project",
             description: "Opens a folder as a project in its own window (or brings it to the front if open) and returns its tabs.",
             inputSchema: #"{"type": "object", "properties": {"path": {"type": "string", "description": "Absolute folder path."}}, "required": ["path"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 30),
        Tool(name: "new_tab", title: "New tab",
             description: "Opens a terminal tab in a folder (in the window of the project that holds it, opening the project if needed), or a pane split beside another tab, and optionally runs a command in it, such as an agent (\"claude\", \"codex\", \"gemini\"). Returns the tab's id.",
             inputSchema: #"{"type": "object", "properties": {"directory": {"type": "string", "description": "Absolute folder path."}, "command": {"type": "string", "description": "Typed at the prompt and run."}, "title": {"type": "string", "description": "Tab title."}, "split_beside": {"type": "string", "description": "A tab id: open as a pane split beside that tab instead of a new tab."}, "direction": {"type": "string", "enum": ["right", "down"], "description": "With split_beside. Default right."}}, "required": ["directory"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 30),
        Tool(name: "send_to_tab", title: "Type into a tab",
             description: "Types text into a tab, as if pasted, and presses Return unless submit is false: a prompt for the agent in that tab, an answer to its question, or a shell command.",
             inputSchema: #"{"type": "object", "properties": {\#(tabID), "text": {"type": "string"}, "submit": {"type": "boolean", "description": "Press Return after the text. Default true."}}, "required": ["tab_id", "text"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 15),
        Tool(name: "press_keys", title: "Press keys in a tab",
             description: "Presses keys in a tab, in order: enter, escape, tab, shift+tab, up, down, left, right, backspace, space, ctrl+c, ctrl+d, or a single character such as \"1\" or \"y\". For menus and confirmations in an agent's screen.",
             inputSchema: #"{"type": "object", "properties": {\#(tabID), "keys": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 20}}, "required": ["tab_id", "keys"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 15),
        Tool(name: "answer_agent", title: "Answer an agent's question",
             description: "Answers the question an agent in a tab is asking (state \"attention\"): picks one of its choices the way the agent's screen takes it (the arrow keys to the choice, then Return; y or n and Return for a y/n prompt). Give the question_id that came with the question from list_tabs, read_tab or wait_for_tab: if the tab has moved on to another question, or asks nothing, nothing is typed and the answer says what it shows now. Returns the choice picked and the tab's state after.",
             inputSchema: #"{"type": "object", "properties": {\#(tabID), "question_id": {"type": "string", "description": "The question_id that came with the question."}, "choice": {"type": "integer", "minimum": 1, "description": "The choice's number in choices (1 is the first)."}, "answer": {"type": "string", "description": "Instead of choice: the choice's words, such as \"Yes\" (or y or n for a y/n prompt)."}}, "required": ["tab_id", "question_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 15),
        Tool(name: "show_tab", title: "Show a tab",
             description: "Brings a tab and its window to the front, for the user to see.",
             inputSchema: #"{"type": "object", "properties": {\#(tabID)}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "close_tab", title: "Close a tab",
             description: "Closes a tab. A tab with something running is refused unless force is true, which stops it. A remote tab kept by tmux only detaches: what runs there keeps running on the host (the answer says so; new_remote_tab with session reattaches), and force ends that tmux session (the tab closes only once it has ended). A herdr tab only detaches; herdr keeps its agents. The last tab in a window whose editor has unsaved files would close the window, so the user is asked to save them first: the answer has closed false and asking_user (and session_ended when force has ended a tmux session already).",
             inputSchema: #"{"type": "object", "properties": {\#(tabID), "force": {"type": "boolean"}}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 15),
        Tool(name: "list_hosts", title: "List remote hosts",
             description: "Servers the user connects to from Next Term (Connect VPS): id, name, ssh destination, port, default folder, and how agents are kept there (keep: off, tmux or herdr). Remote tabs are in list_tabs with their host.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "add_host", title: "Add or update a remote host",
             description: "Saves a server to connect to with the system ssh, which uses the user's keys, ssh agent and ~/.ssh/config; Next Term stores no password. destination is user@host or a Host alias from ~/.ssh/config. For a host already saved under that name, only directory and keep change: destination and port must be the saved ones, and pointing it at another server takes remove_host, then add_host. Nothing is installed or run on the host.",
             inputSchema: #"{"type": "object", "properties": {"name": {"type": "string", "description": "Short name, such as web-1."}, "destination": {"type": "string", "description": "user@host, host, or an alias from ~/.ssh/config."}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "directory": {"type": "string", "description": "Default folder on the host: absolute, or starting with ~. Default ~."}, \#(keepSchema)}, "required": ["name", "destination"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 15),
        Tool(name: "remove_host", title: "Remove a remote host",
             description: "Forgets a saved host. Sessions kept on it (tmux, herdr) keep running there.",
             inputSchema: #"{"type": "object", "properties": {\#(hostRef)}, "required": ["host"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 15),
        Tool(name: "check_host", title: "Check a remote host",
             description: "Reports what a host has: OS, login shell, tmux and herdr versions, git, the agents on PATH (claude, codex, gemini), and Next Term's kept tmux sessions. It runs over the open connection of a remote tab on that host and never logs in by itself: with no tab connected there, open one (new_remote_tab) and let the user answer ssh in it.",
             inputSchema: #"{"type": "object", "properties": {\#(hostRef)}, "required": ["host"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 30, openWorld: true),
        Tool(name: "new_remote_tab", title: "New tab on a remote host",
             description: "Opens a terminal tab on a host, in a folder there (default: the host's folder), kept the host's way unless keep is given, and optionally runs a command in it such as an agent (\"claude\", \"codex\"). session attaches to one of Next Term's tmux sessions on the host (from host_sessions), such as one started on another Mac. If ssh needs a password or a host key confirmation, the tab shows ssh's own prompt to the user and the command waits. Returns the tab's id: use send_to_tab, read_tab and wait_for_tab with it like any tab.",
             inputSchema: #"{"type": "object", "properties": {\#(hostRef), "directory": {"type": "string", "description": "Folder on the host: absolute, or starting with ~."}, "command": {"type": "string", "description": "Typed at the prompt and run once the tab's shell is ready."}, "title": {"type": "string"}, \#(keepSchema), "session": {"type": "string", "description": "A tmux session name from host_sessions, to attach to it."}}, "required": ["host"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60, openWorld: true),
        Tool(name: "host_sessions", title: "Sessions kept on a host",
             description: "What keeps running on a host while no Mac is connected: Next Term's tmux sessions (name, folder, program in front, how many clients are attached) and, if the user runs herdr there, herdr's agents with their state (idle, working, blocked, done). Connects like check_host.",
             inputSchema: #"{"type": "object", "properties": {\#(hostRef)}, "required": ["host"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 30, openWorld: true),
        Tool(name: "host_changes", title: "Changes in a work tree on a host",
             description: "What changed in a git work tree on a host (what its agents did): the branch, the changed files (git status; untracked files are listed), a diffstat, and the diff against HEAD, cut at max_bytes. It never takes git's index lock. Connects like check_host.",
             inputSchema: #"{"type": "object", "properties": {\#(hostRef), "directory": {"type": "string", "description": "Folder on the host. Default: the host's folder."}, "diff": {"type": "boolean", "description": "Include the diff. Default true."}, "max_bytes": {"type": "integer", "minimum": 1000, "maximum": 2000000, "description": "Longest diff to return. Default 200000."}}, "required": ["host"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 60, openWorld: true),
        Tool(name: "list_skills", title: "List agent skills",
             description: "Lists the user's personal agent skills (~/.agents/skills, ~/.claude/skills, ~/.codex/skills, ~/.commandcode/skills): each skill's name and description, what Claude Code, Codex and Command Code each do with it (loads, off, skipped, none), where it came from when known, and whether an update was found.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "install_skill", title: "Ask to install a skill",
             description: "Asks the user to install an agent skill from a public GitHub repository. Nothing is fetched or written on this request alone: the user sees it in Next Term, chooses to review the skill's files, and decides. Answers within about 50 seconds: installed (with the names), declined, failed (with a note saying why), busy (another request is waiting; ask later), or pending with a request_id: call again with only request_id to keep waiting. A source the user declined stays declined until Next Term quits.",
             inputSchema: #"{"type": "object", "properties": {"source": {"type": "string", "description": "owner/repo, owner/repo/path/to/skill, or a github.com link to a repository, folder or SKILL.md."}, "reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words."}, "request_id": {"type": "string", "description": "A pending request's id, to keep waiting for the user's answer."}}, "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60, openWorld: true),
        Tool(name: "remove_skill", title: "Ask to remove a skill",
             description: "Asks the user to remove an installed skill (its copy in ~/.agents/skills and its Claude Code link); the user sees what goes and decides, and can undo it. Answers like install_skill: removed, declined, busy, or pending with a request_id to call again with.",
             inputSchema: #"{"type": "object", "properties": {"name": {"type": "string", "description": "The skill's name, as list_skills gives it."}, "reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words."}, "request_id": {"type": "string", "description": "A pending request's id, to keep waiting for the user's answer."}}, "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60),
        Tool(name: "open_in_editor", title: "Open in the editor",
             description: "Opens a file in Next Term's editor, at a line and column if given (1-based).",
             inputSchema: #"{"type": "object", "properties": {"path": {"type": "string", "description": "Absolute file path."}, "line": {"type": "integer", "minimum": 1}, "column": {"type": "integer", "minimum": 1}}, "required": ["path"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 15),
    ] + controlTools

    public static func tool(named name: String) -> Tool? { tools.first { $0.name == name } }

    static func listing() -> [[String: Any]] {
        tools.map { tool in
            [
                "name": tool.name,
                "title": tool.title,
                "description": tool.description,
                "inputSchema": (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? ["type": "object"],
                "annotations": [
                    "title": tool.title,
                    "readOnlyHint": tool.readOnly,
                    "destructiveHint": tool.destructive,
                    "idempotentHint": tool.idempotent,
                    "openWorldHint": tool.openWorld,
                ],
                // Claude Code defers MCP tools behind its tool search; these are few and worth having at hand.
                "_meta": tool.meta,
            ]
        }
    }

    // MARK: JSON-RPC over stdio

    /// What a tool call returns: text for the model, and whether it is an error.
    public struct CallResult: Sendable {
        public var text: String
        public var isError: Bool
        public init(text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    /// Answers one JSON-RPC message (nil for notifications). `call` runs a tool; it may block.
    public static func respond(to message: [String: Any], version: String,
                               call: (_ name: String, _ arguments: [String: Any]) -> CallResult) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil } // a response to us: none expected
        guard let id = message["id"], !(id is NSNull) else { return nil } // a notification
        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return result([
                "protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "title": "Next Term", "version": version],
                "instructions": instructions,
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": listing()])
        case "tools/call":
            guard let name = params["name"] as? String, tool(named: name) != nil else {
                return error(-32602, "Unknown tool: \(params["name"] as? String ?? "")")
            }
            let outcome = call(name, params["arguments"] as? [String: Any] ?? [:])
            return result(["content": [["type": "text", "text": outcome.text]], "isError": outcome.isError])
        case "resources/list":
            return result(["resources": [Any]()])
        case "prompts/list":
            return result(["prompts": [Any]()])
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    // MARK: the app socket

    /// One request to the app: a line of JSON. The answer is one line too.
    public static func request(tool: String, arguments: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(arguments),
              var data = try? JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments]) else { return nil }
        data.append(0x0A)
        return data
    }

    public static func decodeAnswer(_ line: Data) -> CallResult? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        return CallResult(text: text, isError: object["isError"] as? Bool ?? false)
    }

    public static func encodeAnswer(_ result: CallResult) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: ["text": result.text, "isError": result.isError])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Model-facing JSON: keys sorted, slashes as they are.
    public static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: keys

    /// The bytes a key name sends to a terminal (nil: not a key we know).
    public static func keyBytes(_ name: String) -> String? {
        switch name.lowercased() {
        case "enter", "return": return "\r"
        case "escape", "esc": return "\u{1b}"
        case "tab": return "\t"
        case "shift+tab", "backtab": return "\u{1b}[Z"
        case "up": return "\u{1b}[A"
        case "down": return "\u{1b}[B"
        case "right": return "\u{1b}[C"
        case "left": return "\u{1b}[D"
        case "backspace": return "\u{7f}"
        case "space": return " "
        case "ctrl+c": return "\u{03}"
        case "ctrl+d": return "\u{04}"
        default:
            // One printable character.
            guard name.count == 1, let scalar = name.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7f else { return nil }
            return name
        }
    }
}
