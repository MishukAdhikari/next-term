import Foundation

/// Stage, unstage or revert one hunk, safely while agents work in the same repository.
///
/// `git apply` places a stale hunk at an offset rather than failing, so each operation first checks
/// that the side it applies to is exactly what the diff was made from (full blob ids): if anything
/// changed since, nothing is touched and the caller re-diffs.
public enum HunkOps {
    public enum Action: Sendable {
        /// Unstaged hunk into the index. Use a diff made with base `.unstaged`.
        case stage
        /// Staged hunk out of the index. Use a diff made with base `.staged`.
        case unstage
        /// Undo the hunk in the working tree. Use a diff made with base `.unstaged` or `.head`.
        case revert
    }

    public enum Outcome: Equatable, Sendable {
        case done
        /// The index or file changed since the diff was made: diff again.
        case changedSinceDiff
        /// Another git process holds .git/index.lock (an agent committing): try again in a moment.
        case gitBusy
        case failed
    }

    static let noBlob = String(repeating: "0", count: 40)

    public static func perform(_ action: Action, hunk: DiffHunk, in file: FileDiff, root: String, git: String) -> Outcome {
        let path = file.path
        switch action {
        case .stage:
            // The diff's old side is the index entry (diff-files).
            guard let old = file.oldBlob, indexBlob(of: path, root: root, git: git) == nonZero(old) else { return .changedSinceDiff }
        case .unstage:
            // The diff's new side is the index entry (diff-index --cached).
            guard let new = file.newBlob, indexBlob(of: path, root: root, git: git) == nonZero(new) else { return .changedSinceDiff }
        case .revert:
            // The diff's new side is the working file.
            guard let new = file.newBlob, workingBlob(of: path, root: root, git: git) == nonZero(new) else { return .changedSinceDiff }
        }
        let cached = action != .revert
        if cached, FileManager.default.fileExists(atPath: gitDirectory(root: root, git: git) + "/index.lock") { return .gitBusy }
        let ok = GitRunner.apply(UnifiedDiff.patch(for: hunk, in: file), in: root, git: git, cached: cached, reverse: action != .stage)
        return ok ? .done : .failed
    }

    /// nil for the all-zeros "no such blob".
    private static func nonZero(_ blob: String) -> String? {
        blob.allSatisfy { $0 == "0" } ? nil : blob
    }

    /// The blob staged for `path`, or nil if it is not in the index.
    static func indexBlob(of path: String, root: String, git: String) -> String? {
        output(git, ["-C", root, "rev-parse", "-q", "--verify", ":" + path])
    }

    /// The blob the working file would be stored as (clean filters and line-ending rules applied).
    static func workingBlob(of path: String, root: String, git: String) -> String? {
        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(path).path) else { return nil }
        return output(git, ["-C", root, "hash-object", "--", path])
    }

    static func gitDirectory(root: String, git: String) -> String {
        let dir = output(git, ["-C", root, "rev-parse", "--git-dir"]) ?? ".git"
        return dir.hasPrefix("/") ? dir : URL(fileURLWithPath: root).appendingPathComponent(dir).path
    }

    private static func output(_ git: String, _ args: [String]) -> String? {
        GitRunner.run(git, args, timeout: 10)
            .flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
