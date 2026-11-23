import AppKit
import NextTermCore

/// The MCP servers set up in agents' own configs (MCPHubAgents), as Settings › MCP Servers › Found in your agents and
/// the new-server offer (MCPHubOffer) read them: off the main thread, and only a file that changed since its last read
/// (by its size and modification time), so ~/.claude.json, which Claude Code rewrites often, is read again only when it
/// did. Only read: no agent's file is ever written for the hub (R4).
@MainActor
enum MCPHubAgentServers {
    /// The self-test's own configs: the user's agents are never read in a self-test (none, unless it gives its own).
    static var sourcesForTest: [SecretImport.Source]?

    /// The agents' configs, and each open project's own: Secrets' import reads the same files.
    static func sources(projects: [String]) -> [SecretImport.Source] {
        sourcesForTest ?? (SelfTest.isRequested ? [] : SecretImport.sources(projects: projects))
    }

    /// One reader's state: each file's servers as last read, with the file's signature then.
    final class Reader {
        var files: [String: (signature: String, read: MCPHubAgents.FileRead)] = [:]
        var reading = false
        var again: (() -> Void)?
    }

    /// Reads `sources` again where a file changed, then hands every server found, merged (MCPHubAgents.merged), to `done`
    /// on the main thread; nothing changed, `done` gets the last list at once. A read asked for while one runs follows
    /// it. `stored`: the names in Secrets now, so a key's suggested name never takes a stored one's.
    static func read(_ sources: [SecretImport.Source], with reader: Reader, done: @escaping ([MCPHubAgents.Server]) -> Void) {
        readFiles(sources, with: reader) { files in done(MCPHubAgents.merged(files.map(\.read.servers))) }
    }

    /// The same, file by file, as the offer needs them (MCPHubAgents.due): each source's path and how it read.
    static func readFiles(_ sources: [SecretImport.Source], with reader: Reader,
                          done: @escaping ([(path: String, read: MCPHubAgents.FileRead)]) -> Void) {
        let stored = Set(SecretsStore.shared.index?.names ?? [])
        let storedMark = stored.sorted().joined(separator: ",")
        let signatures = sources.map { signature(of: $0.path) + "|" + storedMark }
        let changed = sources.indices.filter { reader.files[sources[$0].path]?.signature != signatures[$0] }
        let merged = { sources.map { (path: $0.path, read: reader.files[$0.path]?.read ?? .unreadable) } }
        guard !changed.isEmpty else { return done(merged()) }
        guard !reader.reading else {
            reader.again = { readFiles(sources, with: reader, done: done) }
            return
        }
        reader.reading = true
        let wanted = changed.map { (sources[$0], signatures[$0]) }
        Task.detached(priority: .utility) {
            let read = wanted.map { source, signature in (source.path, signature, MCPHubAgents.read(source, stored: stored)) }
            await MainActor.run {
                for (path, signature, file) in read { reader.files[path] = (signature, file) }
                reader.reading = false
                done(merged())
                if let again = reader.again {
                    reader.again = nil
                    again()
                }
            }
        }
    }

    /// A file's size and modification time, or `-` when it is not there.
    nonisolated static func signature(of path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "-" }
        return "\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    // MARK: Settings

    private static let settingsReader = Reader()
    /// What Settings last found, every file's servers merged.
    private(set) static var found: [MCPHubAgents.Server] = []

    /// Settings shows the tab, or comes back: the agents' configs and the open projects' read again where they changed.
    /// A change posts MCPHubControl.changed, so the tab shows it.
    static func refresh(projects: [String]) {
        read(sources(projects: projects), with: settingsReader) { servers in
            guard servers != found else { return }
            found = servers
            NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
        }
    }
}
