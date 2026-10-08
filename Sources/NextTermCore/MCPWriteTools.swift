import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Who approves the change one of Next Term's write tools would make (the tools tagged `write` that the
/// app's MCPWriteControl runs: write_file, create_file, stage, commit, focus_tab, split_pane, close_pane,
/// zoom_pane, set_layout and settings_set).
///
/// The entry point is `MCPControl.call(tool, arguments, caller: pid, approval:, requester:, reply:)` in the
/// app, on the main thread; its reply can come from any thread.
/// - The local socket (`nxtrm mcp`) never passes an approval, so a local agent's change always waits for
///   the user on the Mac. Nothing in a request's arguments can change that.
/// - The remote door calls it with `caller: nil`, `requester:` the connection's name as the approval
///   window should show it (for example “the connection “Claude, phone””), and `.askOnMac` while the
///   connection's “Ask on this Mac before changes” is on, `.preApprovedByGrant(grantID)` while it is off.
///
/// propose_edit takes the policy too, but its ask is its proposal: under either policy the change opens
/// in the editor's side-by-side diff for the user to Accept or Reject, and the tool never writes.
/// settings_get only reads, and asks nothing.
public enum MCPApproval: Equatable, Sendable {
    /// The change waits for the user's Approve in Next Term's approval window, which shows what would
    /// change and who asks. Decline, closing it, or no answer within the wait changes nothing.
    case askOnMac
    /// The user approved this connection's changes when pairing it (its “Ask on this Mac before changes”
    /// is off): the change runs at once, and its answer names the grant.
    case preApprovedByGrant(String)
}

extension MCPServer {
    /// Next Term's scope tag: whether a tool only reads ("read") or acts on this Mac ("write"). It is the
    /// remote door's cross-check, not MCP's readOnlyHint: check_host, host_sessions and host_changes run a
    /// script over a tab's ssh connection (so they are not readOnly) but only read, and are tagged read.
    public enum Scope: String, Sendable {
        case read, write
    }

    /// The tag of every tool, reviewed one by one. A tool missing here has no tag, and a unit test fails.
    static let scopeTags: [String: Scope] = {
        let read = ["list_tabs", "read_tab", "wait_for_tab", "list_projects", "get_editor_selection", "get_open_files",
                    "read_file", "find_in_files", "git_status", "get_diff", "list_hosts", "check_host", "host_sessions",
                    "host_changes", "list_skills", "settings_get"]
        let write = ["open_project", "new_tab", "send_to_tab", "press_keys", "answer_agent", "show_tab", "close_tab",
                     "add_host", "remove_host", "new_remote_tab", "install_skill", "remove_skill", "open_in_editor",
                     "propose_edit", "write_file", "create_file", "stage", "commit", "focus_tab", "split_pane",
                     "close_pane", "zoom_pane", "set_layout", "settings_set"]
        var tags: [String: Scope] = [:]
        for name in read { tags[name] = .read }
        for name in write { tags[name] = .write }
        return tags
    }()

    private static let pathArgument = #""path": {"type": "string", "description": "The file: relative to the project, or absolute inside an open project."}"#
    private static let projectArgument = #""project": {"type": "string", "description": "An open project's folder (as list_projects gives it), its name, or a folder inside one. Default: your window's project, or the only one open."}"#
    private static let tabArgument = #""tab_id": {"type": "string", "description": "A tab's id from list_tabs (a pane of a split tab has its own)."}"#
    private static let reasonArgument = #""reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words when they are asked."}"#

    /// The tools that edit files, commit, and control panes, the layout and settings. Each one tagged write
    /// takes an approval policy (MCPApproval) and asks the user on the Mac before it changes anything.
    public static let controlTools: [Tool] = [
        Tool(name: "propose_edit", title: "Propose a file edit",
             description: "Shows a change to a file in an open project as a proposal in Next Term's side-by-side diff, for the user to Accept or Reject, as Claude Code's IDE edits are. It never writes the file: after an accept, write_file (or create_file for a new file) with the same path and content writes it without asking again, for 10 minutes and while the file is as it was. Give content (the whole new text), or old_text and new_text to replace the one place where old_text appears. Answers within about 50 seconds: accepted, rejected, or pending with a proposal_id: call again with only proposal_id to keep waiting. Closing the proposal rejects it. Files outside the open projects, files that usually hold secrets (.env files, keys and certificates, ssh keys, credentials files, .git) and git hooks (the hooks folder, .husky, and pre-commit's or lefthook's settings) are refused.",
             inputSchema: #"{"type": "object", "properties": {\#(pathArgument), \#(projectArgument), "content": {"type": "string", "description": "The file's whole new text."}, "old_text": {"type": "string", "description": "Instead of content: text that appears exactly once in the file, to replace."}, "new_text": {"type": "string", "description": "With old_text: what replaces it."}, "proposal_id": {"type": "string", "description": "A pending proposal's id, to keep waiting for the user's decision."}}, "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: false, timeout: 60),
        Tool(name: "write_file", title: "Write a file in a project",
             description: "Replaces the text of an existing file in an open project with content, keeping the file's encoding, line endings and permissions. The user is asked on the Mac first (Approve or Decline, seeing what changes and who asks); nothing is written if they decline or do not answer within about 50 seconds. A change the user accepted in propose_edit is written without asking again. Refused: files outside the open projects (symlinks are resolved first), files that usually hold secrets (.env files, keys and certificates, ssh keys, credentials files, .git), git hooks (the hooks folder, .husky, and pre-commit's or lefthook's settings), binary files, files over 5 MB, and a file open in the editor with unsaved edits. create_file makes a new file.",
             inputSchema: #"{"type": "object", "properties": {\#(pathArgument), \#(projectArgument), "content": {"type": "string", "description": "The file's whole new text."}, \#(reasonArgument)}, "required": ["path", "content"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 60),
        Tool(name: "create_file", title: "Create a file in a project",
             description: "Creates a new text file (UTF-8) in an open project, and any folders missing on its path. The user is asked on the Mac first, as for write_file. Refused: a path that exists already (write_file changes a file), paths outside the open projects, files that usually hold secrets (.env files, keys and certificates, ssh keys, credentials files, .git), git hooks (as for write_file), and content over 5 MB.",
             inputSchema: #"{"type": "object", "properties": {\#(pathArgument), \#(projectArgument), "content": {"type": "string", "description": "The new file's text. Default: empty."}, \#(reasonArgument)}, "required": ["path"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60),
        Tool(name: "stage", title: "Stage files",
             description: "Stages the named files of an open project in its git repository: git add of exactly those paths (their changes, new files and deletions; no patterns). Staging a file takes all of its changes, including any the user left unstaged on purpose. The user is asked on the Mac first. Refused: folders, files that usually hold secrets, and paths outside the project's repository. It runs as the branch popup's commands do, listed in Git › Git Commands. Never commits or pushes.",
             inputSchema: #"{"type": "object", "properties": {"paths": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 200, "description": "Files, relative to the project or absolute."}, \#(projectArgument), \#(reasonArgument)}, "required": ["paths"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 60),
        Tool(name: "commit", title: "Commit",
             description: "Commits in an open project's git repository, with message. The named paths are staged first (as stage does) and the commit holds them. When other changes are staged already it refuses, since they would go into the commit too, unless include_staged is true; with no paths, include_staged: true commits what is staged. The user is asked on the Mac first, seeing the branch, the files and the message. The repository's hooks run as for any commit. Refused while a merge, rebase, cherry-pick or revert is in progress, and on a detached HEAD. Never pushes and never amends. Returns the new commit's id.",
             inputSchema: #"{"type": "object", "properties": {"message": {"type": "string", "description": "The commit message."}, "paths": {"type": "array", "items": {"type": "string"}, "maxItems": 200, "description": "Files to stage and commit, relative to the project or absolute."}, "include_staged": {"type": "boolean", "description": "Also commit what is staged already. Default false."}, \#(projectArgument), \#(reasonArgument)}, "required": ["message"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 120),
        Tool(name: "focus_tab", title: "Focus a tab",
             description: "Puts a tab (or a pane of a split tab) in front of its window and gives it that window's keyboard, so what the user types there goes to it. Unlike show_tab, it does not bring the window or Next Term forward. The user is asked on the Mac first.",
             inputSchema: #"{"type": "object", "properties": {\#(tabArgument), \#(reasonArgument)}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60),
        Tool(name: "split_pane", title: "Split a pane",
             description: "Opens a new terminal pane beside a tab's pane: to its right, or below it with direction down, in that pane's folder or directory, without taking the keyboard. Beside a remote tab with no directory, the new pane opens on the same host. The user is asked on the Mac first. Returns the new pane's id, which works like any tab's.",
             inputSchema: #"{"type": "object", "properties": {\#(tabArgument), "direction": {"type": "string", "enum": ["right", "down"], "description": "Default right."}, "directory": {"type": "string", "description": "Absolute folder on this Mac. Default: the pane's folder."}, \#(reasonArgument)}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: false, timeout: 60),
        Tool(name: "close_pane", title: "Close a pane",
             description: "Closes one pane of a split tab; the tab and its other panes stay. A pane with something running is refused unless force is true, which stops it. A remote pane kept by tmux or herdr only detaches: what runs there keeps running on the host. Refused for a tab that is not split (close_tab closes it) and for your own pane. The user is asked on the Mac first.",
             inputSchema: #"{"type": "object", "properties": {\#(tabArgument), "force": {"type": "boolean"}, \#(reasonArgument)}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: true, timeout: 60),
        Tool(name: "zoom_pane", title: "Zoom a pane",
             description: "Makes one pane of a split tab fill the tab while the others keep running behind it (zoomed true, the default), or brings every pane back (zoomed false), as Window › Maximize Pane does. The zoomed pane takes its window's keyboard. The user is asked on the Mac first; a call that changes nothing answers at once.",
             inputSchema: #"{"type": "object", "properties": {\#(tabArgument), "zoomed": {"type": "boolean", "description": "Default true."}, \#(reasonArgument)}, "required": ["tab_id"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60),
        Tool(name: "set_layout", title: "Set the layout",
             description: "Changes the layout as the View menu does. terminal_position (bottom, right, left or top) and sidebar_side (left or right) apply to every window. sidebar (shown or hidden) and terminal_folded (true folds the terminal to its tab bar, or to a rail beside the editor) apply to one window: your window, or the one with project open. The user is asked on the Mac first; a call that changes nothing answers at once with the layout.",
             inputSchema: #"{"type": "object", "properties": {"terminal_position": {"type": "string", "enum": ["bottom", "right", "left", "top"]}, "sidebar_side": {"type": "string", "enum": ["left", "right"]}, "sidebar": {"type": "string", "enum": ["shown", "hidden"]}, "terminal_folded": {"type": "boolean"}, \#(projectArgument), \#(reasonArgument)}, "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60),
        Tool(name: "settings_get", title: "Get settings",
             description: "The settings that settings_set may change, with their values and what each takes: font_size, line_height, soft_wrap, terminal_position and the notification switches. Other settings are not listed.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15),
        Tool(name: "settings_set", title: "Change settings",
             description: "Changes some of Next Term's settings, given as values: {name: value}. Only these: font_size (8 to 32, shared by the editor and the terminal), line_height (the editor's, 1.0 to 2.0), soft_wrap, terminal_position (bottom, right, left or top), notify_decisions, notify_agent_finished, notify_program_alerts and notification_sound (true or false). Never agent control, remote access, the IDE links, updates or keys. The user is asked on the Mac first, seeing each change; values already set need no asking.",
             inputSchema: #"{"type": "object", "properties": {"values": {"type": "object", "description": "Setting names and their new values, as settings_get lists them.", "minProperties": 1}, \#(reasonArgument)}, "required": ["values"], "additionalProperties": false}"#,
             readOnly: false, destructive: false, idempotent: true, timeout: 60),
    ]

    public static func isControlTool(_ name: String) -> Bool { controlTools.contains { $0.name == name } }
}

extension MCPServer.Tool {
    /// Next Term's scope tag (nil only for a tool nobody tagged, which a unit test refuses).
    public var scope: MCPServer.Scope? { MCPServer.scopeTags[name] }

    /// The `_meta` it is listed with: Claude Code keeps it loaded, and the scope tag is there for any client.
    var meta: [String: Any] {
        var meta: [String: Any] = ["anthropic/alwaysLoad": true]
        if let scope { meta["next-term/scope"] = scope.rawValue }
        return meta
    }
}

// MARK: - files

extension MCPProjects {
    /// A name list for an answer: the first `limit`, then how many more.
    static func listed(_ names: [String], limit: Int = 10) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? shown + " and \(names.count - limit) more" : shown
    }
}

/// A change to one file that write_file, create_file or propose_edit would make, worked out before the
/// user is asked, so what they approve is exactly what happens.
public struct MCPFileChange: Sendable {
    public let file: ProjectFile
    /// The text on disk when it was read ("\n" line endings when the file uses one style); nil: a new file.
    public let original: String?
    /// How the file is stored; a write keeps it. A new file is UTF-8 with "\n".
    public let format: TextFormat
    /// The text to write, in the same line endings as `original`.
    public let content: String

    public var isNew: Bool { original == nil }
    public var changesText: Bool { original != content }
}

/// The file tools' checks and writes, off the main thread. Every path goes through MCPProjects, as the
/// read tools' do: inside an open project once symlinks are resolved, and never a file that usually holds
/// secrets.
public enum MCPFileTools {
    /// The largest file written or proposed (read_file's limit too).
    public static let maxBytes = MCPProjectTools.maxFileSize

    static func content(_ arguments: [String: Any], required: Bool) throws -> String {
        guard let raw = arguments["content"], !(raw is NSNull) else {
            if required { throw MCPToolError("Give content: the file's whole new text.") }
            return ""
        }
        guard let text = raw as? String else { throw MCPToolError("content must be text.") }
        guard !text.contains("\0") else { throw MCPToolError("content has a NUL character; only text files are written.") }
        guard text.utf8.count <= maxBytes else { throw MCPToolError("content is over 5 MB; Next Term writes files up to 5 MB.") }
        return text
    }

    /// The file's text and format, refusing what the editor would not open as text.
    static func read(_ file: ProjectFile) throws -> (text: String, format: TextFormat) {
        var info = stat()
        guard stat(file.path, &info) == 0, let data = FileManager.default.contents(atPath: file.path) else {
            throw MCPToolError("Could not read \(file.relative).")
        }
        guard info.st_size <= maxBytes else { throw MCPToolError("\(file.relative) is over 5 MB; Next Term writes files up to 5 MB.") }
        guard let decoded = TextFile.decode(data) else {
            throw MCPToolError("\(file.relative) is a binary file (or text in an encoding other than UTF-8 or UTF-16); only text files are written.")
        }
        return decoded
    }

    /// Text in the file's own line endings: "\r\n" becomes "\n" for a file that uses "\r\n" throughout.
    static func normalized(_ text: String, for format: TextFormat) -> String {
        format.lineEnding == .crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }

    /// The body's value, or its refusal.
    static func catching<T>(_ body: () throws -> T) -> Result<T, MCPToolError> {
        do {
            return .success(try body())
        } catch let error as MCPToolError {
            return .failure(error)
        } catch {
            return .failure(MCPToolError(error.localizedDescription))
        }
    }

    /// Whether a file in the repository's top folder holds the settings of a hook manager that runs what
    /// they list on every commit: pre-commit's, or lefthook's (lefthook.yml, .lefthook-local.toml and so on).
    static func isHookSettings(_ name: String) -> Bool {
        let name = name.lowercased()
        if name == ".pre-commit-config.yaml" || name == ".pre-commit-config.yml" { return true }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let lefthook = ["lefthook", ".lefthook", "lefthook-local", ".lefthook-local"].contains(stem)
        return lefthook && ["yml", "yaml", "json", "jsonc", "toml"].contains(ext)
    }

    /// Why writing `file` would let a commit run code, or nil: a file in the repository's hooks folder
    /// (`core.hooksPath`, which husky points at `.husky/_`), in `.husky` (whose scripts husky's hooks run),
    /// or the settings of pre-commit or lefthook, which list what their hooks run. commit runs the hooks,
    /// so without this an agent's write and commit together could run anything. `.git/hooks` is refused
    /// already, as part of `.git`. The file's repository is checked, and each one around it (a
    /// submodule's outer repository, or one a nested clone sits in), since commit may run in any of them.
    /// With no git there is no commit, and nothing to check; a git that does not answer refuses the write.
    ///
    /// This closes only the direct way. Hooks that run the project's own scripts or tests (lint-staged,
    /// `npm test`) run whatever an agent wrote there, so an approved write is still code that may run.
    public static func hookReason(_ file: ProjectFile, git: String?) throws -> String? {
        guard let git else { return nil }
        // Compared without case: the Mac's disks usually ignore it.
        let path = file.path.lowercased()
        // The nearest folder that exists: a new file's folders may not, yet.
        var folder = (file.path as NSString).deletingLastPathComponent
        while !MCPProjects.isFolder(folder), folder.count > 1 { folder = (folder as NSString).deletingLastPathComponent }
        for _ in 0..<8 {
            guard let (top, hooks) = try repositoryHooks(from: folder, git: git, name: file.relative) else { return nil }
            if path.hasPrefix(hooks + "/") || path.hasPrefix(top + "/.husky/") { return "is a git hook, which commit would run" }
            let inTop = (path as NSString).deletingLastPathComponent == top
            if inTop, isHookSettings((path as NSString).lastPathComponent) {
                return "lists what the repository's git hooks run, which commit would run"
            }
            let around = (top as NSString).deletingLastPathComponent
            guard around != top, around.count > 1 else { return nil }
            folder = around
        }
        return nil
    }

    /// The top folder and the hooks folder (real paths, in lower case) of the repository holding `folder`;
    /// nil outside a repository.
    static func repositoryHooks(from folder: String, git: String, name: String) throws -> (top: String, hooks: String)? {
        let args = ["-C", folder, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-path", "hooks"]
        // 128: not in a repository, so no commit runs hooks there.
        guard let data = GitRunner.run(git, args, timeout: 10, acceptedStatus: [0, 128]) else {
            throw MCPToolError("Not written: Next Term could not check \(name) against the repository's git hooks, because git did not answer. Try again.")
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        return (MCPProjects.realPath(lines[0]).lowercased(), MCPProjects.realPath(lines[1]).lowercased())
    }

    /// A file the write tools may change: inside an open project, not a secrets file, not a git hook.
    static func writable(_ arguments: [String: Any], mustExist: Bool, in projects: MCPProjects, git: String?) throws -> ProjectFile {
        let file = try projects.file(arguments["path"], project: arguments["project"], mustExist: mustExist, writing: true).get()
        if let reason = try hookReason(file, git: git) {
            throw MCPProjects.refusal(arguments["path"] as? String ?? file.relative, reason, writing: true)
        }
        return file
    }

    /// write_file: an existing text file and its new text.
    public static func prepareWrite(_ arguments: [String: Any], in projects: MCPProjects, git: String?) -> Result<MCPFileChange, MCPToolError> {
        MCPFileTools.catching {
            let content = try content(arguments, required: true)
            let file = try writable(arguments, mustExist: true, in: projects, git: git)
            let (text, format) = try read(file)
            return MCPFileChange(file: file, original: text, format: format, content: normalized(content, for: format))
        }
    }

    /// create_file: a path where nothing is yet.
    public static func prepareCreate(_ arguments: [String: Any], in projects: MCPProjects, git: String?) -> Result<MCPFileChange, MCPToolError> {
        MCPFileTools.catching {
            let content = try content(arguments, required: false)
            let file = try newFile(arguments, in: projects, git: git)
            return MCPFileChange(file: file, original: nil, format: TextFormat(), content: content)
        }
    }

    /// propose_edit: an existing file or a new one, with content, or old_text replaced by new_text.
    public static func prepareProposal(_ arguments: [String: Any], in projects: MCPProjects, git: String?) -> Result<MCPFileChange, MCPToolError> {
        MCPFileTools.catching {
            let args = MCPArguments(arguments)
            let old = try args.string("old_text")
            let new = try args.string("new_text")
            let hasContent = arguments["content"] != nil && !(arguments["content"] is NSNull)
            if hasContent, old != nil || new != nil { throw MCPToolError("Give content, or old_text and new_text, not both.") }
            if !hasContent, old == nil || new == nil { throw MCPToolError("Give content (the whole new text), or old_text and new_text.") }
            let file = try writable(arguments, mustExist: false, in: projects, git: git)
            guard MCPProjects.exists(file.path) else {
                guard hasContent else { throw MCPToolError("No such file: \(file.relative); a new file's proposal takes content.") }
                let content = try content(arguments, required: true)
                return MCPFileChange(file: file, original: nil, format: TextFormat(), content: content)
            }
            let (text, format) = try read(file)
            if let old, let new {
                let replaced = try replacing(normalized(old, for: format), with: normalized(new, for: format), in: text, name: file.relative)
                guard replaced.utf8.count <= maxBytes else { throw MCPToolError("The new text is over 5 MB; Next Term writes files up to 5 MB.") }
                return MCPFileChange(file: file, original: text, format: format, content: replaced)
            }
            let content = try content(arguments, required: true)
            return MCPFileChange(file: file, original: text, format: format, content: normalized(content, for: format))
        }
    }

    /// `text` with the one place `old` appears replaced by `new`.
    public static func replacing(_ old: String, with new: String, in text: String, name: String) throws -> String {
        guard !old.isEmpty else { throw MCPToolError("old_text is empty.") }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else { throw MCPToolError("old_text is not in \(name); it must match exactly, spaces and line breaks included.") }
        guard count == 1 else { throw MCPToolError("old_text appears \(count) times in \(name); give more of the text around it, so it appears once.") }
        guard let range = text.range(of: old) else { throw MCPToolError("old_text is not in \(name).") }
        return text.replacingCharacters(in: range, with: new)
    }

    /// A path where create_file may make a file: inside an open project, not a secrets file, and free.
    static func newFile(_ arguments: [String: Any], in projects: MCPProjects, git: String?) throws -> ProjectFile {
        if let text = arguments["path"] as? String, text.hasSuffix("/") { throw MCPToolError("Give a file's path, not a folder's.") }
        let file = try writable(arguments, mustExist: false, in: projects, git: git)
        var info = stat()
        if lstat(file.path, &info) == 0 {
            throw MCPToolError("\(file.relative) exists already; write_file changes a file, create_file only makes new ones.")
        }
        return file
    }

    /// The text on disk now, or nil when it is gone or no longer text.
    public static func current(_ file: ProjectFile) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return TextFile.decode(data)?.text
    }

    /// Writes an existing file's new text, if the file is still as it was read: atomically, through a
    /// symlink to the file it points at, keeping its permissions, encoding and line endings.
    public static func write(_ change: MCPFileChange) throws {
        guard let original = change.original else { return try create(change) }
        guard current(change.file) == original else {
            throw MCPToolError("\(change.file.relative) changed since it was read, so nothing was written. Read it again and ask again.")
        }
        try TextFile.write(TextFile.encode(change.content, as: change.format), to: URL(fileURLWithPath: change.file.path))
    }

    /// Makes a new file (and the folders on its path), never over anything that appeared meanwhile.
    public static func create(_ change: MCPFileChange) throws {
        let folder = (change.file.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // The folders made, resolved again: still inside the project.
        let real = MCPProjects.realPath(folder)
        guard real == change.file.root || real.hasPrefix(change.file.root + "/") else {
            throw MCPToolError("\(change.file.relative) would be outside the project; nothing was written.")
        }
        let fd = open(change.file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw MCPToolError("\(change.file.relative) appeared meanwhile, so nothing was written.") }
            throw MCPToolError("Could not create \(change.file.relative): \(String(cString: strerror(errno))).")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: TextFile.encode(change.content, as: change.format))
            try handle.close()
        } catch {
            throw MCPToolError("Could not write \(change.file.relative): \(error.localizedDescription)")
        }
    }

    /// What the approval window says the change does: the lines added and removed, and the first changed
    /// lines (a new file: its size and first lines).
    public static func summary(_ change: MCPFileChange, git: String?) -> String {
        let lines = change.content.isEmpty ? 0 : ProjectSearch.splitLines(change.content).count
        guard let original = change.original else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(change.content.utf8.count), countStyle: .file)
            let head = ProjectSearch.splitLines(change.content).prefix(8).map { "  " + cut($0.0) }
            return (["\(lines) line\(lines == 1 ? "" : "s"), \(size)."] + head).joined(separator: "\n")
        }
        guard let git, let diff = GitRunner.diff(old: original, new: change.content, git: git, context: 0) else {
            return "\(lines) line\(lines == 1 ? "" : "s") after the change."
        }
        let added = diff.hunks.reduce(0) { $0 + $1.added }
        let removed = diff.hunks.reduce(0) { $0 + $1.removed }
        var shown: [String] = []
        for line in diff.hunks.flatMap(\.lines) where line.kind != .context {
            if shown.count == 12 { break }
            shown.append((line.kind == .added ? "+ " : "− ") + cut(line.text))
        }
        let total = added + removed
        if total > shown.count { shown.append("… and \(total - shown.count) more changed lines.") }
        return (["+\(added) −\(removed) lines."] + shown).joined(separator: "\n")
    }

    static func cut(_ line: String) -> String {
        line.count > 100 ? String(line.prefix(100)) + "…" : line
    }
}

// MARK: - git

/// A git repository as stage and commit see it.
public struct MCPRepository: Equatable, Sendable {
    /// The work tree's top folder (real path).
    public let root: String
    public let gitDir: String
    /// Shared by the repository's worktrees: GitWriter takes turns per common folder.
    public let commonDir: String
    /// The branch checked out; nil on a detached HEAD.
    public let branch: String?
    public let inProgress: GitInProgress?

    public init(root: String, gitDir: String, commonDir: String, branch: String?, inProgress: GitInProgress?) {
        self.root = root
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.branch = branch
        self.inProgress = inProgress
    }
}

/// What stage or commit would do, worked out before the user is asked.
public struct MCPGitPlan: Sendable {
    public let repository: MCPRepository
    /// The files named, from the repository's top folder.
    public let paths: [String]
    /// What was staged when the plan was made.
    public let staged: [String]
    /// What is staged (stage) or committed (commit).
    public let files: [String]
    /// The commit's message; nil for stage.
    public let message: String?
}

/// stage's and commit's checks: which paths, which message, and when a commit is refused.
public enum MCPGitTools {
    /// The repository holding `folder`, read without locks.
    public static func repository(of folder: String, git: String) -> MCPRepository? {
        let args = ["-C", folder, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"]
        guard let data = GitRunner.run(git, args, timeout: 10) else { return nil }
        let dirs = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard dirs.count >= 3 else { return nil }
        let head = GitRunner.run(git, ["-C", folder, "symbolic-ref", "--quiet", "--short", "HEAD"], timeout: 10, acceptedStatus: [0, 1])
        let branch = head.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return MCPRepository(root: canonicalPath(dirs[0]), gitDir: dirs[1], commonDir: canonicalPath(dirs[2]),
                             branch: branch?.isEmpty == false ? branch : nil, inProgress: BranchModel.inProgress(gitDir: dirs[1]))
    }

    /// The named files as repository paths, sorted: inside the project and its repository (a deleted file
    /// too), never a folder or a file that usually holds secrets.
    public static func paths(_ raw: Any?, required: Bool, project: String, repository: MCPRepository,
                             projects: MCPProjects) -> Result<[String], MCPToolError> {
        guard let raw, !(raw is NSNull) else {
            return required ? .failure(MCPToolError("Give paths: the files to stage.")) : .success([])
        }
        guard let list = raw as? [Any], list.allSatisfy({ $0 is String }) else { return .failure(MCPToolError("paths is a list of file paths.")) }
        let names = list.compactMap { $0 as? String }
        if required, names.isEmpty { return .failure(MCPToolError("Give paths: the files to stage.")) }
        guard names.count <= 200 else { return .failure(MCPToolError("Give at most 200 paths at a time.")) }
        var result = Set<String>()
        for name in names {
            switch projects.file(name, project: project, mustExist: false, writing: true) {
            case .failure(let error): return .failure(error)
            case .success(let file):
                guard file.path.hasPrefix(repository.root + "/") else {
                    return .failure(MCPToolError("\(name) is not in the repository at \(repository.root)."))
                }
                if MCPProjects.isFolder(file.path) { return .failure(MCPToolError("\(name) is a folder; name its files.")) }
                result.insert(String(file.path.dropFirst(repository.root.count + 1)))
            }
        }
        return .success(result.sorted())
    }

    /// A commit message as given, refusing an empty or oversized one.
    public static func message(_ raw: Any?) -> Result<String, MCPToolError> {
        guard let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(MCPToolError("Give message: the commit message."))
        }
        guard !text.contains("\0") else { return .failure(MCPToolError("The message has a NUL character.")) }
        guard text.count <= 10_000 else { return .failure(MCPToolError("The message is over 10,000 characters.")) }
        return .success(text)
    }

    /// Why nothing may be committed in the repository now, or nil.
    public static func commitRefusal(_ repository: MCPRepository) -> MCPToolError? {
        if let progress = repository.inProgress {
            return MCPToolError("\(progress.title) is in progress in \(repository.root), so nothing was committed. Finish or abort it first (the branch popup offers both).")
        }
        if repository.branch == nil {
            return MCPToolError("HEAD is detached in \(repository.root): a commit there would be on no branch, so nothing was committed. Switch to a branch first.")
        }
        return nil
    }

    /// The files a commit would hold: the named ones and what is staged. Refused when other changes are
    /// staged and the caller did not say to include them (they would go into the commit unseen).
    public static func commitFiles(named: [String], staged: [String], includeStaged: Bool) -> Result<[String], MCPToolError> {
        let wanted = Set(named)
        let others = staged.filter { !wanted.contains($0) }.sorted()
        if named.isEmpty {
            if staged.isEmpty { return .failure(MCPToolError("Nothing to commit: nothing is staged, and no paths were named.")) }
            guard includeStaged else {
                return .failure(MCPToolError("Name the paths to commit, or pass include_staged: true to commit what is staged now: \(MCPProjects.listed(staged.sorted())). Nothing was committed."))
            }
            return .success(staged.sorted())
        }
        if !others.isEmpty, !includeStaged {
            return .failure(MCPToolError("Other changes are staged already, and would go into this commit too: \(MCPProjects.listed(others)). Pass include_staged: true to commit them as well, or ask the user to unstage them. Nothing was committed."))
        }
        return .success(Array(wanted.union(staged)).sorted())
    }

    /// stage: the repository and the files named.
    public static func prepareStage(_ arguments: [String: Any], in projects: MCPProjects, git: String) -> Result<MCPGitPlan, MCPToolError> {
        MCPFileTools.catching {
            let (folder, repository) = try locate(arguments, in: projects, git: git)
            let paths = try self.paths(arguments["paths"], required: true, project: folder, repository: repository, projects: projects).get()
            return MCPGitPlan(repository: repository, paths: paths, staged: BranchModel.stagedFiles(at: repository.root, git: git), files: paths, message: nil)
        }
    }

    /// commit: the repository, the files named, what is staged now, what the commit would hold and its
    /// message, or why it is refused.
    public static func prepareCommit(_ arguments: [String: Any], in projects: MCPProjects, git: String) -> Result<MCPGitPlan, MCPToolError> {
        MCPFileTools.catching {
            let message = try message(arguments["message"]).get()
            let includeStaged = try MCPArguments(arguments).bool("include_staged", default: false)
            let (folder, repository) = try locate(arguments, in: projects, git: git)
            if let refusal = commitRefusal(repository) { throw refusal }
            let paths = try self.paths(arguments["paths"], required: false, project: folder, repository: repository, projects: projects).get()
            let staged = BranchModel.stagedFiles(at: repository.root, git: git)
            let files = try commitFiles(named: paths, staged: staged, includeStaged: includeStaged).get()
            return MCPGitPlan(repository: repository, paths: paths, staged: staged, files: files, message: message)
        }
    }

    static func locate(_ arguments: [String: Any], in projects: MCPProjects, git: String) throws -> (String, MCPRepository) {
        let folder = try projects.project(arguments["project"]).get()
        guard let repository = repository(of: folder, git: git) else { throw MCPToolError("\(folder) is not in a git repository.") }
        return (folder, repository)
    }

    /// Why the plan the user approved no longer holds (the staged files or the branch changed meanwhile),
    /// or nil.
    public static func changedSince(_ plan: MCPGitPlan, git: String) -> MCPToolError? {
        guard let now = repository(of: plan.repository.root, git: git) else { return MCPToolError("The repository is gone; nothing changed.") }
        if plan.message != nil {
            if let refusal = commitRefusal(now) { return refusal }
            if now.branch != plan.repository.branch {
                return MCPToolError("The branch changed to \(now.branch ?? "a detached HEAD") while the user was asked, so nothing was committed.")
            }
            if Set(BranchModel.stagedFiles(at: now.root, git: git)) != Set(plan.staged) {
                return MCPToolError("The staged changes changed while the user was asked, so nothing was committed. Ask again.")
            }
        }
        return nil
    }

    /// What the approval window says: the repository and branch, the files and, for a commit, its message.
    public static func summary(_ plan: MCPGitPlan) -> String {
        let name = (plan.repository.root as NSString).lastPathComponent
        let named = Set(plan.paths)
        let files = plan.files.prefix(12).map { "  " + $0 + (named.contains($0) || plan.message == nil ? "" : " (staged already)") }
        let more = plan.files.count > 12 ? ["  … and \(plan.files.count - 12) more"] : []
        guard let message = plan.message else {
            let count = "\(plan.files.count) file\(plan.files.count == 1 ? "" : "s")"
            return (["git add of \(count) in \(name):"] + files + more + ["Nothing is committed or pushed."]).joined(separator: "\n")
        }
        let branch = plan.repository.branch ?? "a detached HEAD"
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { "  " + MCPFileTools.cut(String($0)) }
        let header = "A commit in \(name) on \(branch), of \(plan.files.count) file\(plan.files.count == 1 ? "" : "s"):"
        return ([header] + files + more + ["With the message:"] + lines + ["Nothing is pushed."]).joined(separator: "\n")
    }

    /// `git add` of exactly the paths in a NUL-separated file: no patterns, deletions included.
    public static func stageArguments(pathspecFile: String) -> [String] {
        ["--literal-pathspecs", "add", "--all", "--pathspec-from-file=" + pathspecFile, "--pathspec-file-nul"]
    }

    /// A plain commit of the index with the message in a file: no amend, no push, hooks as usual.
    public static func commitArguments(messageFile: String) -> [String] {
        ["commit", "--file=" + messageFile]
    }

    /// The new commit's short id, from "[main abc1234] Subject".
    public static func committedID(from output: String) -> String? {
        guard let bracket = output.range(of: #"\[[^\]]* ([0-9a-f]{7,})\]"#, options: .regularExpression) else { return nil }
        let last = String(output[bracket]).components(separatedBy: " ").last ?? ""
        return last.isEmpty ? nil : String(last.dropLast())
    }
}

// MARK: - settings and layout

/// The settings agents may change with settings_set: a short, explicit list of harmless preferences. Agent
/// control, remote access, the IDE links, updates and keys are never on it, so no agent can turn off its
/// own guards or the user's view of them.
public enum MCPSettings {
    public enum Kind: Equatable, Sendable {
        case flag
        case number(ClosedRange<Double>, wholeNumbers: Bool)
        case choice([String])
    }

    public enum Value: Equatable, Sendable {
        case flag(Bool)
        case number(Double)
        case choice(String)

        /// As JSON shows it.
        public var json: Any {
            switch self {
            case .flag(let on): return on
            case .number(let number): return number == number.rounded() ? Int(number) as Any : number as Any
            case .choice(let text): return text
            }
        }

        public var text: String {
            switch self {
            case .flag(let on): return on ? "on" : "off"
            case .number(let number): return number == number.rounded() ? String(Int(number)) : String(number)
            case .choice(let text): return text
            }
        }
    }

    public struct Setting: Sendable {
        public let name: String
        public let title: String
        public let kind: Kind

        /// What it takes, for settings_get.
        public var takes: String {
            switch kind {
            case .flag: return "true or false"
            case .number(let range, let whole):
                let low = Value.number(range.lowerBound).text, high = Value.number(range.upperBound).text
                return whole ? "a whole number, \(low) to \(high)" : "a number, \(low) to \(high)"
            case .choice(let options): return options.joined(separator: ", ")
            }
        }
    }

    public static let allowlist: [Setting] = [
        Setting(name: "font_size", title: "Font size", kind: .number(8...32, wholeNumbers: true)),
        Setting(name: "line_height", title: "Editor line height", kind: .number(1...2, wholeNumbers: false)),
        Setting(name: "soft_wrap", title: "Soft wrap", kind: .flag),
        Setting(name: "terminal_position", title: "Terminal position", kind: .choice(["bottom", "right", "left", "top"])),
        Setting(name: "notify_decisions", title: "Notify when an agent needs your decision", kind: .flag),
        Setting(name: "notify_agent_finished", title: "Notify when an agent finishes", kind: .flag),
        Setting(name: "notify_program_alerts", title: "Notify on a program's own bell or notification", kind: .flag),
        Setting(name: "notification_sound", title: "Play a sound with notifications", kind: .flag),
    ]

    public static func setting(_ name: String) -> Setting? { allowlist.first { $0.name == name } }

    /// The changes asked for, in the allowlist's order, each value checked; anything else refuses them all.
    public static func changes(_ raw: Any?) -> Result<[(Setting, Value)], MCPToolError> {
        guard let values = raw as? [String: Any], !values.isEmpty else {
            return .failure(MCPToolError("Give values: setting names and their new values, such as {\"font_size\": 14}."))
        }
        let names = allowlist.map(\.name).joined(separator: ", ")
        for name in values.keys.sorted() where setting(name) == nil {
            return .failure(MCPToolError("“\(name)” is not a setting agents may change; nothing was changed. These are: \(names)."))
        }
        var result: [(Setting, Value)] = []
        for setting in allowlist {
            guard let raw = values[setting.name] else { continue }
            switch value(raw, for: setting) {
            case .failure(let error): return .failure(error)
            case .success(let value): result.append((setting, value))
            }
        }
        return .success(result)
    }

    static func value(_ raw: Any, for setting: Setting) -> Result<Value, MCPToolError> {
        let refusal = MCPToolError("\(setting.name) takes \(setting.takes); nothing was changed.")
        switch setting.kind {
        case .flag:
            guard MCPServer.isBoolean(raw), let on = raw as? Bool else { return .failure(refusal) }
            return .success(.flag(on))
        case .number(let range, let whole):
            guard !MCPServer.isBoolean(raw), let number = (raw as? NSNumber)?.doubleValue, range.contains(number) else { return .failure(refusal) }
            if whole, number != number.rounded() { return .failure(refusal) }
            return .success(.number(number))
        case .choice(let options):
            guard let text = raw as? String, options.contains(text) else { return .failure(refusal) }
            return .success(.choice(text))
        }
    }
}

/// What set_layout was asked to change; nil fields stay as they are.
public struct MCPLayoutChange: Equatable, Sendable {
    public var terminalPosition: String?
    public var sidebarSide: String?
    public var sidebarShown: Bool?
    public var terminalFolded: Bool?

    public init(terminalPosition: String? = nil, sidebarSide: String? = nil, sidebarShown: Bool? = nil, terminalFolded: Bool? = nil) {
        self.terminalPosition = terminalPosition
        self.sidebarSide = sidebarSide
        self.sidebarShown = sidebarShown
        self.terminalFolded = terminalFolded
    }

    public var isEmpty: Bool { terminalPosition == nil && sidebarSide == nil && sidebarShown == nil && terminalFolded == nil }

    public static func parse(_ arguments: [String: Any]) -> Result<MCPLayoutChange, MCPToolError> {
        MCPFileTools.catching {
            let args = MCPArguments(arguments)
            var change = MCPLayoutChange()
            if arguments["terminal_position"] != nil {
                change.terminalPosition = try args.choice("terminal_position", of: ["bottom", "right", "left", "top"], default: "bottom")
            }
            if arguments["sidebar_side"] != nil { change.sidebarSide = try args.choice("sidebar_side", of: ["left", "right"], default: "left") }
            if arguments["sidebar"] != nil { change.sidebarShown = try args.choice("sidebar", of: ["shown", "hidden"], default: "shown") == "shown" }
            if arguments["terminal_folded"] != nil { change.terminalFolded = try args.bool("terminal_folded", default: false) }
            guard !change.isEmpty else {
                throw MCPToolError("Give at least one of terminal_position, sidebar_side, sidebar and terminal_folded.")
            }
            return change
        }
    }
}
