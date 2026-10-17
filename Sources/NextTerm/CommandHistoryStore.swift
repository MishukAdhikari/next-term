import Foundation
import NextTermCore

/// The app's one record of your commands (CommandHistory), for suggestions while typing, kept in History.noindex
/// (CommandHistoryFolder): Next Term's own folder in Application Support, the relaunch harness's in its runs, or a temporary
/// folder of the plain self-test's own (SelfTest.historyFolder), so a self-test never reads or writes yours.
///
/// What it holds is touched on one serial queue at user-interactive QoS: the load (lazily, at the first request), queries
/// and records. The log's appends and compactions go on a queue of their own, so a query never waits on the disk. A
/// compaction works on a copy; what another copy of Next Term appended meanwhile is merged back in once it is written.
final class CommandHistoryStore: @unchecked Sendable {
    static let shared = CommandHistoryStore(folder: SelfTest.historyFolder.map { CommandHistoryFolder(support: $0) })

    /// A log under this size is never worth compacting.
    static let smallLog = 1 << 20

    private let folder: CommandHistoryFolder?
    private let queue = DispatchQueue(label: "nextterm.history", qos: .userInteractive)
    private let files = DispatchQueue(label: "nextterm.history.files", qos: .utility)

    // On `queue`:
    private var history = CommandHistory()
    private var loaded = false
    /// Lines of the shell's own history you forgot, by their hash: never suggested again.
    private var forgotten: Set<String> = []
    /// Lines forgotten since the last compaction: one merged back from the log stays forgotten.
    private var forgottenSince: Set<String> = []
    /// Each folder's repository (its common git folder; "" for none), as asked.
    private var repositories: [String: String] = [:]

    // On `files`:
    /// The folder and repository ids the log names already.
    private var named: Set<String> = []
    /// The log may be written: it was read whole, or there was none, and it is this version's.
    private var writable = false
    private var compactedSize = 0
    private var compacting = false

    /// Why the folder can't be used this launch, for Settings; on the main queue.
    private(set) var problem: String?

    init(folder: CommandHistoryFolder?) {
        self.folder = folder
    }

    #if DEBUG
    /// The folder, for the self-test: it checks the record it clears is its own.
    var folderURL: URL? { folder?.url }
    #endif

    // MARK: asking

    /// The newest lines you ran that start with `prefix` (CommandHistory.query), asked from `folder`, to `reply` on the main
    /// queue.
    func query(prefix: String, folder: String?, limit: Int = CommandHistory.queryLimit, reply: @escaping ([CommandHistory.Entry]) -> Void) {
        queue.async {
            self.loadIfNeeded()
            let repo = folder.flatMap { self.repository(of: $0) }
            let found = self.history.query(prefix: prefix, folder: folder, repo: repo, limit: limit)
            DispatchQueue.main.async { reply(found) }
        }
    }

    /// How many commands are kept, to `reply` on the main queue.
    func count(reply: @escaping (Int) -> Void) {
        queue.async {
            self.loadIfNeeded()
            let count = self.history.count
            DispatchQueue.main.async { reply(count) }
        }
    }

    /// Whether `line` of the shell's own history was forgotten, to `reply` on the main queue.
    func isForgotten(_ line: String, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.loadIfNeeded()
            let gone = self.forgotten.contains(CommandHistoryFile.hash(of: line))
            DispatchQueue.main.async { reply(gone) }
        }
    }

    // MARK: changing

    /// A run of yours of `line` in `folder` that started `at`, with its exit (nil: it never said, as when its tab closed),
    /// right after `previous` in the same tab (your command before it there, if no other came between). Kept only when
    /// CommandHistory keeps the line; the log gets its state, and `previous`'s when what follows it changed.
    func record(_ line: String, folder: String, at date: Date, exit: Int32?, after previous: String? = nil) {
        queue.async {
            self.loadIfNeeded()
            let repo = self.repository(of: folder)
            let time = Self.milliseconds(date)
            guard let made = self.history.record(line, folder: folder, repo: repo, at: time) else { return }
            if let exit { self.history.ended(made.line, exit: exit) }
            self.forgottenSince.remove(made.line)
            var changed = [made.line]
            if let previous, let before = self.history.entry(for: previous) {
                self.history.followed(previous: before.line, by: made.line, at: time)
                let followed = self.history.entry(for: before.line)?.followed
                if followed != before.followed, before.line != made.line { changed.append(before.line) }
            }
            let entries = changed.compactMap { self.history.entry(for: $0) }
            self.append { (named: inout Set<String>) -> Data in
                var out = Data()
                for entry in entries { out += CommandHistoryFile.entryLines(entry, named: &named) }
                return out
            }
        }
    }

    /// The command the record is sure follows `line` (CommandHistory.next), with what is known of it, to `reply` on the
    /// main queue.
    func next(after line: String, reply: @escaping (CommandHistory.Entry?) -> Void) {
        queue.async {
            self.loadIfNeeded()
            let next = self.history.next(after: line).flatMap { self.history.entry(for: $0) }
            DispatchQueue.main.async { reply(next) }
        }
    }

    /// `line` is gone from the record, and from the log at once (a compaction).
    func forget(_ line: String) {
        queue.async {
            self.loadIfNeeded()
            guard self.history.entry(for: line) != nil else { return }
            self.history.forget(line)
            self.forgottenSince.insert(line)
            self.compactSoon()
        }
    }

    /// A line of the shell's own history you forgot: never suggested again. Only its hash is kept.
    func forgetFallback(_ line: String) {
        queue.async {
            self.loadIfNeeded()
            guard self.forgotten.count < CommandHistoryFile.maxForgotten else { return }
            let hash = CommandHistoryFile.hash(of: line)
            guard self.forgotten.insert(hash).inserted else { return }
            self.append { (_: inout Set<String>) -> Data in CommandHistoryFile.forgottenLine(hash) }
        }
    }

    /// Everything gone: the record, the forgotten lines and the log. `then` on the main queue.
    func clear(then: @escaping () -> Void) {
        queue.async {
            self.loadIfNeeded()
            self.history.clear()
            self.forgotten = []
            self.forgottenSince = []
            self.files.async {
                if let folder = self.folder, self.writable {
                    do { try folder.clear() } catch { self.failed(error, while: "clearing") }
                }
                self.named = []
                self.compactedSize = 0
                DispatchQueue.main.async(execute: then)
            }
        }
    }

    // MARK: the log

    /// The log, read once, at the first request: a log another version wrote, or one that can't be read, leaves the record
    /// empty for this launch and is left as it is.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let folder else { return }
        do {
            try folder.ensure()
            let read = try folder.read()
            let contents = CommandHistoryFile.decode(read?.data ?? Data())
            if contents.otherVersion {
                return failed(nil, while: "reading", note: "Next Term’s history file is another version’s, so Next Term doesn’t use it.")
            }
            history = contents.history
            forgotten = contents.forgotten
            let size = read?.data.count ?? 0
            let whole = read?.whole ?? true
            let worthCompacting = whole && size > Self.smallLog && contents.runs > 2 * max(1, history.count)
            files.async {
                self.named = contents.named
                self.writable = whole
                self.compactedSize = size
            }
            if worthCompacting { compactSoon() }
        } catch {
            failed(error, while: "reading")
        }
    }

    /// One run's lines (or a forgotten line), made on the files queue against the ids the log names (`named`) and
    /// appended; past twice the compacted size (1 MB at least) or 32 MB, a compaction.
    private func append(_ lines: @escaping (inout Set<String>) -> Data) {
        files.async {
            guard self.writable, let folder = self.folder else { return }
            var named = self.named
            do {
                try folder.append(lines(&named))
                self.named = named
            } catch {
                return self.failed(error, while: "writing")
            }
            let size = folder.size
            if size > CommandHistoryFile.compactAt || size > max(2 * self.compactedSize, Self.smallLog) {
                self.queue.async { self.compactSoon() }
            }
        }
    }

    /// Compacts the log from a copy of the record (on `queue`): the copy is merged with what the log holds now, written, and
    /// what another copy of Next Term added is merged back into the record.
    private func compactSoon() {
        let snapshot = history, forgottenNow = forgotten, dropping = forgottenSince
        files.async {
            guard self.writable, !self.compacting, let folder = self.folder else { return }
            self.compacting = true
            defer { self.compacting = false }
            var written: (history: CommandHistory, forgotten: Set<String>, news: Bool)?
            var named: Set<String> = []
            do {
                let data = try folder.compact { (current: Data?) -> Data? in
                    let log = CommandHistoryFile.decode(current ?? Data())
                    guard !log.otherVersion else { return nil }
                    let merged = CommandHistoryFile.merge(snapshot, log.history, dropping: dropping)
                    let allForgotten = forgottenNow.union(log.forgotten)
                    written = (merged, allForgotten, CommandHistoryFile.hasNews(log.history, for: snapshot))
                    return CommandHistoryFile.encode(merged, forgotten: allForgotten, named: &named)
                }
                guard let data, let written else { return }
                self.named = named
                self.compactedSize = data.count
                self.queue.async { self.compacted(written, dropping: dropping) }
            } catch {
                self.failed(error, while: "compacting")
            }
        }
    }

    /// After a compaction (on `queue`): what another copy of Next Term ran is merged into the record, and the lines it
    /// dropped are no longer waiting for one.
    private func compacted(_ written: (history: CommandHistory, forgotten: Set<String>, news: Bool), dropping: Set<String>) {
        forgotten.formUnion(written.forgotten)
        if written.news { history = CommandHistoryFile.merge(history, written.history, dropping: forgottenSince) }
        forgottenSince.subtract(dropping)
    }

    /// A read or write refused or failed: noted in the log, and said in Settings (`problem`). A refused folder or file is
    /// never written to again this launch.
    private func failed(_ error: Error?, while doing: String, note: String? = nil) {
        let text = note ?? (error as? LocalizedError)?.errorDescription ?? error.map { "\($0)" } ?? "unknown"
        NSLog("Next Term: command history: \(doing): \(text)")
        files.async { self.writable = false }
        DispatchQueue.main.async { self.problem = text }
    }

    // MARK: places

    /// The repository `folder` is in: its common git folder, so a repository's worktrees share it (GitRunner.commonGitDir), read
    /// once a folder.
    private func repository(of folder: String) -> String? {
        if let known = repositories[folder] { return known.isEmpty ? nil : known }
        if repositories.count >= CommandHistory.maxFolders { repositories = [:] }
        let repo = GitRunner.commonGitDir(root: ProjectRoot.find(from: folder)).map(canonicalPath)
        repositories[folder] = repo ?? ""
        return repo
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}
