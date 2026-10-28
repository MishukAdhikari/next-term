import Foundation

/// edit_host's change to a saved host (plan 010a U6a): each field given replaces the saved one, and the rest stay. A new
/// destination or port points the host at another server, so it gets a new id, as New Remote Tab gives it: tabs and kept
/// records saved for the old id do not follow it there (RemoteConnection.host(of:) refuses them), and tabs open on the
/// old one keep their copy until they close.
public struct HostEdit: Equatable, Sendable {
    public var name: String?
    public var destination: String?
    public var port: Int?
    /// Back to ssh's own port (or the one ~/.ssh/config gives).
    public var clearPort = false
    public var directory: String?
    public var keep: KeepMode?
    public var tmuxPrefix: TmuxPrefix?
    public var tmuxHistory: Int?

    public init(name: String? = nil, destination: String? = nil, port: Int? = nil, clearPort: Bool = false, directory: String? = nil,
                keep: KeepMode? = nil, tmuxPrefix: TmuxPrefix? = nil, tmuxHistory: Int? = nil) {
        self.name = name
        self.destination = destination
        self.port = port
        self.clearPort = clearPort
        self.directory = directory
        self.keep = keep
        self.tmuxPrefix = tmuxPrefix
        self.tmuxHistory = tmuxHistory
    }

    /// edit_host's arguments, each checked for its type; the host's own rules are `apply`'s. null counts as not given,
    /// as for the other tools (MCPArguments).
    public static func parse(_ arguments: [String: Any]) -> Result<HostEdit, HostEditFailure> {
        var edit = HostEdit()
        func given(_ key: String) -> Any? { arguments[key].flatMap { $0 is NSNull ? nil : $0 } }
        func text(_ key: String) -> String? { (given(key) as? String)?.trimmingCharacters(in: .whitespaces) }
        edit.name = text("name")
        edit.destination = text("destination")
        edit.directory = text("directory")
        if let value = given("port") {
            guard let port = value as? Int else { return .failure(.init("port is a number from 1 to 65535.")) }
            edit.port = port
        }
        edit.clearPort = given("clear_port") as? Bool ?? false
        if edit.clearPort, edit.port != nil { return .failure(.init("Give port or clear_port, not both.")) }
        if let value = given("keep") {
            guard let raw = value as? String, let keep = KeepMode(rawValue: raw) else { return .failure(.init("keep is off, tmux or herdr.")) }
            edit.keep = keep
        }
        if let value = given("tmux_prefix") {
            guard let raw = value as? String, let prefix = TmuxPrefix(rawValue: raw) else {
                let known: String = TmuxPrefix.allCases.map(\.rawValue).joined(separator: ", ")
                return .failure(.init("tmux_prefix is one of \(known)."))
            }
            edit.tmuxPrefix = prefix
        }
        if let value = given("tmux_history") {
            guard let lines = value as? Int else { return .failure(.init("tmux_history is a number of lines, 1,000 to 200,000.")) }
            edit.tmuxHistory = lines
        }
        return .success(edit)
    }

    /// What applying it gives.
    public struct Applied: Equatable, Sendable {
        public var host: RemoteHost
        /// It now points at another server: a new id.
        public var repointed: Bool
        /// What changes, one line each, as the user is shown it: “destination: dev@203.0.113.5 → dev@203.0.113.9”.
        public var changes: [String]
    }

    /// `saved` with the edit made, checked as New Remote Tab checks a host; `others`: the other saved hosts, whose names
    /// it may not take.
    public func apply(to saved: RemoteHost, others: [RemoteHost]) -> Result<Applied, HostEditFailure> {
        let given: [Bool] = [name != nil, destination != nil, port != nil, clearPort, directory != nil, keep != nil,
                             tmuxPrefix != nil, tmuxHistory != nil]
        guard given.contains(true) else { return .failure(.init("Give at least one thing to change.")) }
        var host = saved
        if let name { host.name = name }
        if let destination { host.destination = destination }
        if let port { host.port = port }
        if clearPort { host.port = nil }
        if let directory { host.directory = directory }
        if let keep { host.keep = keep }
        if let tmuxPrefix { host.tmuxPrefix = tmuxPrefix == .ctrlB ? nil : tmuxPrefix }
        if let tmuxHistory { host.tmuxHistory = tmuxHistory == TmuxOptions.defaultHistory ? nil : tmuxHistory }
        if let problem = host.problem { return .failure(.init(problem)) }
        if host.name != saved.name, let problem = RemoteHost.nameProblem(host.name) { return .failure(.init(problem)) }
        let taken = others.contains { (other: RemoteHost) -> Bool in
            other.id != saved.id && other.name.caseInsensitiveCompare(host.name.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
        if taken { return .failure(.init("Another saved host is named “\(host.name)”.")) }
        let repointed = host.destination != saved.destination || host.port != saved.port
        if repointed { host.id = RemoteHost.makeID() }
        return .success(Applied(host: host, repointed: repointed, changes: Self.changes(from: saved, to: host)))
    }

    /// What differs, field by field.
    public static func changes(from old: RemoteHost, to new: RemoteHost) -> [String] {
        func port(_ value: Int?) -> String { value.map(String.init) ?? "ssh’s own" }
        var lines: [String] = []
        if old.name != new.name { lines.append("name: \(old.name) → \(new.name)") }
        if old.destination != new.destination { lines.append("destination: \(old.destination) → \(new.destination)") }
        if old.port != new.port { lines.append("port: \(port(old.port)) → \(port(new.port))") }
        if old.directory != new.directory { lines.append("folder: \(old.directory) → \(new.directory)") }
        if old.keep != new.keep { lines.append("keep: \(old.keep.rawValue) → \(new.keep.rawValue)") }
        let oldTmux = old.tmuxOptions, newTmux = new.tmuxOptions
        if oldTmux.prefix != newTmux.prefix { lines.append("tmux prefix: \(oldTmux.prefix.rawValue) → \(newTmux.prefix.rawValue)") }
        if oldTmux.history != newTmux.history { lines.append("tmux history: \(oldTmux.history) → \(newTmux.history) lines") }
        return lines
    }
}

/// Why an edit was refused, in the words the agent is told.
public struct HostEditFailure: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}
