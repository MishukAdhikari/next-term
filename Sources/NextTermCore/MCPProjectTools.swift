import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A tool call that cannot go ahead, with a plain sentence saying why (and what to do instead).
public struct MCPToolError: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// A file of an open project, as the project tools see it.
public struct ProjectFile: Equatable, Sendable {
    /// The open project holding it (its real path).
    public let root: String
    /// The file's real path (symlinks resolved), inside `root`.
    public let path: String
    /// `path` relative to `root`.
    public var relative: String { path == root ? "" : String(path.dropFirst(root.count + 1)) }
}

/// The projects open in Next Term, which bound what the project tools may read: nothing outside
/// them, symlinks resolved first, and never files that usually hold secrets.
public struct MCPProjects: Sendable {
    /// Real paths of the open projects' folders.
    public let open: [String]
    /// The caller's own window's project, used when a call names none.
    public let preferred: String?

    public init(open: [String], preferred: String?) {
        self.open = Array(Set(open.map(canonicalPath))).sorted()
        self.preferred = preferred.map(canonicalPath)
    }

    private var listed: String { open.isEmpty ? "none" : open.joined(separator: ", ") }

    /// The open project (or a folder inside one) a call names: its folder or its name. With none, the
    /// caller's window's project, or the only one open.
    public func project(_ raw: Any?) -> Result<String, MCPToolError> {
        if raw != nil, !(raw is String) { return .failure(.init("project is an open project's folder or name.")) }
        let text = (raw as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if text.isEmpty {
            if let preferred, open.contains(preferred) { return .success(preferred) }
            if open.count == 1 { return .success(open[0]) }
            return .failure(.init(open.isEmpty ? "No project is open in Next Term; open_project opens one."
                                               : "Give project: one of the open projects (\(listed))."))
        }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let real = Self.realPath(expanded)
            if open.contains(real) || (root(holding: real) != nil && Self.isFolder(real)) { return .success(real) }
            return .failure(.init("Not an open project: \(text). Open projects: \(listed); open_project opens a folder."))
        }
        let named = open.filter { ($0 as NSString).lastPathComponent.caseInsensitiveCompare(text) == .orderedSame }
        if named.count == 1 { return .success(named[0]) }
        if named.count > 1 { return .failure(.init("More than one open project is called \(text): \(named.joined(separator: ", ")). Give its folder.")) }
        return .failure(.init("No open project is called \(text). Open projects: \(listed)."))
    }

    /// The open project whose folder holds `path` (a real path), the innermost if they nest.
    public func root(holding path: String) -> String? {
        open.filter { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }.max { $0.count < $1.count }
    }

    /// A file a call names: relative to the project, or absolute. It must be inside an open project
    /// once symlinks are resolved, and must not look like it holds secrets (checked on the name asked
    /// for and on the real one, since a harmless-looking link can point at `.env`). `mustExist: false`
    /// allows a deleted file (get_diff).
    public func file(_ raw: Any?, project: Any?, mustExist: Bool = true) -> Result<ProjectFile, MCPToolError> {
        guard let text = raw as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.init("Give path: a file in an open project, relative to it or absolute."))
        }
        guard !text.contains("\0") else { return .failure(.init("That path has a NUL character.")) }
        let expanded = (text as NSString).expandingTildeInPath
        let lexical: String
        if expanded.hasPrefix("/") {
            lexical = expanded
        } else if project != nil || preferred.map({ open.contains($0) }) == true || open.count <= 1 {
            switch self.project(project) {
            case .failure(let error): return .failure(error)
            case .success(let base): lexical = (base as NSString).appendingPathComponent(expanded)
            }
        } else {
            // Several projects and none named: the one that has the file.
            let having = open.map { ($0 as NSString).appendingPathComponent(expanded) }.filter { Self.exists($0) }
            if having.count > 1 { return .failure(.init("\(text) is in more than one open project; give project.")) }
            guard let only = having.first else { return .failure(.init("No file \(text) in the open projects (\(listed)).")) }
            lexical = only
        }
        if let reason = Self.secretReason(expanded.hasPrefix("/") ? (lexical as NSString).lastPathComponent : expanded) {
            return .failure(Self.refusal(text, reason))
        }
        guard Self.exists(lexical) || !mustExist else { return .failure(.init("No such file: \(text).")) }
        // A missing file (deleted) is resolved through its folder; ".." there could walk anywhere.
        if !Self.exists(lexical), lexical.split(separator: "/").contains("..") {
            return .failure(.init("Give the path without “..”."))
        }
        let real = Self.realPath(lexical)
        guard let root = root(holding: real) else {
            return .failure(.init("\(text) is outside the projects open in Next Term (\(listed)); only files inside them are read."))
        }
        let file = ProjectFile(root: root, path: real)
        if let reason = Self.secretReason(file.relative) { return .failure(Self.refusal(text, reason)) }
        if mustExist || Self.exists(real) {
            if Self.isFolder(real) { return .failure(.init("\(text) is a folder; find_in_files searches one, and read_file reads a file in it.")) }
            guard isRegularFile(real) else { return .failure(.init("\(text) is not a regular file.")) }
        }
        return .success(file)
    }

    static func refusal(_ asked: String, _ reason: String) -> MCPToolError {
        .init("Not read: \(asked) \(reason). Next Term never gives such files to agents; ask the user for what you need from it.")
    }

    // MARK: secrets

    /// Folders that hold keys and credentials.
    static let secretFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store"]
    /// File names that hold credentials.
    static let secretNames: Set<String> = [".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", ".htpasswd",
                                           "auth.json", ".dockercfg", "keychain", ".envrc"]
    /// Extensions of keys, certificates with keys, and state files full of secrets.
    static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "p8", "jks", "keystore", "ppk", "tfstate", "tfvars",
                                                "keychain", "keychain-db", "kdbx", "age"]

    /// Why a project-relative path is never read, or nil if it may be: environment files, keys and
    /// certificates, ssh keys, credentials files, and git's own folder (which can hold tokens).
    public static func secretReason(_ relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last?.lowercased() else { return nil }
        for folder in parts.dropLast().map({ $0.lowercased() }) {
            if folder == ".git" { return "is inside git’s own folder (.git), which can hold credentials; git_status and get_diff show the changes" }
            if secretFolders.contains(folder) { return "is inside \(folder), a folder for keys and credentials" }
        }
        if name == ".git" { return "is git’s own data, which can hold credentials; git_status and get_diff show the changes" }
        // Every env file the editor knows (.flaskenv too), and .envrc; .env.example is the committed
        // template, as the IDE link has it (IDELink.isSensitive).
        if name != ".env.example", name.hasPrefix(".env") || EnvFile.isEnvFile(named: name) {
            return "is an environment file, which usually holds secrets"
        }
        let ext = (name as NSString).pathExtension
        if secretExtensions.contains(ext) { return "is a key, certificate or secrets file (.\(ext))" }
        if name.hasPrefix("id_"), ext != "pub",
           ext.isEmpty || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(where: { name.hasPrefix($0) }) {
            return "looks like an ssh private key"
        }
        if secretNames.contains(name) || name.hasPrefix("credentials") || name.hasPrefix("secrets.")
            || name.hasPrefix("service-account") || name.hasPrefix("service_account") {
            return "is a credentials file"
        }
        return nil
    }

    // MARK: paths

    /// The real path (symlinks resolved); for a file that does not exist, its folder's real path plus its name.
    static func realPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (realPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}

extension MCPServer {
    /// Whether a decoded JSON value is true or false. Not `value is Bool`: the numbers 1 and 0 from
    /// JSONSerialization pass that test too, and a Bool passes `as? Int`.
    public static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return String(cString: number.objCType) == "c"
    }
}

/// Reads a tool's arguments, refusing values of the wrong type or out of range.
struct MCPArguments {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw MCPToolError("\(key) must be text.") }
        return text
    }

    func int(_ key: String, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let value = values[key], !(value is NSNull) else { return fallback }
        guard !MCPServer.isBoolean(value), let number = value as? Int else { throw MCPToolError("\(key) must be a whole number.") }
        guard range.contains(number) else { throw MCPToolError("\(key) is \(range.lowerBound) to \(range.upperBound).") }
        return number
    }

    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = values[key], !(value is NSNull) else { return fallback }
        guard MCPServer.isBoolean(value), let flag = value as? Bool else { throw MCPToolError("\(key) must be true or false.") }
        return flag
    }

    func choice(_ key: String, of options: [String], default fallback: String) throws -> String {
        guard let text = try string(key) else { return fallback }
        guard options.contains(text) else { throw MCPToolError("\(key) is one of \(options.joined(separator: ", ")).") }
        return text
    }
}

/// The read-only project tools of Next Term's MCP server: read_file, find_in_files, git_status and
/// get_diff. They run off the main thread, given the open projects and the git binary, and answer
/// with model-facing JSON (MCPServer.json) or a tool error.
public enum MCPProjectTools {
    /// Files bigger than this are neither read nor searched (Find in Files' own limit).
    public static let maxFileSize = ProjectSearch.maxFileSize
    /// The most text one answer carries.
    public static let maxChars = 60_000
    /// A longer line is cut.
    public static let maxLineLength = 2_000

    static func run(_ body: () throws -> Any) -> MCPServer.CallResult {
        do {
            return MCPServer.CallResult(text: MCPServer.json(try body()))
        } catch let error as MCPToolError {
            return MCPServer.CallResult(text: error.text, isError: true)
        } catch {
            return MCPServer.CallResult(text: "\(error.localizedDescription)", isError: true)
        }
    }

    static let noGit = MCPToolError("git is not installed (Next Term looks in /opt/homebrew/bin, /usr/local/bin and the developer tools).")

    // MARK: read_file

    public static func readFile(_ arguments: [String: Any], in projects: MCPProjects) -> MCPServer.CallResult {
        run {
            let args = MCPArguments(arguments)
            let offset = try args.int("offset", in: 1...Int.max, default: 1)
            let limit = try args.int("limit", in: 1...2000, default: 400)
            let file = try projects.file(arguments["path"], project: arguments["project"]).get()
            var info = stat()
            guard stat(file.path, &info) == 0 else { throw MCPToolError("Could not read \(file.relative).") }
            guard info.st_size <= maxFileSize else {
                throw MCPToolError("\(file.relative) is \(ByteCountFormatter.string(fromByteCount: Int64(info.st_size), countStyle: .file)); read_file reads files up to 5 MB. find_in_files can still find lines in smaller files.")
            }
            guard let data = FileManager.default.contents(atPath: file.path) else { throw MCPToolError("Could not read \(file.relative).") }
            guard let decoded = TextFile.decode(data) else {
                throw MCPToolError("\(file.relative) is a binary file (or text in an encoding other than UTF-8 or UTF-16); read_file reads text only.")
            }
            let lines = decoded.text.isEmpty ? [] : ProjectSearch.splitLines(decoded.text).map(\.0)
            guard offset == 1 || offset <= lines.count else {
                throw MCPToolError("offset \(offset) is past the end: \(file.relative) has \(lines.count) lines.")
            }
            var taken: [String] = []
            var chars = 0, cutLines = 0
            for line in lines.dropFirst(offset - 1).prefix(limit) {
                var shown = line
                if shown.count > maxLineLength {
                    shown = String(shown.prefix(maxLineLength)) + "…"
                    cutLines += 1
                }
                if !taken.isEmpty, chars + shown.count + 1 > maxChars { break }
                taken.append(shown)
                chars += shown.count + 1
            }
            let redacted = MCPRedaction.redact(taken.joined(separator: "\n"))
            let end = offset - 1 + taken.count
            var result: [String: Any] = ["path": file.relative, "project": file.root, "total_lines": lines.count,
                                         "start_line": taken.isEmpty ? 0 : offset, "end_line": end, "text": redacted.text]
            if end < lines.count { result["next_offset"] = end + 1 }
            if cutLines > 0 { result["long_lines_cut"] = cutLines }
            if redacted.count > 0 { result["redacted"] = redacted.count }
            return result
        }
    }

    // MARK: find_in_files

    public static func findInFiles(_ arguments: [String: Any], in projects: MCPProjects, git: String?,
                                   timeout: TimeInterval = 40) -> MCPServer.CallResult {
        run {
            let args = MCPArguments(arguments)
            guard let text = try args.string("query"), !text.isEmpty else { throw MCPToolError("Give query: the text to find.") }
            guard text.count <= 1000 else { throw MCPToolError("query is at most 1,000 characters.") }
            let limit = try args.int("max_results", in: 1...200, default: 50)
            let masks = (try args.string("glob") ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let isRegex = try args.bool("regex", default: false)
            let matchCase = try args.bool("case_sensitive", default: false)
            let wholeWord = try args.bool("whole_word", default: false)
            let query = SearchQuery(text: text, isRegex: isRegex, matchCase: matchCase, wholeWord: wholeWord, masks: masks)
            do { _ = try query.expression() } catch {
                throw MCPToolError("Not a valid regular expression: \(text)")
            }
            let folder = try projects.project(arguments["project"]).get()

            var secret = 0
            let files = ProjectSearch.files(in: folder, git: git).filter { path in
                let full = (folder as NSString).appendingPathComponent(path)
                guard MCPProjects.secretReason(path) == nil else { secret += 1; return false }
                guard MCPProjects.isLink(full) else { return true }
                // A link is followed only to a file inside an open project, and not to a secret one.
                let real = MCPProjects.realPath(full)
                guard let root = projects.root(holding: real), MCPProjects.secretReason(ProjectFile(root: root, path: real).relative) == nil else {
                    return false
                }
                return true
            }
            let lock = NSLock()
            var found: [FileMatches] = []
            let deadline = Date().addingTimeInterval(timeout)
            try ProjectSearch.search(root: folder, files: files, query: query, isCancelled: { Date() > deadline }) { matches in
                lock.lock()
                found.append(matches)
                lock.unlock()
            }
            let all = found.sorted { $0.relativePath < $1.relativePath }.flatMap(\.matches)
            var redactions = 0
            let shown: [[String: Any]] = all.prefix(limit).map { match in
                let preview = MCPRedaction.redact(snippet(match))
                redactions += preview.count
                return ["path": match.relativePath, "line": match.line, "column": match.range.location + 1, "text": preview.text]
            }
            var result: [String: Any] = ["project": folder, "matches": shown, "total": all.count,
                                         "files": Set(all.map(\.relativePath)).count]
            if all.count > shown.count { result["more"] = "\(all.count - shown.count) more; narrow the query or glob, or raise max_results (up to 200)." }
            if all.count >= ProjectSearch.maxMatches { result["stopped_at"] = ProjectSearch.maxMatches }
            if Date() > deadline { result["timed_out"] = true }
            if secret > 0 { result["secret_files_skipped"] = secret }
            if redactions > 0 { result["redacted"] = redactions }
            return result
        }
    }

    /// A match's line, cut around the match when it is long, with leading indentation dropped.
    static func snippet(_ match: SearchMatch) -> String {
        let ns = match.lineText as NSString
        guard ns.length > 300 else { return match.lineText.trimmingCharacters(in: .whitespaces) }
        let start = max(0, match.range.location - 100)
        let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(300, ns.length - start)))
        return (start > 0 ? "…" : "") + ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            + (NSMaxRange(range) < ns.length ? "…" : "")
    }

    // MARK: git

    /// Paths in the repository, as the project folder sees them: a project inside a bigger repository
    /// sees only its own files.
    struct Scope {
        let gitRoot: String
        let folder: String
        /// `folder` relative to the repository ("" when they are the same).
        var prefix: String { folder == gitRoot ? "" : String(folder.dropFirst(gitRoot.count + 1)) }

        /// A repository path relative to the folder, or nil when it is outside it.
        func relative(_ path: String) -> String? {
            if prefix.isEmpty { return path }
            return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : nil
        }
    }

    static func repository(_ folder: String, git: String) throws -> (GitSnapshot, Scope) {
        guard let snapshot = GitRunner.snapshot(for: folder, git: git) else {
            throw MCPToolError("\(folder) is not in a git repository (or git did not answer in time).")
        }
        let gitRoot = canonicalPath(snapshot.root)
        guard folder == gitRoot || folder.hasPrefix(gitRoot + "/") else { throw MCPToolError("\(folder) is not in a git repository.") }
        return (snapshot, Scope(gitRoot: gitRoot, folder: folder))
    }

    // MARK: git_status

    public static func gitStatus(_ arguments: [String: Any], in projects: MCPProjects, git: String?) -> MCPServer.CallResult {
        run {
            let folder = try projects.project(arguments["project"]).get()
            guard let git else { throw noGit }
            let (snapshot, scope) = try repository(folder, git: git)
            var files: [[String: Any]] = []
            var added = 0, removed = 0
            for (path, change) in snapshot.files where change != .ignored {
                guard let shown = scope.relative(path) else { continue }
                let code = snapshot.codes[path] ?? ".."
                let stats = snapshot.fileStats[path] ?? LineStats()
                var entry: [String: Any] = [
                    "path": shown, "state": String(describing: change),
                    "staged": change != .untracked && code.first != ".",
                    "unstaged": change == .untracked || code.dropFirst().first != ".",
                    "added": stats.added, "removed": stats.removed,
                ]
                if let from = snapshot.renamedFrom[path] { entry["from"] = scope.relative(from) ?? from }
                added += stats.added
                removed += stats.removed
                files.append(entry)
            }
            for (path, change) in snapshot.wholeFolders where change == .untracked {
                guard let shown = scope.relative(path) else { continue }
                files.append(["path": shown + "/", "state": "untracked", "folder": true, "staged": false, "unstaged": true])
            }
            files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            var result: [String: Any] = [
                "project": folder, "branch": snapshot.branch ?? NSNull(), "head": snapshot.head ?? NSNull(),
                "upstream": snapshot.upstream ?? NSNull(), "changed": files.count, "added": added, "removed": removed,
                "files": Array(files.prefix(1000)),
            ]
            if snapshot.branch == nil { result["detached"] = snapshot.head != nil }
            if snapshot.upstream != nil {
                result["ahead"] = snapshot.ahead
                result["behind"] = snapshot.behind
            }
            if files.count > 1000 { result["more"] = "\(files.count - 1000) more files changed." }
            if scope.gitRoot != folder { result["git_root"] = scope.gitRoot }
            return result
        }
    }

    // MARK: get_diff

    public static func getDiff(_ arguments: [String: Any], in projects: MCPProjects, git: String?) -> MCPServer.CallResult {
        run {
            let args = MCPArguments(arguments)
            let which = try args.choice("which", of: ["head", "staged", "unstaged"], default: "head")
            let context = try args.int("context", in: 0...20, default: 3)
            let limit = try args.int("max_chars", in: 1000...200_000, default: maxChars)
            let folder = try projects.project(arguments["project"]).get()
            let path = try args.string("path")
            let file = try path.map { try projects.file($0, project: arguments["project"] ?? folder, mustExist: false).get() }
            guard let git else { throw noGit }
            let (snapshot, scope) = try repository(folder, git: git)
            let base: GitRunner.DiffBase = which == "staged" ? .staged : which == "unstaged" ? .unstaged : .head

            // The repository paths to diff: one file, or everything under the project folder.
            var tracked: [String] = []
            var untracked: [String] = []
            if let file {
                guard file.path.hasPrefix(scope.gitRoot + "/") else { throw MCPToolError("\(path ?? "") is not in \(folder)’s repository.") }
                let inRepo = String(file.path.dropFirst(scope.gitRoot.count + 1))
                let wholeUntracked = snapshot.wholeFolders.contains { $0.value == .untracked && inRepo.hasPrefix($0.key + "/") }
                if snapshot.files[inRepo] == .untracked || wholeUntracked { untracked = [inRepo] } else { tracked = [inRepo] }
            } else {
                tracked = scope.prefix.isEmpty ? [] : [scope.prefix]
                untracked = snapshot.files.filter { $0.value == .untracked && scope.relative($0.key) != nil }.map(\.key).sorted()
            }
            var diffs: [FileDiff] = []
            if file == nil || !tracked.isEmpty {
                guard let found = GitRunner.diffs(in: scope.gitRoot, git: git, base: base, paths: tracked, context: context) else {
                    throw MCPToolError("git could not diff \(path ?? folder).")
                }
                diffs = found
            }
            if base != .staged {
                for path in untracked.prefix(100) {
                    if let diff = GitRunner.diff(of: path, in: scope.gitRoot, git: git, context: context, untracked: true) { diffs.append(diff) }
                }
            }

            var leftOut: [[String: String]] = []
            var shown: [[String: Any]] = []
            var notShown: [String] = []
            var text = ""
            var chars = 0, redactions = 0
            var cut = false
            // A file whose timestamps changed but whose content did not comes back as a bare header.
            diffs.removeAll { $0.hunks.isEmpty && !$0.isBinary && !$0.isRename && $0.header.allSatisfy { $0.hasPrefix("diff --git") || $0.hasPrefix("index ") } }
            for diff in diffs {
                let name = scope.relative(diff.path) ?? diff.path
                if let reason = [diff.newPath, diff.oldPath].compactMap({ $0 }).lazy.compactMap(MCPProjects.secretReason).first {
                    leftOut.append(["path": name, "reason": reason])
                    continue
                }
                guard !cut else { notShown.append(name); continue }
                let rendered = MCPRedaction.redact(UnifiedDiff.render(diff))
                var piece = rendered.text
                if chars + piece.count > limit {
                    guard chars == 0 else { cut = true; notShown.append(name); continue }
                    piece = String(piece.prefix(limit))
                    if let lastLine = piece.lastIndex(of: "\n") { piece = String(piece[...lastLine]) }
                    piece += "… (cut at \(limit) characters)\n"
                    cut = true
                }
                text += piece
                chars += piece.count
                redactions += rendered.count
                var entry: [String: Any] = ["path": name, "added": diff.hunks.reduce(0) { $0 + $1.added },
                                            "removed": diff.hunks.reduce(0) { $0 + $1.removed }]
                if diff.isBinary { entry["binary"] = true }
                if diff.isNew { entry["new"] = true }
                if diff.isDeleted { entry["deleted"] = true }
                if diff.isRename, let old = diff.oldPath { entry["from"] = scope.relative(old) ?? old }
                shown.append(entry)
            }
            if let file, !leftOut.isEmpty { throw MCPProjects.refusal(file.relative, leftOut[0]["reason"] ?? "looks like it holds secrets") }
            var result: [String: Any] = ["project": folder, "which": which, "files": shown, "diff": text]
            if diffs.isEmpty {
                result["note"] = file == nil ? "No \(which == "head" ? "" : which + " ")changes." : "No \(which == "head" ? "" : which + " ")changes in \(path ?? "")."
            }
            if !notShown.isEmpty { result["not_shown"] = notShown; result["more"] = "Cut at max_chars; ask for those files one path at a time." }
            if !leftOut.isEmpty { result["left_out"] = leftOut }
            if untracked.count > 100, base != .staged { result["untracked_not_diffed"] = untracked.count - 100 }
            if redactions > 0 { result["redacted"] = redactions }
            return result
        }
    }
}
