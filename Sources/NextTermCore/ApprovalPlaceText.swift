import Foundation

/// The words an approval panel uses for where a request comes from: the line under its heading that names the project
/// (and the linked worktree with its branch), the In row's path, and Remember's reach and how Always could be offered.
/// Presentation only: what a choice allows is decided elsewhere.
public enum ApprovalPlaceText {
    /// "coding-sessions", or "coding-sessions · worktree fix-login (branch fix-login)" in a linked worktree. `project` is
    /// the main checkout's folder, `worktree` the linked worktree's; nil when neither is known.
    public static func origin(project: String?, worktree: String?, branch: String?) -> String? {
        let name: (String) -> String = { ($0 as NSString).lastPathComponent }
        guard let project, !name(project).isEmpty else { return worktree.map { "worktree " + name($0) + branchText(branch) } }
        guard let worktree, worktree != project else { return name(project) }
        return name(project) + " \u{00B7} worktree " + name(worktree) + branchText(branch)
    }

    private static func branchText(_ branch: String?) -> String {
        guard let branch, !branch.isEmpty else { return "" }
        return " (branch \(branch))"
    }

    /// The In row: "project root" or "worktree root" when the folder is that root, else the whole path with `~` for home.
    public static func folder(_ folder: String, project: String?, worktree: String?, home: String = NSHomeDirectory()) -> String {
        let trimmed: (String) -> String = { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        if let worktree, trimmed(worktree) == trimmed(folder) { return "worktree root" }
        if let project, trimmed(project) == trimmed(folder) { return "project root" }
        return RecentProjects.abbreviate(trimmed(folder), home: trimmed(home))
    }

    /// The branch a worktree has checked out, read from its HEAD (`.git` a folder, or a file naming the git folder); nil
    /// for a detached HEAD or when it can't be read. No git process: the panel asks for it while it builds.
    public static func branch(of worktree: String) -> String? {
        let dotGit = (worktree as NSString).appendingPathComponent(".git")
        var gitDir = dotGit
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return nil }
        if !isFolder.boolValue {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
            let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = named.hasPrefix("/") ? named : (worktree as NSString).appendingPathComponent(named)
        }
        guard let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("ref: refs/heads/") else { return nil }
        return String(ref.dropFirst("ref: refs/heads/".count))
    }

    /// Beside Remember: the longest choice it offers, so a lasting one is seen without opening the pop-up. Nil with one
    /// choice.
    public static func reach(_ titles: [String]) -> String? {
        guard titles.count > 1, let last = titles.last else { return nil }
        return "Up to: \(last)"
    }

    /// One short note under Remember, from what used to be separate lines: why only Allow once is offered, why Always
    /// isn't, and how it could be.
    public static func rememberNote(_ parts: [String?], refusal: String?) -> String? {
        var lines = parts.compactMap { $0 }.filter { !$0.isEmpty }
        if let refusal, !refusal.isEmpty {
            lines.append(refusal)
            if let how = howToGetAlways(refusal) { lines.append(how) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// How the agent could ask in a way Always is offered for, when the reason has a plain way around it.
    public static func howToGetAlways(_ refusal: String) -> String? {
        if refusal == SecretAlwaysRules.shellSyntaxRefusal {
            return "To allow it every time, the agent can run it as one plain command, without pipes, $(\u{2026}), redirections or globs."
        }
        return nil
    }
}
