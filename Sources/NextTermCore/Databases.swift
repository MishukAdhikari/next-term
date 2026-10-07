import Foundation

// MARK: - what a connection is

public enum DatabaseEngine: String, Sendable, CaseIterable {
    case mysql, mariadb, postgres, sqlite, mongodb, libsql, sqlserver, cockroach

    public var displayName: String {
        switch self {
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .postgres: return "PostgreSQL"
        case .sqlite: return "SQLite"
        case .mongodb: return "MongoDB"
        case .libsql: return "libSQL"
        case .sqlserver: return "SQL Server"
        case .cockroach: return "CockroachDB"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .mysql, .mariadb: return 3306
        case .postgres: return 5432
        case .mongodb: return 27017
        case .sqlserver: return 1433
        case .cockroach: return 26257
        case .sqlite, .libsql: return nil
        }
    }

    /// A URL scheme (`postgres`, `mysql2`, `mongodb+srv`, `prisma+postgres`).
    init?(scheme: String) {
        switch scheme.lowercased() {
        case "postgres", "postgresql", "prisma+postgres", "pg": self = .postgres
        case "mysql", "mysql2", "mysqlx": self = .mysql
        case "mariadb": self = .mariadb
        case "mongodb", "mongodb+srv": self = .mongodb
        case "libsql": self = .libsql
        case "sqlserver", "mssql": self = .sqlserver
        case "cockroachdb", "cockroach": self = .cockroach
        default: return nil
        }
    }

    /// Laravel's `DB_CONNECTION`.
    init?(laravel name: String) {
        switch name.lowercased() {
        case "mysql": self = .mysql
        case "mariadb": self = .mariadb
        case "pgsql", "postgres", "postgresql": self = .postgres
        case "sqlite": self = .sqlite
        case "sqlsrv": self = .sqlserver
        case "mongodb": self = .mongodb
        default: return nil
        }
    }

    /// Prisma's datasource `provider`, or Drizzle's `dialect`.
    init?(orm name: String) {
        switch name.lowercased() {
        case "postgresql", "postgres", "pg": self = .postgres
        case "mysql", "singlestore": self = .mysql
        case "sqlite": self = .sqlite
        case "turso": self = .libsql
        case "sqlserver", "mssql": self = .sqlserver
        case "mongodb": self = .mongodb
        case "cockroachdb": self = .cockroach
        default: return nil
        }
    }
}

public enum DatabaseProvider: String, Sendable, CaseIterable {
    case vercel = "Vercel", neon = "Neon", supabase = "Supabase", herd = "Herd", planetScale = "PlanetScale"
    case prismaPostgres = "Prisma Postgres", turso = "Turso", mongoAtlas = "MongoDB Atlas"

    /// The Vercel Marketplace slug, for `vercel integration open <slug>`.
    public var vercelSlug: String? {
        switch self {
        case .neon: return "neon"
        case .supabase: return "supabase"
        case .prismaPostgres: return "prisma"
        default: return nil
        }
    }

    /// Named from the host only.
    static func from(host: String?, user: String?) -> DatabaseProvider? {
        guard let host = host?.lowercased() else { return nil }
        if host.hasSuffix(".neon.tech") { return .neon }
        if host.hasSuffix(".supabase.co") || host.hasSuffix(".supabase.com") { return .supabase }
        if host.hasSuffix(".psdb.cloud") { return .planetScale }
        if host == "db.prisma.io" || host.hasSuffix(".prisma-data.net") { return .prismaPostgres }
        if host.hasSuffix(".turso.io") { return .turso }
        if host.hasSuffix(".mongodb.net") { return .mongoAtlas }
        return nil
    }
}

/// Where a connection points, from its host alone: an env file's name says nothing (a `.env.local`
/// that `vercel env pull` wrote for Development often holds the production URL).
public enum DatabaseEnvironment: String, Sendable {
    /// This Mac: loopback, a Unix socket, `*.test`, `*.localhost`, a SQLite file.
    case local
    /// A container on this Mac (Docker, OrbStack).
    case development
    /// Anything else, treated as production.
    case remote
    /// Not a connection (only the shape of one, from `.env.example` or an ORM's config).
    case unknown

    public static func classify(host: String?, socket: String? = nil) -> DatabaseEnvironment {
        if let socket, !socket.isEmpty { return .local }
        guard var host = host?.lowercased().trimmingCharacters(in: .whitespaces), !host.isEmpty else { return .local }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasPrefix("/") { return .local } // a socket folder
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" || host == "0.0.0.0" || isLoopbackIPv4(host) { return .local }
        if host.hasSuffix(".localhost") || host.hasSuffix(".test") { return .local }
        if host == "host.docker.internal" || host == "docker.for.mac.localhost" || host.hasSuffix(".docker.internal")
            || host.hasSuffix(".orb.local") { return .development }
        // A Compose service reached by its name.
        if composeServices.contains(host) { return .development }
        return .remote
    }

    /// 127.0.0.0/8, written as four numbers (not `127.0.0.1.nip.io`, which can resolve anywhere).
    static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    static let composeServices: Set<String> = ["db", "database", "mysql", "mariadb", "postgres", "postgresql", "pgsql", "pg",
                                               "mongo", "mongodb", "sqlserver", "mssql"]

    /// Terminal hand-offs (`mysql`, `psql`) are offered here only.
    public var allowsTerminal: Bool { self == .local || self == .development }
}

/// A database a project's own files describe. It holds no secret: a hand-off reads the password again
/// from the file (`Databases.credentials(for:root:)`) at the moment it needs it.
public struct DetectedDatabase: Sendable, Equatable, Identifiable {
    public struct Source: Sendable, Equatable {
        /// Relative to the project.
        public let file: String
        public let keys: [String]
        /// A pooler's URL (Neon's `-pooler` host, Supabase's pooler, `POSTGRES_URL`).
        public let pooled: Bool
    }

    /// Stable across scans: the engine, where it is and which database, never a secret.
    public let id: String
    public let engine: DatabaseEngine
    /// The database's name, or the file's.
    public let name: String
    public let host: String?
    public let port: Int?
    public let user: String?
    public let database: String?
    public let socket: String?
    /// Most specific first (Neon before Vercel).
    public let providers: [DatabaseProvider]
    public let environment: DatabaseEnvironment
    /// The connection with its password and secret parameters replaced by `•••`.
    public let masked: String
    /// Where it was found, the hand-off's choice first (a direct URL before a pooled one).
    public let sources: [Source]
    /// SQLite: the file, absolute.
    public let filePath: String?
    public let hasPassword: Bool
    /// False for the shape of a connection only (`.env.example`, an ORM pointing at an unset key):
    /// nothing connects to it.
    public let isConnection: Bool
    /// Why it is not a connection, or what else to know ("Pooled and direct URLs").
    public let note: String?
    /// Frameworks and ORMs that read it: Laravel, Prisma, Drizzle.
    public let tools: [String]

    /// The file it was read from first, relative to the project.
    public var sourceFile: String? { sources.first?.file }
    public var hasPooledAndDirect: Bool { sources.contains { $0.pooled } && sources.contains { !$0.pooled } }
}

/// What a hand-off needs and nothing else may see. Its descriptions are redacted, so printing it or
/// interpolating it into a string shows no secret.
public struct DatabaseCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let password: String?
    /// The full URL, password included, for TablePlus.
    public let url: URL?

    public var description: String { "DatabaseCredentials(\(DatabaseMask.dots))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the scan found in one project.
public struct DatabaseScan: Sendable, Equatable {
    public var databases: [DetectedDatabase] = []
    /// `.vercel/project.json` links the folder to a Vercel project.
    public var vercelProject: String?
    public var isVercelLinked: Bool { vercelProject != nil }
    public var isEmpty: Bool { databases.isEmpty }

    public init(databases: [DetectedDatabase] = [], vercelProject: String? = nil) {
        self.databases = databases
        self.vercelProject = vercelProject
    }
}
