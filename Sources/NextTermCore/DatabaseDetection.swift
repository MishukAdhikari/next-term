import Foundation

/// Finds a project's databases offline, from its own text files: env files, Prisma, Drizzle, Supabase's
/// config, the Vercel link, and SQLite files. It never runs project code, never reads the app's own
/// environment, and never writes anything.
public enum Databases {
    /// The env files Laravel, Next.js and `vercel env pull` use, in the order Next.js prefers them.
    public static let envFiles = [".env.development.local", ".env.local", ".env.development", ".env"]
    /// Read for the engine and the shape of a connection only, never as one.
    public static let exampleFiles = [".env.example"]

    /// Herd for macOS keeps its configuration here.
    public static var herdIsInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Application Support/Herd")
    }

    public static func scan(root: String, herdInstalled: Bool = herdIsInstalled) -> DatabaseScan {
        let context = Context(root: canonicalPath(root), herdInstalled: herdInstalled)
        var env = gather(context, live: true)
        if env.isEmpty { env = gather(context, live: false) } // a fresh clone: what .env.example expects
        var all = env + others(context)
        applyHints(&all, context.hints)
        return DatabaseScan(databases: merge(all).map(\.public), vercelProject: context.vercelProject)
    }

    /// Reads the password again, from the file it came from, for a hand-off. nil if it is gone or changed.
    public static func credentials(for database: DetectedDatabase, root: String, herdInstalled: Bool = herdIsInstalled) -> DatabaseCredentials? {
        guard database.isConnection else { return nil }
        if database.engine == .sqlite, let file = database.filePath {
            return DatabaseCredentials(password: nil, url: URL(fileURLWithPath: file))
        }
        let context = Context(root: canonicalPath(root), herdInstalled: herdInstalled)
        guard let group = merge(gather(context, live: true) + others(context)).first(where: { $0.id == database.id }) else { return nil }
        return DatabaseCredentials(password: group.preferred.password, url: group.preferred.url?.handOffURL)
    }

    /// The first 16 bytes of every SQLite 3 database.
    public static func isSQLiteFile(_ path: String) -> Bool {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return header == Data("SQLite format 3\0".utf8)
    }

    /// What the SQLite viewer opens: a SQLite file by its header, or an empty one (Laravel makes
    /// database.sqlite with `touch`).
    public static func opensInViewer(_ path: String) -> Bool {
        guard sqliteExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        return isSQLiteFile(path) || isEmptyFile(path)
    }

    public static func isEmptyFile(_ path: String) -> Bool {
        isRegularFile(path) && ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1) == 0
    }

    // MARK: context

    /// What the scan reads once per project.
    struct Context {
        let root: String
        let herdInstalled: Bool
        var vercelProject: String?
        var isLaravel = false
        var appURLHost: String?
        var hints: [OrmHint] = []

        init(root: String, herdInstalled: Bool) {
            self.root = root
            self.herdInstalled = herdInstalled
            let fm = FileManager.default
            isLaravel = fm.fileExists(atPath: root + "/artisan")
            if let data = Self.small(root + "/.vercel/project.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["projectId"] is String {
                vercelProject = (json["projectName"] as? String) ?? "linked"
            }
            hints = OrmHint.read(root: root)
        }

        func path(_ relative: String) -> String { (root as NSString).appendingPathComponent(relative) }

        static func small(_ path: String, limit: Int = 512 * 1024) -> Data? {
            guard isRegularFile(path), let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int),
                  size <= limit else { return nil }
            return FileManager.default.contents(atPath: path)
        }
    }

    // MARK: gathering

    private static func gather(_ base: Context, live: Bool) -> [Candidate] {
        var context = base
        var found: [Candidate] = []
        for file in live ? envFiles : exampleFiles {
            let path = context.path(file)
            guard let entries = EnvFile.read(path) else { continue }
            let values = EnvFile.values(entries)
            if context.appURLHost == nil, let app = values["APP_URL"] {
                context.appURLHost = DatabaseURL.hostAndPort(String(app.split(separator: "/").dropFirst().first ?? "")).0
            }
            let header = (try? String(contentsOfFile: path, encoding: .utf8))?.prefix(80) ?? ""
            let fromVercel = header.hasPrefix("# Created by Vercel CLI")
                || (context.vercelProject != nil && (file == ".env.local" || file == ".env.development.local"))
            var cs = fromEnv(file: file, entries: entries, values: values, context: context)
            for i in cs.indices {
                if fromVercel { cs[i].providers.append(.vercel) }
                if !live {
                    cs[i].isConnection = false
                    cs[i].note = "Example only: \(file) shows the shape, not a connection"
                }
            }
            found += cs
        }
        return found
    }

    /// What is not in an env file: Supabase's local stack, a URL written in an ORM's config, SQLite files.
    private static func others(_ context: Context) -> [Candidate] {
        var found = supabase(context)
        for hint in context.hints {
            guard let literal = hint.literal, var c = fromURL(literal, keys: [], file: hint.file, context: context, relativeTo: hint.folder) else { continue }
            c.tools.append(hint.tool)
            found.append(c)
        }
        found += sqliteFiles(context).map { path in
            Candidate.sqlite(path, file: relative(path, to: context.root), keys: [], exists: true)
        }
        return found
    }

    /// The connections an env file names: Laravel's `DB_*`, URL keys, libpq's `PG*`, `POSTGRES_*`.
    static func fromEnv(file: String, entries: [EnvEntry], values: [String: String], context: Context) -> [Candidate] {
        var found: [Candidate] = []
        var seen = Set<String>()
        let keys = entries.map(\.key).filter { seen.insert($0).inserted }
        func set(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }

        // Laravel and Herd: split keys, or DB_URL over them.
        if values["DB_CONNECTION"] != nil || values["DB_HOST"] != nil || values["DB_DATABASE"] != nil || set("DB_URL") != nil {
            let dbKeys = keys.filter { $0.hasPrefix("DB_") }
            var c: Candidate?
            if let url = set("DB_URL") {
                c = fromURL(url, keys: dbKeys, file: file, context: context, relativeTo: context.root)
            } else if let engine = DatabaseEngine(laravel: values["DB_CONNECTION"] ?? "") ?? (values["DB_HOST"] != nil ? .mysql : nil) {
                if engine == .sqlite {
                    let name = set("DB_DATABASE") ?? "database/database.sqlite"
                    let path = name.hasPrefix("/") ? name : context.path(name)
                    c = .sqlite(canonicalPath(path), file: file, keys: dbKeys, exists: isSQLiteFile(path) || isEmptyFile(path))
                } else {
                    c = split(engine, host: set("DB_HOST") ?? "127.0.0.1", port: set("DB_PORT"), user: set("DB_USERNAME"),
                              password: values["DB_PASSWORD"], database: set("DB_DATABASE"), socket: set("DB_SOCKET"),
                              keys: dbKeys, file: file, context: context)
                }
            }
            if var c {
                if context.isLaravel { c.tools.append("Laravel") }
                found.append(c)
            }
        }
        // URL keys: DATABASE_URL and its family, prefixed (NEON2_DATABASE_URL) or not.
        for key in keys where isURLKey(key) && key != "DB_URL" {
            guard let value = set(key), let c = fromURL(value, keys: [key], file: file, context: context, relativeTo: context.root) else { continue }
            found.append(c)
        }
        // libpq, as Neon's integration writes it (PGHOST, and PGHOST_UNPOOLED for the direct host).
        if set("PGHOST") != nil || set("PGDATABASE") != nil {
            let pgKeys = keys.filter { $0.hasPrefix("PG") }
            for hostKey in ["PGHOST", "PGHOST_UNPOOLED"] {
                guard hostKey == "PGHOST" || set(hostKey) != nil else { continue }
                if var c = split(.postgres, host: set(hostKey) ?? "localhost", port: set("PGPORT"), user: set("PGUSER"), password: values["PGPASSWORD"],
                                 database: set("PGDATABASE"), socket: nil, keys: pgKeys, file: file, context: context) {
                    if hostKey == "PGHOST_UNPOOLED" { c.pooled = false }
                    found.append(c)
                }
            }
        }
        // POSTGRES_HOST and friends (Vercel), or POSTGRES_DB for a Compose container.
        if set("POSTGRES_HOST") != nil || set("POSTGRES_DATABASE") != nil || set("POSTGRES_DB") != nil {
            let user = set("POSTGRES_USER") ?? "postgres"
            if let c = split(.postgres, host: set("POSTGRES_HOST") ?? "localhost", port: set("POSTGRES_PORT"), user: user,
                             password: values["POSTGRES_PASSWORD"], database: set("POSTGRES_DATABASE") ?? set("POSTGRES_DB") ?? user,
                             socket: nil, keys: keys.filter { $0.hasPrefix("POSTGRES_") && !isURLKey($0) }, file: file, context: context) {
                found.append(c)
            }
        }
        return found
    }

    /// `*DATABASE_URL*`, `*_UNPOOLED`, `POSTGRES_URL*`, `MYSQL_URL`, `MONGODB_URI`, `TURSO_DATABASE_URL`, `DIRECT_URL`.
    static func isURLKey(_ key: String) -> Bool {
        let k = key.uppercased()
        if k.contains("DATABASE_URL") || k.contains("DATABASE_URI") || k.contains("MONGODB_URI") || k.contains("MONGODB_URL") { return true }
        if k.hasSuffix("_UNPOOLED") || k.hasSuffix("_NON_POOLING") { return true }
        if k.hasPrefix("POSTGRES_") && k.contains("URL") { return true }
        return ["MYSQL_URL", "MONGO_URL", "MONGO_URI", "TURSO_DATABASE_URL", "LIBSQL_URL", "DB_URL", "DIRECT_URL", "SUPABASE_DB_URL"].contains(k)
    }

    static func split(_ engine: DatabaseEngine, host: String, port: String?, user: String?, password: String?, database: String?, socket: String?,
                      keys: [String], file: String, context: Context) -> Candidate? {
        let scheme = engine == .postgres ? "postgresql" : engine == .mariadb ? "mysql" : engine.rawValue
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var text = scheme + "://"
        if let user { text += enc(user) }
        if let password, !password.isEmpty { text += ":" + enc(password) }
        if user != nil || password?.isEmpty == false { text += "@" }
        text += host.contains(":") ? "[\(host)]" : enc(host)
        if let port = port.flatMap({ Int($0) }) { text += ":\(port)" }
        if let database { text += "/" + enc(database) }
        if let socket { text += "?socket=" + (socket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? socket) }
        guard var url = DatabaseURL(text) else { return nil }
        if engine == .mariadb { url = url.with(engine: .mariadb) }
        return Candidate(url: url, keys: keys, file: file, context: context)
    }

    static func fromURL(_ text: String, keys: [String], file: String, context: Context, relativeTo folder: String) -> Candidate? {
        guard let url = DatabaseURL(text) else { return nil }
        if url.engine == .sqlite, let name = url.file {
            var path = name.hasPrefix("/") ? name : (folder as NSString).appendingPathComponent(name)
            // Prisma resolves file: next to its schema.
            if !name.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) {
                let prisma = context.path("prisma/" + name)
                if FileManager.default.fileExists(atPath: prisma) { path = prisma }
            }
            return .sqlite(canonicalPath((path as NSString).standardizingPath), file: file, keys: keys,
                           exists: isSQLiteFile(path) || isEmptyFile(path))
        }
        var c = Candidate(url: url, keys: keys, file: file, context: context)
        let k = keys.first?.uppercased() ?? ""
        if k.hasSuffix("_UNPOOLED") || k.hasSuffix("_NON_POOLING") || k == "DIRECT_URL" { c.pooled = false }
        return c
    }

    /// `supabase/config.toml`: the local stack's database, on the `[db]` port.
    static func supabase(_ context: Context) -> [Candidate] {
        guard let data = Context.small(context.path("supabase/config.toml")) else { return [] }
        var inDB = false
        var port: String?
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inDB = line.hasPrefix("[db]"); continue }
            guard inDB, line.hasPrefix("port"), let eq = line.firstIndex(of: "=") else { continue }
            port = line[line.index(after: eq)...].split(separator: "#").first?.trimmingCharacters(in: .whitespaces)
        }
        // Supabase's documented local password; never in the file, still treated as a secret.
        guard let port, var c = split(.postgres, host: "127.0.0.1", port: port, user: "postgres", password: "postgres", database: "postgres",
                                      socket: nil, keys: ["[db] port"], file: "supabase/config.toml", context: context) else { return [] }
        if !c.providers.contains(.supabase) { c.providers.insert(.supabase, at: 0) }
        c.tools.append("Supabase CLI")
        return [c]
    }

    static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}
