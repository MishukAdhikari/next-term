import Foundation

// TOML, YAML and agents' configs for the import. TOML is read with the importer's TOML reader and YAML with
// `YAMLSubset`, both into `YAMLSubset.Node`s, and walked here: known shapes (Codex, Cargo, Compose, Kubernetes, goose,
// Continue) by the places that hold keys, any other document by its paths, as JSON is. Agents' configs the MCP-config
// import doesn't rewrite are copied with a note on each row that the file still holds the key. The MCP-config import's
// own files are told apart (`isMoveTarget`) so the app sends them there instead.

/// A reader's failure, as a `Result`'s.
extension SecretSources.Unreadable: Error {}

extension SecretSources {
    /// The most a TOML or YAML file may hold: no config file is near it.
    public static let configMaxBytes = TOMLReader.maxBytes

    /// What a config file gives: its values, and the agent whose config it is.
    struct ConfigFound {
        var values: [Found]
        var agent: String?
    }

    /// The report for a TOML or YAML file, or why it can't be read.
    static func configReport(_ text: String, format: Format, file: String, purpose: String, stored: Set<String>,
                             now: Date) -> SourceReport {
        guard text.utf8.count <= configMaxBytes else {
            return SourceReport(format: format, unreadable: .configTooLarge, purpose: purpose)
        }
        let read: Result<ConfigFound, Unreadable> = format == .toml ? tomlFound(text) : yamlFound(text)
        switch read {
        case .failure(let reason):
            return SourceReport(format: format, unreadable: reason, purpose: purpose)
        case .success(let found):
            guard found.values.count <= maxValues else {
                return SourceReport(format: format, unreadable: .tooMany, purpose: purpose)
            }
            return report(found.values, format: format, purpose: purpose, stored: stored, now: now, agent: found.agent)
        }
    }

    /// TOML by its content: a first line that is a table's header, a `key = value` line, and text the TOML reader
    /// reads. A `.env` with quoted values reads as TOML too, so it has no header; an INI file's bare values don't read.
    static func looksLikeTOML(_ text: String) -> Bool {
        guard text.utf8.count <= configMaxBytes, let first = firstLine(text), first.hasPrefix("[") else { return false }
        guard text.contains("=") else { return false }
        guard case .success(let table) = TOMLReader.parse(text) else { return false }
        return !table.isEmpty
    }

    /// YAML by its content: a `---` or `%YAML` first, or a `key:` line with a block under it, and text `YAMLSubset`
    /// reads into a mapping or a list. Flat `KEY: value` lines are left to the `.env` reader, which reads them alike.
    static func looksLikeYAML(_ text: String) -> Bool {
        guard text.utf8.count <= configMaxBytes, let first = firstLine(text) else { return false }
        let marked: Bool = first == "---" || first.hasPrefix("--- ") || first.hasPrefix("%YAML")
        guard marked || hasBlockUnderKey(text) else { return false }
        guard case .success(let documents) = YAMLSubset.documents(text) else { return false }
        return documents.contains { (node: YAMLSubset.Node) -> Bool in node.pairs != nil || node.items != nil }
    }

    /// The first line with something on it that isn't a comment, without its blanks.
    static func firstLine(_ text: String) -> Substring? {
        for line in text.split(separator: "\n", maxSplits: 1_000, omittingEmptySubsequences: true) {
            let trimmed: Substring = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
            return trimmed
        }
        return nil
    }

    /// A `key:` line with nothing after it, then a line more indented or a `- ` item, in the first 200 lines.
    static func hasBlockUnderKey(_ text: String) -> Bool {
        var opened: Int?
        for line in text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: true).prefix(200) {
            let content: Substring = line.drop { (character: Character) -> Bool in character == " " }
            let body: String = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || body.hasPrefix("#") { continue }
            let indent: Int = line.count - content.count
            if let opened, indent > opened || body.hasPrefix("- ") { return true }
            opened = body.hasSuffix(":") && !body.hasPrefix("-") ? indent : nil
        }
        return false
    }
}

// MARK: - The MCP-config import's own files

extension SecretSources {
    /// Whether a chosen file is one the MCP-config import rewrites: an agent's own config Next Term knows, or a
    /// project's `.mcp.json` and the others that import reads in a project, wherever the project is. Links are followed
    /// first. The app sends such a file to that import, with its backup and Undo, instead of copying from it.
    public static func isMoveTarget(path: String, home: String = NSHomeDirectory(), projects: [String] = []) -> Bool {
        moveSource(path: path, home: home, projects: projects) != nil
    }

    /// The MCP-config import's source for a chosen file, or nil when it isn't one of that import's files.
    public static func moveSource(path: String, home: String = NSHomeDirectory(),
                                  projects: [String] = []) -> SecretImport.Source? {
        let real: String = canonicalPath(path)
        var folders: [String] = projects
        for candidate in [path, real] {
            for name in SecretImport.projectFiles where candidate.hasSuffix("/" + name) {
                folders.append(String(candidate.dropLast(name.count + 1)))
            }
        }
        let sources: [SecretImport.Source] = SecretImport.sources(home: home, projects: folders)
        return sources.first { (source: SecretImport.Source) -> Bool in canonicalPath(source.path) == real }
    }
}
