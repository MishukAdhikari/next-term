import Foundation

/// new_tab's rules that need no window: the line it types, and the window a linked worktree's folder opens in.
extension MCPServer {
    /// What new_tab types: `command`, then `prompt` quoted for the shell (ShellQuote), so an agent never quotes the user's
    /// words itself, where `$(…)`, backticks and `$` would run. OpenCode's joined to `--prompt=` (`opencodeLine`).
    public static func commandLine(_ command: String, prompt: String?) -> String {
        guard let prompt, !prompt.isEmpty else { return command }
        let quoted: String = ShellQuote.quote(prompt)
        if let opencode: String = opencodeLine(command, prompt: prompt, quoted: quoted) { return opencode }
        return command + " " + quoted
    }

    /// `command` with `prompt` (`quoted` for the shell) as OpenCode takes a first prompt; nil when it runs no OpenCode.
    /// OpenCode reads a word after its options as the project folder (`opencode 'Fix the login test'` finds no such folder
    /// and exits), and a word after a space that starts with "-" as an option, even where an option's value goes (a list's
    /// "- fix login" is lost, `-v` prints the version and exits). So the prompt goes in as one word: `--prompt='…'`.
    ///
    /// The program is found as CommandClassifier finds it (`parse`, by `program(in:)`): past assignments, `env` and package
    /// runners (`npx opencode-ai@latest`), by the name it knows OpenCode by, in the last simple command, which the prompt
    /// follows. Its words after it, read with AgentCLI.opencode:
    /// - a `--prompt` last, with no value yet: the prompt joins it;
    /// - else a one-shot: `run`, whose message is its words, takes the prompt as one more (after `--` when it starts with
    ///   "-"), and a `--prompt` that has its value is followed by the prompt as typed;
    /// - else `--prompt=` and the prompt.
    static func opencodeLine(_ command: String, prompt: String, quoted: String) -> String? {
        var line: Substring = Substring(command)
        while let last: Character = line.last, last == " " || last == "\t" { line = line.dropLast() }
        guard let simple: String = CommandClassifier.segments(command).last, line.hasSuffix(simple) else { return nil }
        let parsed: (name: String, args: [String]) = CommandClassifier.parse(simple)
        guard AgentCLI.opencode.programs.contains(parsed.name) else { return nil }
        let reading: AgentCLI.Reading = AgentCLI.opencode.read(parsed.args)
        if case .known(let name, _, let option)? = reading.pieces.last, option.kind == .oneShot, AgentCLI.isOption(name) {
            let given: [String] = reading.given.last ?? []
            if given == [name] { return String(line) + "=" + quoted }
            if given == [name + "="] { return String(line) + quoted }
        }
        let oneShot: String? = reading.pieces.lazy.compactMap { (piece: AgentCLI.Piece) -> String? in
            guard case .known(let name, _, let option) = piece, option.kind == .oneShot else { return nil }
            return name
        }.first
        guard let oneShot else { return String(line) + " --prompt=" + quoted }
        let dashed: Bool = !AgentCLI.isOption(oneShot) && prompt.hasPrefix("-") && !parsed.args.contains("--")
        let separator: String = dashed ? " -- " : " "
        return String(line) + separator + quoted
    }

    /// When `directory` is in a linked worktree that sits inside `owner`, the project of an open window (a worktree in
    /// its .claude/worktrees): that worktree, which new_tab opens in a window of its own, titled "repo ▸ folder", as Open
    /// Worktree does. nil: the owner's window it is.
    public static func ownWorktree(of directory: String, inside owner: String) -> String? {
        let root = canonicalPath(ProjectRoot.find(from: directory)), owner = canonicalPath(owner)
        guard root.hasPrefix(owner + "/"), WorktreeWindow.repository(ofLinkedWorktree: root) != nil else { return nil }
        return root
    }
}
