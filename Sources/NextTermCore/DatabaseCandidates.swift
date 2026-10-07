import Foundation

/// One place a connection was found (a key, a split group, a file), before duplicates are merged.
/// The only type that holds a password, and it stays inside NextTermCore.
struct Candidate {
    var engine: DatabaseEngine
    var url: DatabaseURL?
    /// SQLite, absolute.
    var filePath: String?
    /// The source file, relative to the project.
    var file: String
    var keys: [String]
    var pooled = false
    var providers: [DatabaseProvider] = []
    var tools: [String] = []
    var isConnection = true
    var exists = true
    var note: String?

    var password: String? { url?.password }

    init(url: DatabaseURL, keys: [String], file: String, context: Databases.Context) {
        engine = url.engine
        self.url = url
        self.keys = keys
        self.file = file
        let host = url.host?.lowercased() ?? ""
        if let provider = DatabaseProvider.from(host: url.host, user: url.user) { providers.append(provider) }
        if url.scheme == "prisma+postgres", !providers.contains(.prismaPostgres) { providers.append(.prismaPostgres) }
        pooled = host.contains("-pooler.") || host.contains(".pooler.") || host.hasPrefix("pooler.")
            || url.parameters.contains { $0.key.lowercased() == "pgbouncer" && $0.value == "true" }
        let isLocal = DatabaseEnvironment.classify(host: url.host, socket: url.socket) == .local
        if context.herdInstalled, isLocal, [.mysql, .mariadb, .postgres].contains(engine),
           (url.socket ?? "").contains("/Herd/") || context.appURLHost?.lowercased().hasSuffix(".test") == true {
            providers.append(.herd)
        }
    }

    private init(sqlite path: String, file: String, keys: [String], exists: Bool) {
        engine = .sqlite
        filePath = path
        self.file = file
        self.keys = keys
        self.exists = exists
    }

    static func sqlite(_ path: String, file: String, keys: [String], exists: Bool) -> Candidate {
        Candidate(sqlite: path, file: file, keys: keys, exists: exists)
    }

    /// The shape of a connection an ORM expects but no env file sets.
    static func unset(_ engine: DatabaseEngine, key: String, hint: OrmHint) -> Candidate {
        var c = Candidate(sqlite: "", file: hint.file, keys: [key], exists: false)
        c.engine = engine
        c.filePath = nil
        c.isConnection = false
        c.tools = [hint.tool]
        c.note = "Not set: \(hint.file) reads \(key), and no env file sets it"
        return c
    }

    var environment: DatabaseEnvironment {
        guard isConnection else { return .unknown }
        if engine == .sqlite { return .local }
        return DatabaseEnvironment.classify(host: url?.host, socket: url?.socket)
    }

    var name: String {
        if let filePath, !filePath.isEmpty { return (filePath as NSString).lastPathComponent }
        if let database = url?.database { return database }
        if let host = url?.host, let label = host.split(separator: ".").first, !host.hasPrefix("/"), !isConnectionLocal { return String(label) }
        if !isConnection, let key = keys.first { return key }
        return engine.displayName
    }

    private var isConnectionLocal: Bool { environment == .local }

    var masked: String {
        if !isConnection, url == nil, filePath == nil { return note ?? "Not set" }
        if engine == .sqlite, let filePath { return filePath }
        return url?.masked ?? engine.displayName
    }

    /// Same database, whichever key or file named it: engine, host, port, database and user. Neon's
    /// pooler host and Supabase's pooler user name the same database as their direct forms.
    var mergeKey: String {
        if !isConnection { return "shape|\(engine.rawValue)|\(file)|\(keys.first ?? "")" }
        if engine == .sqlite { return "sqlite|\(filePath ?? "")" }
        guard let url else { return "unknown|\(file)" }
        var host = (url.host ?? "").lowercased()
        var user = url.user ?? ""
        var port = String(url.port ?? engine.defaultPort ?? 0)
        if host.hasSuffix(".supabase.co"), host.hasPrefix("db.") {
            host = "supabase:" + (host.split(separator: ".").dropFirst().first.map(String.init) ?? host)
            port = ""
        } else if host.hasSuffix(".pooler.supabase.com"), let dot = user.firstIndex(of: ".") {
            host = "supabase:" + user[user.index(after: dot)...]
            user = String(user[..<dot])
            port = ""
        } else if host.hasSuffix(".neon.tech"), let first = host.split(separator: ".").first, first.hasSuffix("-pooler") {
            host = String(first.dropLast(7)) + host.dropFirst(first.count)
        }
        let engineName = engine == .mariadb ? "mysql" : engine.rawValue
        return [engineName, host, port, url.database ?? "", user, url.socket ?? ""].joined(separator: "|")
    }
}

/// Candidates that name one database.
struct CandidateGroup {
    let id: String
    var members: [Candidate]

    /// What a hand-off uses: a direct connection before a pooled one.
    var preferred: Candidate { members[preferredIndex] }
    private var preferredIndex: Int { members.firstIndex { !$0.pooled } ?? 0 }

    var `public`: DetectedDatabase {
        let first = preferred
        let ordered = [first] + members.enumerated().filter { $0.offset != preferredIndex }.map(\.element)
        var providers: [DatabaseProvider] = []
        for p in ordered.flatMap(\.providers) where !providers.contains(p) { providers.append(p) }
        let rank: (DatabaseProvider) -> Int = { $0 == .vercel ? 2 : $0 == .herd ? 1 : 0 }
        providers.sort { rank($0) < rank($1) }
        var tools: [String] = []
        for t in ordered.flatMap(\.tools) where !tools.contains(t) { tools.append(t) }
        let pooledAndDirect = ordered.contains { $0.pooled } && ordered.contains { !$0.pooled }
        var note = first.note
        if note == nil, first.isConnection, !first.exists { note = "The file does not exist yet" }
        if note == nil, pooledAndDirect { note = "Pooled and direct URLs; hand-offs use the direct one" }
        return DetectedDatabase(
            id: id, engine: first.engine, name: first.name, host: first.url?.host, port: first.url == nil ? nil : first.url?.port ?? first.engine.defaultPort,
            user: first.url?.user, database: first.url?.database, socket: first.url?.socket, providers: providers, environment: first.environment,
            masked: first.masked,
            sources: ordered.map { DetectedDatabase.Source(file: $0.file, keys: $0.keys, pooled: $0.pooled) },
            filePath: first.filePath.flatMap { $0.isEmpty ? nil : $0 },
            hasPassword: ordered.contains { $0.password?.isEmpty == false },
            isConnection: first.isConnection && first.exists, note: note, tools: tools)
    }
}

extension Databases {
    static func merge(_ candidates: [Candidate]) -> [CandidateGroup] {
        var groups: [CandidateGroup] = []
        var index: [String: Int] = [:]
        for c in candidates {
            let key = c.mergeKey
            if let i = index[key] {
                groups[i].members.append(c)
            } else {
                index[key] = groups.count
                groups.append(CandidateGroup(id: key, members: [c]))
            }
        }
        return groups
    }

    /// The ORM's keys on the rows that use them, and a row for a key it reads that nothing sets.
    static func applyHints(_ candidates: inout [Candidate], _ hints: [OrmHint]) {
        for hint in hints {
            for i in candidates.indices where !Set(candidates[i].keys).isDisjoint(with: hint.keys) && !candidates[i].tools.contains(hint.tool) {
                candidates[i].tools.append(hint.tool)
            }
            if let key = hint.keys.first, let engine = hint.engine, hint.literal == nil, !candidates.contains(where: { $0.keys.contains(key) }) {
                candidates.append(.unset(engine, key: key, hint: hint))
            }
        }
    }

    /// Folders never searched for SQLite files: dependencies and build output.
    static let skippedFolders: Set<String> = ["node_modules", "vendor", "build", "dist", "DerivedData", "Pods", "target", "__pycache__",
                                              "venv", "env", "coverage", "out", "bower_components", "Carthage"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3"]

    /// SQLite files in the project, three folders deep at most, never through a symlink or into a
    /// dependency folder, and only files that start with SQLite's header.
    static func sqliteFiles(_ context: Context) -> [String] {
        var result: [String] = []
        var budget = 20_000
        let fm = FileManager.default
        func walk(_ folder: String, depth: Int) {
            guard budget > 0, let names = try? fm.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() {
                budget -= 1
                guard budget > 0 else { return }
                let path = (folder as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR where depth < 3 && !name.hasPrefix(".") && !skippedFolders.contains(name):
                    walk(path, depth: depth + 1)
                case S_IFREG where sqliteExtensions.contains((name as NSString).pathExtension.lowercased()):
                    if Databases.isSQLiteFile(path) { result.append(canonicalPath(path)) }
                default:
                    break
                }
            }
        }
        walk(context.root, depth: 0)
        return result
    }
}

/// What Prisma or Drizzle says about the database: its engine and the env keys it reads, by regex
/// (their configs are code, and code is never run).
struct OrmHint: Sendable {
    let tool: String
    /// Relative to the project.
    let file: String
    /// Where a relative `file:` URL is resolved.
    let folder: String
    let engine: DatabaseEngine?
    /// The URL's key first.
    let keys: [String]
    /// A URL written in the config itself.
    let literal: String?

    static func read(root: String) -> [OrmHint] {
        var hints: [OrmHint] = []
        let fm = FileManager.default
        func text(_ relative: String) -> String? {
            Databases.Context.small((root as NSString).appendingPathComponent(relative), limit: 1024 * 1024).map { String(decoding: $0, as: UTF8.self) }
        }
        // Prisma: the datasource block, and Prisma 7's prisma.config.ts.
        var schemaFiles = ["prisma/schema.prisma", "schema.prisma"].filter { text($0) != nil }
        if let more = try? fm.contentsOfDirectory(atPath: root + "/prisma/schema") {
            schemaFiles += more.filter { $0.hasSuffix(".prisma") }.sorted().map { "prisma/schema/" + $0 }
        }
        let schema = schemaFiles.compactMap(text).joined(separator: "\n")
        let block = captures(#"datasource\s+\w+\s*\{([^}]*)\}"#, in: schema).first ?? ""
        let config = text("prisma.config.ts") ?? ""
        if !block.isEmpty || !config.isEmpty {
            let provider = captures(#"provider\s*=\s*"([^"]+)""#, in: block).first
            var keys = captures(#"\b(?:url|directUrl|shadowDatabaseUrl)\s*=\s*env\(\s*"([^"]+)"\s*\)"#, in: block)
            keys += envKeys(in: config).filter { !keys.contains($0) }
            let literal = captures(#"\burl\s*=\s*"([^"]+)""#, in: block).first
            let file = schemaFiles.first ?? "prisma.config.ts"
            hints.append(OrmHint(tool: "Prisma", file: block.isEmpty ? "prisma.config.ts" : file,
                                 folder: (root as NSString).appendingPathComponent((file as NSString).deletingLastPathComponent),
                                 engine: provider.flatMap(DatabaseEngine.init(orm:)), keys: keys, literal: literal))
        }
        // Drizzle: dialect (or the older driver) and dbCredentials.
        for ext in ["ts", "js", "mjs", "cjs", "mts", "cts", "json"] {
            let file = "drizzle.config." + ext
            guard let source = text(file) else { continue }
            let dialect = captures(#"\b(?:dialect|driver)\s*:\s*["'`]([A-Za-z0-9-]+)["'`]"#, in: source).first
            let engine = dialect.flatMap { name -> DatabaseEngine? in
                switch name { case "pg", "postgresql": return .postgres; case "mysql2": return .mysql; case "better-sqlite", "libsql": return .sqlite
                default: return DatabaseEngine(orm: name) }
            }
            var literal = captures(#"\burl\s*:\s*["'`]([^"'`]+)["'`]"#, in: source).first
            if let value = literal, engine == .sqlite, DatabaseURL(value) == nil { literal = "file:" + value }
            hints.append(OrmHint(tool: "Drizzle", file: file, folder: root, engine: engine, keys: envKeys(in: source), literal: literal))
            break
        }
        return hints
    }

    /// `env("X")`, `process.env.X`, `process.env["X"]`, in order, once each.
    static func envKeys(in source: String) -> [String] {
        let found = captures(#"(?:\benv\(\s*["'`]|process\.env\.|process\.env\[\s*["'`])([A-Z][A-Z0-9_]*)"#, in: source)
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static func captures(_ pattern: String, in text: String) -> [String] {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
