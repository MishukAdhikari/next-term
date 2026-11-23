import Foundation

/// What the user decided about the MCP hub's servers beyond the servers themselves, kept at the top of the user's list
/// (MCPHubFile) under its own `nextTerm`, where the app reads it for every agent's plan (MCPHubControl) and Settings ›
/// MCP Servers changes it:
///
///     "nextTerm": {
///       "approvedLists": [{"file": "/Users/me/Code/app/.next-term/mcp.json", "digest": "9f2c…"}],
///       "off": [{"server": "github", "folder": "/Users/me/Code/app"}]
///     }
///
/// - **An approval** is of a project's list as it is now: its file and its bytes' SHA-256 (MCPHubScope.Source.digest).
///   A commit that changes the list changes the digest, so its servers wait again until the user looks at it again.
///   One approval a list: approving it again replaces the old one.
/// - **Off for a project**: a server's name, and a folder an agent in which (or in a folder inside it) gets that server
///   off, whichever list it comes from, the user's or the project's. So a team's server can be turned off for oneself,
///   and one of the user's own servers for one project, without a second entry of the same name.
///
/// Read leniently: an item that isn't a well-formed record is passed over, never a reason the list can't be used; and
/// written back with every other key under `nextTerm` kept as it was.
public struct MCPHubChoices: Equatable, Sendable {
    public struct Approval: Equatable, Sendable {
        public let file: String
        public let digest: String

        public init(file: String, digest: String) {
            self.file = file
            self.digest = digest
        }

        /// As MCPHubPlan.make takes it.
        public var key: String { file + "\u{0}" + digest }
    }

    public struct Off: Equatable, Sendable {
        public let server: String
        public let folder: String

        public init(server: String, folder: String) {
            self.server = server
            self.folder = folder
        }
    }

    public var approved: [Approval] = []
    public var off: [Off] = []

    public init(approved: [Approval] = [], off: [Off] = []) {
        self.approved = approved
        self.off = off
    }

    /// The approvals, as MCPHubPlan.make takes them.
    public var approvedKeys: Set<String> { Set(approved.map(\.key)) }

    /// Whether the list at `file`, with these bytes' `digest`, is approved as it is now.
    public func isApproved(_ file: String, digest: String) -> Bool {
        approved.contains { $0.file == file && $0.digest == digest }
    }

    /// Whether the user turned `server` off for `folder`: for it, or for a folder it is inside.
    public func isOff(_ server: String, in folder: String, home: String) -> Bool {
        off.contains { $0.server == server && MCPHubScope.contains($0.folder, folder, home: home) }
    }

    /// The off record that covers `server` in `folder`, as it is written (so turning it on again removes that one).
    public func offRecord(_ server: String, in folder: String, home: String) -> Off? {
        off.first { $0.server == server && MCPHubScope.contains($0.folder, folder, home: home) }
    }

    // MARK: reading and writing

    static let key = "nextTerm"

    /// The choices in a user's list, as read.
    public static func read(_ document: MCPHubFile.Document) -> MCPHubChoices {
        guard let own = document.members.first(where: { $0.key == key })?.value else { return MCPHubChoices() }
        var choices = MCPHubChoices()
        if case .array(let items)? = own.member("approvedLists") {
            for item in items {
                guard let file = item.member("file")?.string, let digest = item.member("digest")?.string,
                      !file.isEmpty, !digest.isEmpty else { continue }
                choices.approved.append(Approval(file: file, digest: digest))
            }
        }
        if case .array(let items)? = own.member("off") {
            for item in items {
                guard let server = item.member("server")?.string, let folder = item.member("folder")?.string,
                      !server.isEmpty, !folder.isEmpty else { continue }
                choices.off.append(Off(server: server, folder: folder))
            }
        }
        return choices
    }

    /// The document with these choices in its `nextTerm`, every other key there and elsewhere as it was. The two lists
    /// are rewritten whole (an item that wasn't well-formed goes); an empty one is taken out, and so is an empty
    /// `nextTerm`.
    func written(into document: MCPHubFile.Document) -> MCPHubFile.Document {
        var document = document
        var own = document.members.first { $0.key == Self.key }?.value.members ?? []
        func put(_ name: String, _ items: [MCPHubFile.Value]) {
            own.removeAll { $0.key == name && items.isEmpty }
            guard !items.isEmpty else { return }
            if let at = own.firstIndex(where: { $0.key == name }) {
                own[at].value = .array(items)
                own = own.enumerated().filter { $0.offset == at || $0.element.key != name }.map(\.element)
            } else {
                own.append(MCPHubFile.Member(name, .array(items)))
            }
        }
        put("approvedLists", approved.map { .object([MCPHubFile.Member("file", .string($0.file)), MCPHubFile.Member("digest", .string($0.digest))]) })
        put("off", off.map { .object([MCPHubFile.Member("server", .string($0.server)), MCPHubFile.Member("folder", .string($0.folder))]) })
        if let at = document.members.firstIndex(where: { $0.key == Self.key }) {
            if own.isEmpty { document.members.remove(at: at) } else { document.members[at].value = .object(own) }
        } else if !own.isEmpty {
            document.members.append(MCPHubFile.Member(Self.key, .object(own)))
        }
        return document
    }

    /// Why a choice can't be kept, or nil: a list or a folder is a full path, a server has a name.
    static func reason(_ change: MCPHubFile.Change) -> String? {
        switch change {
        case .approve(let file, let digest):
            if !file.hasPrefix("/") { return "\(file) is not a list's full path." }
            if digest.isEmpty { return "The list has no digest to approve." }
        case .turnOff(let server, let folder), .turnOn(let server, let folder):
            if server.isEmpty { return "It names no server." }
            if !(folder.hasPrefix("/") || folder == "~" || folder.hasPrefix("~/")) { return "\(folder) is not a folder's full path." }
        case .set, .remove: break
        }
        return nil
    }
}
