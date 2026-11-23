import Foundation

/// One thing an agent's transcript line says it did to a place on disk.
public struct WriteSignal: Equatable, Sendable {
    public enum Kind: Sendable {
        /// A file written or edited.
        case file
        /// A shell command run in a folder, or a `cd` into it, or a git command that changes it.
        case shell
        /// A worktree made (`git worktree add`).
        case created
    }

    /// An absolute, standardised path.
    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// A signal with the time its transcript line was written: what came before this version first ran is the
/// baseline, and a line read again is no new signal.
public struct DatedWrite: Equatable, Sendable {
    public let signal: WriteSignal
    public let at: Date

    public init(signal: WriteSignal, at: Date) {
        self.signal = signal
        self.at = at
    }
}

/// Which places an agent writes to, read from one line of its transcript.
///
/// Tools are matched by name, never by an argument called `path`: an MCP tool or a search carries one too, and a
/// look is not a write. A command only counts when it moves into a folder, changes a repository there, or makes a
/// worktree, so `gh issue view 11650` and `git -C other diff` say nothing. Subagents' lines are not the agent's.
public enum AgentWrites {
    /// The signals in one transcript line's bytes; none when it is not a JSON object.
    public static func signals(line: Data, agent: LiveChat.Agent, cwd: String?) -> [WriteSignal] {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        return signals(record: record, agent: agent, cwd: cwd)
    }

    /// The signals in one parsed transcript line. `cwd` is the folder the agent's calls run in, which relative
    /// paths start from; a relative path with none is left out.
    public static func signals(record: [String: Any], agent: LiveChat.Agent, cwd: String?) -> [WriteSignal] {
        if record["isSidechain"] as? Bool == true { return [] }
        switch agent {
        case .claude:
            guard record["type"] as? String == "assistant" else { return [] }
            return anthropicBlocks(record["message"], cwd: cwd)
        case .commandCode:
            guard record["type"] as? String == "message" else { return [] }
            return anthropicBlocks(record["message"], cwd: cwd)
        case .codex:
            guard record["type"] as? String == "response_item", let payload = record["payload"] as? [String: Any] else { return [] }
            return codexItem(payload, cwd: cwd)
        }
    }

    // MARK: Claude Code and Command Code

    /// Their assistant messages hold Anthropic's content blocks.
    private static func anthropicBlocks(_ message: Any?, cwd: String?) -> [WriteSignal] {
        guard let message = message as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.flatMap { block -> [WriteSignal] in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
                  let input = block["input"] as? [String: Any] else { return [] }
            switch name {
            case "Write", "Edit", "MultiEdit", "NotebookEdit", "write_file", "edit_file":
                guard let path = (input["file_path"] ?? input["notebook_path"]) as? String,
                      let resolved = resolve(path, from: cwd) else { return [] }
                return [WriteSignal(path: resolved, kind: .file)]
            case "Bash", "shell_command":
                guard let command = input["command"] as? String else { return [] }
                return shellCall(command, folder: (input["cwd"] ?? input["workdir"]) as? String, cwd: cwd)
            default:
                return []
            }
        }
    }

    // MARK: Codex

    private static func codexItem(_ item: [String: Any], cwd: String?) -> [WriteSignal] {
        switch item["type"] as? String {
        case "function_call":
            let arguments = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
            let workdir = arguments["workdir"] as? String
            if item["name"] as? String == "apply_patch" {
                let base = workdir.flatMap { resolve($0, from: cwd) } ?? cwd
                let patch = (arguments["input"] ?? arguments["patch"]) as? String ?? ""
                return patchFiles(patch).compactMap { resolve($0, from: base) }.map { WriteSignal(path: $0, kind: .file) }
            }
            let command = (arguments["cmd"] ?? arguments["command"]).flatMap(commandText) ?? ""
            return shellCall(command, folder: workdir, cwd: cwd)
        case "local_shell_call":
            let action = item["action"] as? [String: Any] ?? [:]
            return shellCall(commandText(action["command"]) ?? "", folder: (action["working_directory"] ?? action["workdir"]) as? String, cwd: cwd)
        case "custom_tool_call":
            let input = item["input"] as? String ?? ""
            switch item["name"] as? String {
            case "apply_patch":
                return patchFiles(input).compactMap { resolve($0, from: cwd) }.map { WriteSignal(path: $0, kind: .file) }
            case "exec":
                return codeModeExec(input, cwd: cwd)
            default:
                return []
            }
        default:
            return []
        }
    }

    /// A command given as one string, or as an argv list (`["bash", "-lc", "cd /wt && ls"]`, where the script is the
    /// command).
    private static func commandText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        guard let words = value as? [String], !words.isEmpty else { return nil }
        if words.count == 3, ["bash", "zsh", "sh"].contains((words[0] as NSString).lastPathComponent), words[1].hasSuffix("c") {
            return words[2]
        }
        return words.joined(separator: " ")
    }

    /// Current Codex runs every tool through one `exec` call whose input is JavaScript: `tools.exec_command({cmd, workdir})`
    /// and `tools.apply_patch("*** Begin Patch\n...")`. Nothing runs these here, so the folders, commands and patch
    /// headers are read out of the text, each exec_command with its own workdir.
    private static func codeModeExec(_ source: String, cwd: String?) -> [WriteSignal] {
        var signals: [WriteSignal] = []
        let calls = source.components(separatedBy: "exec_command(").dropFirst()
        var firstWorkdir: String?
        for call in calls {
            let workdir = firstMatch(workdirPattern, in: call).flatMap { resolve($0, from: cwd) }
            if firstWorkdir == nil { firstWorkdir = workdir }
            let command = firstMatch(cmdPattern, in: call).map(unescapeJavaScript) ?? ""
            signals += shellCall(command, folder: workdir, cwd: cwd)
        }
        let base = firstWorkdir ?? cwd
        signals += patchFiles(source).compactMap { resolve($0, from: base) }.map { WriteSignal(path: $0, kind: .file) }
        return signals
    }

    /// `workdir: "/x"`, `"workdir": '/x'`
    private static let workdirPattern = regex(#"["']?workdir["']?\s*:\s*["'`]([^"'`]+)["'`]"#)
    /// `cmd: "git status"`: a JavaScript string, with its escapes.
    private static let cmdPattern = regex(#"["']?cmd["']?\s*:\s*"((?:[^"\\]|\\.)*)""#)
    /// The files an apply_patch names, in a real patch (newlines) or in JavaScript source (a `\n` escape ends the name).
    private static let patchHeaderPattern = regex(#"\*\*\* (?:Add File|Update File|Delete File|Move to): ([^\\\n"'`]+)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func patchFiles(_ text: String) -> [String] {
        allMatches(patchHeaderPattern, in: text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func firstMatch(_ expression: NSRegularExpression?, in text: String) -> String? {
        allMatches(expression, in: text).first
    }

    /// Each match's first capture group.
    private static func allMatches(_ expression: NSRegularExpression?, in text: String) -> [String] {
        guard let expression else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func unescapeJavaScript(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: Shell

    /// What a shell call writes: its own folder (a Command Code `cwd`, a Codex `workdir`), then each command in it.
    private static func shellCall(_ command: String, folder: String?, cwd: String?) -> [WriteSignal] {
        var signals: [WriteSignal] = []
        var base = cwd
        if let folder, let resolved = resolve(folder, from: cwd) {
            signals.append(WriteSignal(path: resolved, kind: .shell))
            base = resolved
        }
        return signals + shellSignals(command, from: base)
    }

    /// The signals in a command line, which runs its commands in turn from `start`: a `cd` moves where the next
    /// ones run, and relative folders start from there.
    static func shellSignals(_ commandLine: String, from start: String?) -> [WriteSignal] {
        var signals: [WriteSignal] = []
        var current = start
        for segment in CommandClassifier.segments(commandLine) {
            let words = CommandClassifier.words(segment)
            guard let found = CommandClassifier.program(in: words) else { continue }
            let args = Array(words[(found.index + 1)...])
            switch found.name {
            case "cd":
                // `cd -` goes to a place only the shell knows, and so does a variable.
                guard let target = args.first(where: { !$0.hasPrefix("-") }), !args.contains("-"),
                      !target.contains("$"), !target.contains("`"), let resolved = resolve(target, from: current) else { continue }
                signals.append(WriteSignal(path: resolved, kind: .shell))
                current = resolved
            case "git":
                signals += git(args, from: current)
            default:
                continue
            }
        }
        return signals
    }

    /// Git subcommands that change the files, the index or HEAD of the repository they run in.
    private static let mutating: Set<String> = [
        "commit", "add", "switch", "checkout", "reset", "merge", "rebase", "stash", "apply", "am", "rm", "mv",
        "restore", "cherry-pick", "revert", "pull", "clean",
    ]

    /// A git command's signals: the folder it runs in (`-C` options, each relative to the last) when it changes
    /// something, or the folder of a worktree it adds.
    private static func git(_ args: [String], from start: String?) -> [WriteSignal] {
        var folder = start
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            if args[index] == "-C", index + 1 < args.count {
                folder = resolve(args[index + 1], from: folder)
                index += 2
            } else {
                index += args[index] == "-c" ? 2 : 1
            }
        }
        guard index < args.count else { return [] }
        let rest = Array(args[(index + 1)...])
        if args[index] == "worktree" {
            guard rest.first == "add" else { return [] }
            // The folder is the first word that isn't an option or an option's value.
            var words = rest.dropFirst()
            var path: String?
            while let word = words.first {
                words = words.dropFirst()
                if word == "-b" || word == "-B" || word == "--reason" { words = words.dropFirst(); continue }
                if word.hasPrefix("-") { continue }
                path = word
                break
            }
            guard let path, let resolved = resolve(path, from: folder) else { return [] }
            return [WriteSignal(path: resolved, kind: .created)]
        }
        guard mutating.contains(args[index]), let folder else { return [] }
        return [WriteSignal(path: folder, kind: .shell)]
    }

    // MARK: Paths

    /// An absolute, standardised path: `~` is the home folder, a relative one starts from `base`. Nil when it is
    /// relative and there is nowhere to start from.
    private static func resolve(_ path: String, from base: String?) -> String? {
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardized.path }
        guard let base else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardized.path
    }
}
