import Foundation

/// GitHub Copilot CLI's editor protocol, the one VS Code's Copilot extension serves (MIT, in
/// microsoft/vscode): the CLI finds editors through lock files in `~/.copilot/ide/`, connects to the Unix
/// socket a lock names with the lock's `Authorization` header, and speaks MCP over Streamable HTTP there.
/// The editor pushes `selection_changed` (and `add_file_reference` / `add_selection` to put an @-mention
/// into the prompt); the CLI calls `open_diff`, which waits until you accept or reject, and `close_diff`.
/// The server is CopilotIDEServer; this is the part that needs no socket.
public enum CopilotIDE {
    /// `$COPILOT_HOME/ide`, else `~/.copilot/ide` (where the CLI looks).
    public static func lockFolder(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = environment["COPILOT_HOME"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("ide", isDirectory: true)
        }
        return home.appendingPathComponent(".copilot/ide", isDirectory: true)
    }

    /// The header the CLI sends back on every request.
    public static func authorization(nonce: String) -> String { "Nonce " + nonce }

    /// The lock file. `isTrusted` is false: Copilot skips its own "do you trust this folder?" question for
    /// a folder an editor calls trusted, and Next Term has no say in that. Copilot connects either way.
    public static func lock(socketPath: String, nonce: String, pid: Int32, workspaces: [String], timestamp: Int) -> [String: Any] {
        ["socketPath": socketPath, "scheme": "unix", "headers": ["Authorization": authorization(nonce: nonce)],
         "pid": Int(pid), "ideName": "Next Term", "timestamp": timestamp, "workspaceFolders": workspaces, "isTrusted": false]
    }

    /// The request carries this launch's nonce (compared in constant time).
    public static func isAuthorized(_ header: String?, nonce: String) -> Bool {
        guard let header else { return false }
        return IDELink.constantTimeEqual(header, authorization(nonce: nonce))
    }

    // MARK: tools

    private static func schema(_ required: [String], _ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "required": required, "properties": properties]
    }

    /// The six tools the protocol defines, by the names the CLI calls.
    public static let tools: [[String: Any]] = [
        ["name": "get_vscode_info", "description": "Get information about the editor", "inputSchema": schema([], [:])],
        ["name": "get_selection", "description": "Get the selected text in the editor, or the file the caret is in",
         "inputSchema": schema([], [:])],
        ["name": "get_diagnostics", "description": "Get the editor's diagnostics (Next Term has none)",
         "inputSchema": schema([], ["uri": ["type": "string"]])],
        ["name": "open_diff", "description": "Show a proposed change to a file and wait for the user to accept or reject it",
         "inputSchema": schema(["original_file_path", "new_file_contents", "tab_name"],
                               ["original_file_path": ["type": "string"], "new_file_contents": ["type": "string"],
                                "tab_name": ["type": "string"]])],
        ["name": "close_diff", "description": "Close a proposed change, by its tab name",
         "inputSchema": schema(["tab_name"], ["tab_name": ["type": "string"]])],
        ["name": "update_session_name", "description": "Name the CLI's session",
         "inputSchema": schema(["name"], ["name": ["type": "string"]])],
    ]

    /// A tool's answer: the value as JSON text, the way the CLI reads it.
    public static func textResult(_ value: Any) -> [String: Any] {
        let text: String
        if value is NSNull {
            text = "null"
        } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .prettyPrinted]),
                  let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = "\(value)"
        }
        return ["content": [["type": "text", "text": text]]]
    }

    public static func errorResult(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    public struct DiffRequest: Equatable, Sendable {
        public let path: String
        public let proposed: String
        public let tabName: String
    }

    /// open_diff's arguments. The path must be absolute (the CLI sends absolute paths).
    public static func diffRequest(_ arguments: [String: Any]) -> DiffRequest? {
        guard let path = arguments["original_file_path"] as? String, path.hasPrefix("/"),
              let proposed = arguments["new_file_contents"] as? String,
              let tab = arguments["tab_name"] as? String, !tab.isEmpty else { return nil }
        return DiffRequest(path: path, proposed: proposed, tabName: tab)
    }

    /// open_diff's answer once you decide. SAVED: the CLI writes its proposed text; REJECTED: it does not.
    public static func diffResult(accepted: Bool, tabName: String, path: String, trigger: String? = nil) -> [String: Any] {
        let result: [String: Any] = [
            "success": true,
            "result": accepted ? "SAVED" : "REJECTED",
            "trigger": trigger ?? (accepted ? "accepted_via_button" : "rejected_via_button"),
            "tab_name": tabName,
            "message": (accepted ? "User accepted changes for " : "User rejected changes for ") + path,
        ]
        return textResult(result)
    }

    /// close_diff's answer: the CLI closes a proposal you answered in the terminal.
    public static func closeDiffResult(tabName: String, wasOpen: Bool) -> [String: Any] {
        let message = wasOpen ? "Diff \"\(tabName)\" closed" : "No active diff found with tab name \"\(tabName)\" (may already be closed)"
        return textResult(["success": true, "already_closed": !wasOpen, "tab_name": tabName, "message": message])
    }

    // MARK: what the editor sends

    /// selection_changed for Copilot: the same shape as Claude's (`text`, `filePath`, `fileUrl`, `selection`
    /// 0-based), and only for a file that may be shared. Nil when no file is in front or it holds secrets:
    /// then nothing is sent, and Copilot keeps the last file it was told about, as with VS Code.
    public static func selection(fromClaude params: [String: Any]) -> [String: Any]? {
        guard let path = params["filePath"] as? String, !path.isEmpty, !IDELink.isSensitive(path),
              params["selection"] is [String: Any] else { return nil }
        var result = params
        if result["text"] == nil { result["text"] = "" }
        if result["fileUrl"] == nil { result["fileUrl"] = URL(fileURLWithPath: path).absoluteString }
        return result
    }

    /// ⌥⌘K with Copilot connected: `add_selection` for lines, `add_file_reference` for a whole file. The
    /// CLI types `@path:10-20 ` into its prompt (lines 1-based here, 0-based on the wire). Only the path and
    /// the line numbers go, never the text, as with Claude's @-mentions.
    public static func fileReference(path: String, lines: ClosedRange<Int>?) -> (method: String, params: [String: Any])? {
        guard path.hasPrefix("/") else { return nil }
        var params: [String: Any] = ["filePath": path, "fileUrl": URL(fileURLWithPath: path).absoluteString,
                                     "selection": NSNull(), "selectedText": NSNull()]
        guard let lines else { return ("add_file_reference", params) }
        params["selection"] = ["start": ["line": lines.lowerBound - 1, "character": 0],
                               "end": ["line": lines.upperBound - 1, "character": 0]]
        return ("add_selection", params)
    }
}
