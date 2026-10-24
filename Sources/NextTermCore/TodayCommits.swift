import Foundation

/// The user's own commits since local midnight, for Post Update: git runs once, read-only, in the project's main
/// checkout with every branch and worktree, and only for the email git has for the user there. With no email there
/// are no commit lines, never every author's, since others' work would land in the user's update. Subjects are masked
/// before anything holds them, and nothing read is logged.
public enum TodayCommits {
    /// The most subjects git is asked for.
    public static let asked = 200
    /// The most subjects the draft lists; the rest are counted.
    public static let shown = 30

    /// What reading gave.
    public enum Outcome: Equatable, Sendable {
        case subjects([String])
        /// git has no user.email in this project.
        case noEmail
        case notRepository
        /// No git binary on this Mac.
        case noGit
        /// git ran and failed, or took too long.
        case failed

        public var subjects: [String] {
            if case .subjects(let subjects) = self { return subjects }
            return []
        }

        /// Why there are no commit lines, as the sheet says it; nil when git answered.
        public var reason: String? {
            switch self {
            case .subjects: return nil
            case .noEmail: return "No commits: git has no user.email in this project."
            case .notRepository: return "No commits: this project isn’t a git repository."
            case .noGit: return "No commits: git isn’t installed on this Mac."
            case .failed: return "No commits: git couldn’t read this project’s history."
            }
        }
    }

    /// `git log`'s arguments for `email`'s commits since `since`, in every branch, worktree and remote, a stash or a
    /// note left out; nil with no usable email. The time is written with its offset, so git reads the user's midnight.
    public static func arguments(since: Date, email: String?, timeZone: TimeZone = .current) -> [String]? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty,
              !email.hasPrefix("-"), !HandoffRequest.hasControl(email) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        let time = formatter.string(from: since)
        // An exclude applies to the --all after it.
        let refs: [String] = ["--exclude=refs/stash", "--exclude=refs/notes/*", "--all"]
        // The whole address in its angle brackets, so olddev@example.com or dev@example.com.au (someone else) never
        // matches; in any letter case, as mail addresses are written.
        let author: String = "--author=<" + email + ">"
        let match: [String] = [author, "--fixed-strings", "--regexp-ignore-case"]
        let limits: [String] = ["--no-merges", "--since=" + time] + match
        let shape: [String] = ["--format=%s", "-n", String(asked)]
        return ["log"] + refs + limits + shape
    }

    /// git's output as subjects: each masked and trimmed, empty ones and exact repeats (a cherry-pick from one worktree
    /// to another) left out, the first `shown` kept and "and N more" added for the rest.
    public static func parse(_ output: String, mask: (String) -> String) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let subject = mask(String(line)).trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty, seen.insert(subject).inserted else { continue }
            kept.append(subject)
        }
        guard kept.count > shown else { return kept }
        let more = kept.count - shown
        return Array(kept.prefix(shown)) + ["and \(more) more"]
    }

    /// Today's commits for `project`, read in its main checkout (a linked worktree's main checkout, so every worktree
    /// counts once whichever one the window shows). Blocks while git runs: call it off the main thread.
    public static func read(project: String, git: String?, now: Date, calendar: Calendar = .current,
                            mask: (String) -> String) -> Outcome {
        guard let git else { return .noGit }
        let root = TodoFolder.projectRoot(project)
        let base: [String] = ["-C", root, "--no-optional-locks"]
        guard GitRunner.run(git, base + ["rev-parse", "--git-dir"], timeout: 10) != nil else { return .notRepository }
        // `config` exits 1 when the key is not set: no email.
        let emailData = GitRunner.run(git, base + ["config", "--get", "user.email"], timeout: 10)
        let email = emailData.flatMap { String(data: $0, encoding: .utf8) }
        let since = calendar.startOfDay(for: now)
        let planned: [String]? = arguments(since: since, email: email, timeZone: calendar.timeZone)
        guard let arguments = planned else { return .noEmail }
        guard let output = GitRunner.run(git, base + arguments, timeout: 15) else { return .failed }
        return .subjects(parse(String(decoding: output, as: UTF8.self), mask: mask))
    }
}
