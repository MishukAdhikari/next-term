import Foundation

/// The editor link to Claude Code (and OpenCode, which speaks its protocol), Gemini CLI, Qwen Code and
/// GitHub Copilot CLI (ClaudeIDEServer, GeminiIDEServer, CopilotIDEServer).
public enum IDELink {
    /// Files whose selection and place among the open files are never shared: environment files
    /// (`.env`, `.env.*`, `*.env`, `.flaskenv`) except the committed `.env.example`, keys, and two
    /// credentials files. The MCP tools refuse a longer list (MCPProjects.secretReason).
    public static func isSensitive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if EnvFile.isEnvFile(named: name) { return name != ".env.example" }
        return name.hasSuffix(".pem") || name.hasSuffix(".key") || name == "id_rsa" || name == "id_ed25519"
            || name == ".npmrc" || name == ".netrc"
    }

    /// An @-mention Send to Agent puts straight into a linked agent's prompt (`at_mentioned`): a file, and its lines as
    /// that agent counts them.
    public struct Mention: Equatable, Sendable {
        public var filePath: String
        public var lineStart: Int?
        public var lineEnd: Int?

        public init(filePath: String, lineStart: Int? = nil, lineEnd: Int? = nil) {
            self.filePath = filePath
            self.lineStart = lineStart
            self.lineEnd = lineEnd
        }

        /// The notification's params.
        public var params: [String: Any] {
            var params: [String: Any] = ["filePath": filePath]
            if let lineStart { params["lineStart"] = lineStart }
            if let lineEnd { params["lineEnd"] = lineEnd }
            return params
        }
    }

    /// The mention for `lines` (1-based, as the editor shows them) of the file at `path`. Claude Code counts lines from 0,
    /// as LSP does. OpenCode counts them from 1 (it labels the mention `#start-end` and reads from `start`), and drops a
    /// mention without lines, so a file or a folder gets none: it is typed into OpenCode's prompt instead.
    public static func mention(path: String, lines: ClosedRange<Int>?, opencode: Bool) -> Mention? {
        guard let lines else { return opencode ? nil : Mention(filePath: path) }
        let shift = opencode ? 0 : 1
        return Mention(filePath: path, lineStart: lines.lowerBound - shift, lineEnd: lines.upperBound - shift)
    }

    /// The mentions Send to Agent puts into a linked agent's prompt for `items`, in order, or nil when any of them has to be
    /// typed: a mention carries only a file and its lines, so a folder, a note ("as staged", "deleted") or code that is not
    /// on disk is typed, and so is a file without lines for OpenCode. All or none, so the items stay in one prompt.
    public static func mentions(_ items: [ContextItem], opencode: Bool) -> [Mention]? {
        var mentions: [Mention] = []
        for item in items {
            guard !item.isFolder, item.note == nil, item.code == nil else { return nil }
            guard let mention = mention(path: item.path, lines: item.lines, opencode: opencode) else { return nil }
            mentions.append(mention)
        }
        return mentions
    }

    /// Whether a client of the Claude Code link is OpenCode, which counts a mention's lines from 1 and takes none without
    /// lines: it names itself "opencode" in its handshake, or it came in without the token, which only an opencode process
    /// running in one of this app's tabs can (IDEPeer), whatever name it then gives.
    public static func isOpencode(clientName: String?, tokenless: Bool) -> Bool {
        tokenless || clientName == "opencode"
    }

    /// What a linked OpenCode is told once the editor shows no file it may share (none open, or one that holds secrets):
    /// the last file shared with it, with no text and no range, which OpenCode tells its model only as an open file. The
    /// clearing message Claude Code takes (a selection with no file and no text) fails OpenCode's check, and OpenCode
    /// would keep sending the old lines. Nil, and nothing is sent, before any file was shared, or for a sensitive one.
    public static func opencodeEmptySelection(lastShared: String?) -> [String: Any]? {
        guard let path = lastShared, !isSensitive(path) else { return nil }
        let origin: [String: Int] = ["line": 0, "character": 0]
        return [
            "text": "",
            "filePath": path,
            "fileUrl": URL(fileURLWithPath: path).absoluteString,
            "selection": ["start": origin, "end": origin, "isEmpty": true] as [String: Any],
        ]
    }

    /// What a linked OpenCode is sent for `claude`, the selection Claude Code is sent, and the file to remember as the last
    /// one shared with it: the same selection while it names a file that may be shared, else the empty one for the last
    /// file. Nil: nothing to send.
    public static func opencodeSelection(_ claude: [String: Any], lastShared: String?) -> (params: [String: Any], lastShared: String?)? {
        if let path = claude["filePath"] as? String, claude["text"] is String, !isSensitive(path) {
            return (claude, path)
        }
        guard let empty = opencodeEmptySelection(lastShared: lastShared) else { return nil }
        return (empty, lastShared)
    }

    /// Compares a secret in constant time (no early exit at the first different byte).
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(x, y) { difference |= left ^ right }
        return difference == 0
    }
}
