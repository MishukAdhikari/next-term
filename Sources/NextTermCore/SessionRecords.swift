import Foundation

/// What one look at a session record found: the folder it names last, and the writes of the lines written since
/// the look before.
public struct RecordRead: Equatable, Sendable {
    public let folder: RecordedFolder?
    public let writes: [DatedWrite]

    public init(folder: RecordedFolder?, writes: [DatedWrite] = []) {
        self.folder = folder
        self.writes = writes
    }
}

/// The session records of running agents, followed as they grow, for the folder each names last and the places
/// it writes to. The first look at a record (or at one replaced) reads its last 1 MB forward; each later look
/// reads only what was written since, once, and keeps the folder named before when the new lines name none (a
/// long tool result, a turn's output). A record unchanged since the last look is not read at all, nor is Claude
/// Code's session file or Copilot CLI's workspace. One owner: not for use from two threads.
public struct SessionRecords {
    private struct Followed {
        let file: RecordFile
        /// Where its last whole line ended at the last look: the next look reads from there.
        let end: UInt64
        let found: RecordedFolder?
        /// The folder its relative paths start from, as of that line.
        let cwd: String?
    }

    private var followed: [String: Followed] = [:]
    private var claudeSessions: [String: (file: RecordFile, session: (id: String, started: String?)?)] = [:]
    /// Copilot CLI's session folder for each process, and its workspace as last read.
    private var copilotSessions: [String: String] = [:]
    private var workspaces: [String: (file: RecordFile, found: RecordedFolder?)] = [:]
    /// Past this many records, sessions long ended are forgotten (the rest are read once more).
    private let limit = 64

    public init() {}

    /// The folder the record at `path` names last.
    public mutating func folder(_ path: String, kind: AgentLocation.RecordKind) -> RecordedFolder? {
        follow(path, kind: kind).folder
    }

    /// The folder the record at `path` names last, and the writes of the lines written since the last look: one
    /// read of what is new.
    public mutating func follow(_ path: String, kind: AgentLocation.RecordKind) -> RecordRead {
        guard let file = RecordFile(path) else {
            followed[path] = nil
            return RecordRead(folder: nil)
        }
        let known = followed[path]
        if let known, known.file == file { return RecordRead(folder: known.found) }
        // Grown in place: only what was written after its last whole line. New, replaced or cut: its last 1 MB.
        let grown = known.flatMap { $0.file.id == file.id && $0.file.size <= file.size ? $0 : nil }
        let read = AgentLocation.readForward(path, kind: kind, from: grown?.end, size: file.size, modified: file.modified, cwd: grown?.cwd)
        let found = read.found ?? grown?.found
        if followed.count >= limit { followed.removeAll() }
        followed[path] = Followed(file: file, end: read.end ?? grown?.end ?? 0, found: found, cwd: read.cwd)
        return RecordRead(folder: found, writes: read.writes)
    }

    /// The session the `claude` with process `pid` has open (AgentLocation.claudeSession), read again only
    /// when ~/.claude/sessions/<pid>.json changes.
    public mutating func claudeSession(pid: Int32, home: String) -> (id: String, started: String?)? {
        let path = (home as NSString).appendingPathComponent(".claude/sessions/\(pid).json")
        guard let file = RecordFile(path) else {
            claudeSessions[path] = nil
            return nil
        }
        if let known = claudeSessions[path], known.file == file { return known.session }
        let session = AgentLocation.claudeSession(pid: pid, home: home)
        if claudeSessions.count >= limit { claudeSessions.removeAll() }
        claudeSessions[path] = (file, session)
        return session
    }

    /// The folder Copilot CLI's workspace names for the `copilot` with process `pid`
    /// (AgentLocation.copilotFolder): its session folder kept while its lock is there, the workspace read
    /// again only when it changes.
    public mutating func copilotFolder(pid: Int32, home: String) -> RecordedFolder? {
        let key = "\(pid) \(home)"
        var session = copilotSessions[key]
        if let known = session, !FileManager.default.fileExists(atPath: known + "/inuse.\(pid).lock") { session = nil }
        if session == nil { session = AgentLocation.copilotSession(pid: pid, home: home) }
        if copilotSessions.count >= limit { copilotSessions.removeAll() }
        copilotSessions[key] = session
        guard let session, let file = RecordFile(session + "/workspace.yaml") else { return nil }
        if let known = workspaces[session], known.file == file { return known.found }
        let found = AgentLocation.copilotFolder(session: session)
        if workspaces.count >= limit { workspaces.removeAll() }
        workspaces[session] = (file, found)
        return found
    }
}

/// A record file as it is now: which file it is (another one once it is replaced), how long, and when it was
/// last written.
struct RecordFile: Equatable {
    let id: UInt64
    let size: UInt64
    let modified: Date

    /// nil unless `path` is a regular file.
    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        id = UInt64(info.st_ino)
        size = UInt64(info.st_size)
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        modified = Date(timeIntervalSince1970: seconds)
    }
}
