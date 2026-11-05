import Foundation

/// Which of the MCP hub's servers apply to an agent working in a folder: the user's list (`userPath`) and the
/// projects' lists, found as the skills library finds a project's skills (SkillLibrary.projectFolders): `.next-term/mcp.json`
/// in the agent's folder and each one above it, up to the repository's top, at most ten, never the home folder. So a
/// monorepo's package can have its own, and the repository's still apply.
///
/// A name in more than one list: the first of these is used, and the others are shadowed (Claude Code's own order for
/// its scopes, local over project over user):
/// 1. the user's server for this project (`nextTerm.projects` names a folder this one is in or is): the user's choice
///    here, an off one included, so a team's server can be turned off for oneself;
/// 2. a project's, the nearest list first;
/// 3. the user's for all projects.
/// A server that breaks a rule (MCPHubRules) or is in its file twice is passed over and named in `issues`: it takes no
/// name from another list. An unreadable file adds nothing and is named in `unreadable`. The user's choices at the top of
/// their list (MCPHubChoices) apply on top: a server they turned off for this folder is off, whichever list it is from,
/// and their approvals of projects' lists come with the resolution, for MCPHubPlan.make.
///
/// A project's list comes with the repository, so anyone who can commit to it wrote it: each `Source` has its bytes'
/// `digest`, for the approval the user gives a project's list before any of its servers starts.
public enum MCPHubScope {
    /// The user's list: beside Next Term's other files, made only when the first server is added (MCPHubFile.updated).
    public static func userPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/Next Term/mcp.json")
    }

    /// A project's list, in its folder.
    public static let projectFolder = ".next-term"
    public static let projectFile = projectFolder + "/mcp.json"

    /// One list, as read.
    public struct Source: Equatable, Sendable {
        public let place: MCPHubFile.Place
        public let file: String
        public let read: Result<MCPHubFile.Read, MCPHubFile.Problem>
        /// The bytes' SHA-256, in hex.
        public let digest: String

        public init(place: MCPHubFile.Place, file: String, data: Data) {
            self.place = place
            self.file = file
            read = MCPHubFile.parse(data)
            digest = SecretRun.digest(data)
        }

        /// A file that is there and can't be read: it counts as a broken list, never as none.
        init(place: MCPHubFile.Place, file: String, problem: MCPHubFile.Problem) {
            self.place = place
            self.file = file
            read = .failure(problem)
            digest = ""
        }
    }

    /// A server that applies, and the list it is from.
    public struct Applied: Equatable, Sendable {
        public let server: MCPHubServer
        public let source: Source

        public var name: String { server.name }
    }

    public struct Issue: Equatable, Sendable {
        public let file: String
        public let name: String
        public let reasons: [String]
    }

    public struct Resolution: Equatable, Sendable {
        /// The servers an agent in the folder gets, by name.
        public var servers: [Applied] = []
        /// The ones the user turned off here, by name: listed, never used.
        public var off: [Applied] = []
        /// Same-named servers of lists further down the order, in it.
        public var shadowed: [Applied] = []
        public var issues: [Issue] = []
        /// Lists that can't be read: they add nothing (the app keeps the last list it read, and says why).
        public var unreadable: [Unreadable] = []
        /// The names among `off` that the user turned off for this folder (MCPHubChoices.off), not in their entry.
        public var offHere: Set<String> = []
        /// The projects' lists the user approved, as MCPHubPlan.make takes them (`file + "\0" + digest`).
        public var approved: Set<String> = []

        /// No server, and nothing to say: what every agent sees until the user adds the first one.
        public var isEmpty: Bool { servers.isEmpty && off.isEmpty && shadowed.isEmpty && issues.isEmpty && unreadable.isEmpty }
    }

    public struct Unreadable: Equatable, Sendable {
        public let file: String
        public let problem: MCPHubFile.Problem

        public init(file: String, problem: MCPHubFile.Problem) {
            self.file = file
            self.problem = problem
        }
    }

    // MARK: resolving

    /// The servers for an agent in `folder`, from the user's list and the projects' lists, nearest first. Reads nothing.
    public static func resolve(folder: String, user: Source?, projects: [Source], home: String) -> Resolution {
        var resolution = Resolution()
        let choices: MCPHubChoices
        if case .success(let read)? = user?.read { choices = MCPHubChoices.read(read.document) } else { choices = MCPHubChoices() }
        resolution.approved = choices.approvedKeys
        var forHere: [Applied] = [], fromProjects: [Applied] = [], forAll: [Applied] = []
        for source in (user.map { [$0] } ?? []) + projects {
            let read: MCPHubFile.Read
            switch source.read {
            case .failure(let problem):
                resolution.unreadable.append(Unreadable(file: source.file, problem: problem))
                continue
            case .success(let found): read = found
            }
            for entry in read.document.entries {
                if read.twice.contains(entry.key) {
                    if !resolution.issues.contains(where: { $0.file == source.file && $0.name == entry.key }) {
                        resolution.issues.append(Issue(file: source.file, name: entry.key, reasons: ["It is in the file twice."]))
                    }
                    continue
                }
                switch MCPHubServer.decode(name: entry.key, entry.value, place: source.place) {
                case .failure(let broken):
                    resolution.issues.append(Issue(file: source.file, name: entry.key, reasons: broken.reasons))
                case .success(let server):
                    let applied = Applied(server: server, source: source)
                    switch (source.place, server.projects) {
                    case (.project, _): fromProjects.append(applied)
                    case (.user, .all): forAll.append(applied)
                    case (.user, .only(let folders)):
                        if folders.contains(where: { contains($0, folder, home: home) }) { forHere.append(applied) }
                    }
                }
            }
        }
        var taken = Set<String>()
        for applied in forHere + fromProjects + forAll {
            if !taken.insert(applied.name).inserted {
                resolution.shadowed.append(applied)
            } else if !applied.server.enabled {
                resolution.off.append(applied)
            } else if choices.isOff(applied.name, in: folder, home: home) {
                resolution.off.append(applied)
                resolution.offHere.insert(applied.name)
            } else {
                resolution.servers.append(applied)
            }
        }
        resolution.servers.sort { $0.name < $1.name }
        resolution.off.sort { $0.name < $1.name }
        return resolution
    }

    /// Whether `folder` is `listed` (`~` meaning `home`) or inside it, each as the kernel spells it.
    static func contains(_ listed: String, _ folder: String, home: String) -> Bool {
        let expanded = listed == "~" ? home : listed.hasPrefix("~/") ? home + listed.dropFirst(1) : listed
        let top = canonicalPath(expanded), here = canonicalPath(folder)
        return here == top || here.hasPrefix(top == "/" ? "/" : top + "/")
    }

    // MARK: reading

    /// The lists for an agent in `folder` (nil: outside every project, the user's alone), read from disk. A file not
    /// there is no source; a project's list is read only when it is a plain file inside its `.next-term` folder once
    /// links are followed (SkillLibrary.readText), since a cloned repository's folder is anyone's.
    public static func sources(folder: String?, home: String, userFile: String? = nil) -> (user: Source?, projects: [Source]) {
        let userFile = userFile ?? userPath(home: home)
        let user = source(.user, userFile, in: (userFile as NSString).deletingLastPathComponent)
        let projects = (folder.map { SkillLibrary.projectFolders(from: $0, home: home) } ?? []).compactMap { top in
            source(.project, top + "/" + projectFile, in: top + "/" + projectFolder)
        }
        return (user, projects)
    }

    /// The servers for an agent in `folder`, read from disk now.
    public static func servers(folder: String, home: String = NSHomeDirectory(), userFile: String? = nil) -> Resolution {
        let found = sources(folder: folder, home: home, userFile: userFile)
        return resolve(folder: folder, user: found.user, projects: found.projects, home: home)
    }

    // MARK: saving

    public enum Saved: Equatable, Sendable {
        case written
        /// The change changed nothing, so nothing was written (and no file or folder made).
        case unchanged
    }

    public enum SaveFailure: Error, Equatable, Sendable {
        case refused(MCPHubFile.Refusal)
        /// The file changed on disk since it was read, or couldn't be written (SafeWrite).
        case write(SafeWrite.Failure)
    }

    /// Makes a change to the list at `file` (the user's, or a project's `.next-term/mcp.json`). Nothing is written
    /// when the change changes nothing; the file, and its folder, are made only by an act of the user's on none
    /// (MCPHubFile.updated). The write is all or nothing, and refused when the file changed since it was read. The
    /// user's list is the user's alone (0600); a project's is for its repository (0644).
    public static func save(_ change: MCPHubFile.Change, to file: String, place: MCPHubFile.Place) -> Result<Saved, SaveFailure> {
        write(change, to: file, place: place).map { (written: Written?) -> Saved in written == nil ? .unchanged : .written }
    }

    /// One write `save` made: the file's bytes before it (nil: there was no file) and after, for Undo.
    public struct Written: Equatable, Sendable {
        public let file: String
        public let place: MCPHubFile.Place
        public let before: Data?
        public let after: Data
    }

    /// `save`, with what it wrote: nil when nothing was written.
    public static func write(_ change: MCPHubFile.Change, to file: String, place: MCPHubFile.Place) -> Result<Written?, SaveFailure> {
        let folder = (file as NSString).deletingLastPathComponent
        var info = stat()
        var old: Data?
        if lstat(file, &info) == 0 {
            guard let text = SkillLibrary.readText(file, in: folder) else { return .failure(.refused(.unreadable(.cantRead))) }
            old = Data(text.utf8)
        }
        let bytes: Data
        switch MCPHubFile.updated(old, place: place, change) {
        case .failure(let refusal): return .failure(.refused(refusal))
        case .success(nil): return .success(nil)
        case .success(let made?): bytes = made
        }
        if old == nil {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            } catch {
                let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                return .failure(.write(.system(posix?.domain == NSPOSIXErrorDomain ? Int32(posix?.code ?? Int(EIO)) : EIO)))
            }
        }
        do {
            try SafeWrite.replace(file, with: bytes, expecting: old.map { .contents($0) } ?? .noFile,
                                  newFileMode: place == .user ? 0o600 : 0o644)
        } catch {
            return .failure(.write(error as? SafeWrite.Failure ?? .system(EIO)))
        }
        return .success(Written(file: file, place: place, before: old, after: bytes))
    }

    /// Puts a list back as it was before `written`, only while it is still what that write left: a list changed since
    /// (by hand, by another Next Term) is refused, never overwritten. A list the write made is removed again, so an Undo
    /// of the first server leaves no file, as before it.
    public static func undo(_ written: Written) -> Result<Void, SaveFailure> {
        guard let now = SkillLibrary.readText(written.file, in: (written.file as NSString).deletingLastPathComponent).map({ Data($0.utf8) }),
              now == written.after else { return .failure(.write(.changed)) }
        guard let before = written.before else {
            return unlink(written.file) == 0 ? .success(()) : .failure(.write(.system(errno)))
        }
        do {
            try SafeWrite.replace(written.file, with: before, expecting: .contents(written.after),
                                  newFileMode: written.place == .user ? 0o600 : 0o644)
        } catch {
            return .failure(.write(error as? SafeWrite.Failure ?? .system(EIO)))
        }
        return .success(())
    }

    /// A list as read: nil when there is no file. One that is there and isn't a plain UTF-8 file of at most
    /// MCPHubFile.maxBytes inside its folder, links followed, is `cantRead`.
    static func source(_ place: MCPHubFile.Place, _ file: String, in folder: String) -> Source? {
        var info = stat()
        guard lstat(file, &info) == 0 else { return nil }
        guard let text = SkillLibrary.readText(file, in: folder) else { return Source(place: place, file: file, problem: .cantRead) }
        return Source(place: place, file: file, data: Data(text.utf8))
    }
}
