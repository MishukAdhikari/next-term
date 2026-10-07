import Foundation
import Testing
@testable import NextTermCore

/// A project folder on disk, removed afterwards.
final class FixtureProject {
    let root: String

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = canonicalPath(url.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func write(_ relative: String, _ text: String) {
        let path = (root as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func write(_ relative: String, data: Data) {
        let path = (root as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    func scan(herd: Bool = false) -> DatabaseScan { Databases.scan(root: root, herdInstalled: herd) }
}

/// Every string the UI could show about a database, for "no secret anywhere" checks.
func visibleText(_ scan: DatabaseScan) -> String {
    scan.databases.map { db in
        [db.id, db.name, db.masked, db.note ?? "", db.host ?? "", db.user ?? "", db.database ?? "", db.socket ?? "",
         db.sources.map { $0.file + " " + $0.keys.joined(separator: " ") }.joined(separator: " "), String(describing: db),
         String(reflecting: db), db.tools.joined(separator: " ")].joined(separator: "\n")
    }.joined(separator: "\n") + String(describing: scan)
}

@Suite struct DatabasesTests {
    // MARK: Laravel and Herd

    static let laravelEnv = """
    APP_NAME=Shop
    APP_ENV=local
    APP_KEY=base64:Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE=
    APP_URL=http://shop.test

    LOG_CHANNEL=stack

    DB_CONNECTION=mysql
    DB_HOST=127.0.0.1
    DB_PORT=3306
    DB_DATABASE=shop
    DB_USERNAME=root
    DB_PASSWORD="s3cr#t p@ss/word" # not a comment inside the quotes

    REDIS_HOST=127.0.0.1
    """

    @Test func laravelSplitKeysMakeOneLocalMySQLRow() throws {
        let project = FixtureProject()
        project.write("artisan", "#!/usr/bin/env php\n")
        project.write(".env", Self.laravelEnv)
        let scan = project.scan(herd: true)
        #expect(scan.databases.count == 1)
        let db = try #require(scan.databases.first)
        #expect(db.engine == .mysql && db.name == "shop" && db.environment == .local)
        #expect(db.host == "127.0.0.1" && db.port == 3306 && db.user == "root" && db.hasPassword)
        #expect(db.providers == [.herd])
        #expect(db.tools == ["Laravel"])
        #expect(db.masked == "mysql://root:•••@127.0.0.1:3306/shop")
        #expect(db.sources.first?.file == ".env" && db.sources.first?.keys.first == "DB_CONNECTION")
        #expect(!visibleText(scan).contains("s3cr#t"))
        let credentials = try #require(Databases.credentials(for: db, root: project.root, herdInstalled: true))
        #expect(credentials.password == "s3cr#t p@ss/word")
        #expect(!String(describing: credentials).contains("s3cr") && !String(reflecting: credentials).contains("s3cr"))
        #expect(credentials.url?.absoluteString.hasPrefix("mysql://root:s3cr%23t%20p%40ss%2Fword@127.0.0.1:3306/shop") == true)
    }

    @Test func herdBadgeNeedsHerd() {
        let project = FixtureProject()
        project.write(".env", Self.laravelEnv)
        #expect(project.scan(herd: false).databases.first?.providers == [])
    }

    @Test func emptyLocalRootPassword() throws {
        let project = FixtureProject()
        project.write(".env", "DB_CONNECTION=mysql\nDB_HOST=localhost\nDB_DATABASE=blog\nDB_USERNAME=root\nDB_PASSWORD=\n")
        let db = try #require(project.scan().databases.first)
        #expect(!db.hasPassword && db.masked == "mysql://root@localhost/blog" && db.environment == .local)
        #expect(Databases.credentials(for: db, root: project.root)?.password == nil)
    }

    @Test func laravelElevenSQLiteDefault() throws {
        let project = FixtureProject()
        project.write(".env", """
        DB_CONNECTION=sqlite
        # DB_HOST=127.0.0.1
        # DB_PORT=3306
        # DB_DATABASE=laravel
        # DB_USERNAME=root
        # DB_PASSWORD=
        """)
        project.write("database/database.sqlite", "")
        let scan = project.scan()
        #expect(scan.databases.count == 1)
        let db = try #require(scan.databases.first)
        #expect(db.engine == .sqlite && db.name == "database.sqlite" && db.isConnection && db.environment == .local)
        #expect(db.filePath == project.root + "/database/database.sqlite")
    }

    @Test func dbURLWinsOverSplitKeys() throws {
        let project = FixtureProject()
        project.write(".env", "DB_CONNECTION=pgsql\nDB_HOST=127.0.0.1\nDB_URL=postgresql://app:hunter2@db.internal.example.com:5432/app\n")
        let db = try #require(project.scan().databases.first)
        #expect(db.engine == .postgres && db.host == "db.internal.example.com" && db.environment == .remote)
        #expect(!visibleText(project.scan()).contains("hunter2"))
    }

    // MARK: Next.js, Prisma, Neon, Vercel

    static let vercelNeonEnv = """
    # Created by Vercel CLI
    DATABASE_URL="postgresql://neondb_owner:npg_A1b2C3d4E5f6@ep-cool-river-a5b6c7d8-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require"
    DATABASE_URL_UNPOOLED="postgresql://neondb_owner:npg_A1b2C3d4E5f6@ep-cool-river-a5b6c7d8.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require"
    NEON_PROJECT_ID="young-sun-12345678"
    PGDATABASE="neondb"
    PGHOST="ep-cool-river-a5b6c7d8-pooler.us-east-2.aws.neon.tech"
    PGHOST_UNPOOLED="ep-cool-river-a5b6c7d8.us-east-2.aws.neon.tech"
    PGPASSWORD="npg_A1b2C3d4E5f6"
    PGUSER="neondb_owner"
    POSTGRES_DATABASE="neondb"
    POSTGRES_HOST="ep-cool-river-a5b6c7d8-pooler.us-east-2.aws.neon.tech"
    POSTGRES_PASSWORD="npg_A1b2C3d4E5f6"
    POSTGRES_PRISMA_URL="postgresql://neondb_owner:npg_A1b2C3d4E5f6@ep-cool-river-a5b6c7d8-pooler.us-east-2.aws.neon.tech/neondb?connect_timeout=15&sslmode=require"
    POSTGRES_URL="postgresql://neondb_owner:npg_A1b2C3d4E5f6@ep-cool-river-a5b6c7d8-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require"
    POSTGRES_URL_NON_POOLING="postgresql://neondb_owner:npg_A1b2C3d4E5f6@ep-cool-river-a5b6c7d8.us-east-2.aws.neon.tech/neondb?sslmode=require"
    POSTGRES_URL_NO_SSL="postgresql://neondb_owner:npg_A1b2C3d4E5f6@ep-cool-river-a5b6c7d8-pooler.us-east-2.aws.neon.tech/neondb"
    POSTGRES_USER="neondb_owner"
    VERCEL_OIDC_TOKEN="eyJhbGciOiJSUzI1NiJ9.e30.c2lnbmF0dXJl"
    """

    @Test func vercelPulledNeonIsOneRemoteRow() throws {
        let project = FixtureProject()
        project.write(".vercel/project.json", #"{"projectId":"prj_abc123","orgId":"team_xyz","projectName":"acme-web"}"#)
        project.write(".env.local", Self.vercelNeonEnv)
        project.write("prisma/schema.prisma", """
        generator client {
          provider = "prisma-client-js"
        }

        datasource db {
          provider  = "postgresql"
          url       = env("DATABASE_URL")
          directUrl = env("DATABASE_URL_UNPOOLED")
        }
        """)
        let scan = project.scan()
        #expect(scan.vercelProject == "acme-web")
        #expect(scan.databases.count == 1, "\(scan.databases.map(\.id))")
        let db = try #require(scan.databases.first)
        #expect(db.engine == .postgres && db.name == "neondb" && db.environment == .remote)
        #expect(db.providers == [.neon, .vercel])
        #expect(db.tools == ["Prisma"])
        #expect(db.hasPooledAndDirect && db.note?.contains("direct") == true)
        // The hand-off's choice comes first: the direct URL, not the pooler.
        #expect(db.sources.first?.keys == ["DATABASE_URL_UNPOOLED"] && db.sources.first?.pooled == false)
        #expect(db.host == "ep-cool-river-a5b6c7d8.us-east-2.aws.neon.tech")
        #expect(db.masked == "postgresql://neondb_owner:•••@ep-cool-river-a5b6c7d8.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require")
        #expect(!visibleText(scan).contains("npg_A1b2C3d4E5f6") && !visibleText(scan).contains("eyJhbGci"))
        let credentials = try #require(Databases.credentials(for: db, root: project.root))
        #expect(credentials.password == "npg_A1b2C3d4E5f6")
        #expect(credentials.url?.host == "ep-cool-river-a5b6c7d8.us-east-2.aws.neon.tech")
    }

    @Test func prefixedVercelKeysAndALocalDatabaseBeside() throws {
        let project = FixtureProject()
        project.write(".env", "DATABASE_URL=postgresql://postgres:postgres@localhost:5432/acme_dev\n")
        project.write(".env.development.local", """
        NEON2_DATABASE_URL=postgres://reader:pw_9f8e7d@ep-small-sky-123456.eu-central-1.aws.neon.tech/analytics?sslmode=require
        """)
        let scan = project.scan()
        #expect(scan.databases.map(\.name) == ["analytics", "acme_dev"])
        #expect(scan.databases.map(\.environment) == [.remote, .local])
        #expect(scan.databases.first?.sources.first?.keys == ["NEON2_DATABASE_URL"])
    }

    @Test func fileNameNeverSetsTheTag() throws {
        // .env.development.local, as `vercel env pull` writes it, with the production database in it.
        let project = FixtureProject()
        project.write(".env.development.local", "# Created by Vercel CLI\nPOSTGRES_URL=\"postgres://default:Xy9_prod@ep-prod-db-998877.us-east-1.aws.neon.tech:5432/verceldb?sslmode=require\"\n")
        let db = try #require(project.scan().databases.first)
        #expect(db.environment == .remote && db.providers == [.neon, .vercel])
        #expect(!db.environment.allowsTerminal)
    }

    // MARK: Supabase

    @Test func supabaseLocalStackMergesWithItsURL() throws {
        let project = FixtureProject()
        project.write("supabase/config.toml", """
        project_id = "acme"

        [api]
        enabled = true
        port = 54321

        [db]
        # Port to use for the local database URL.
        port = 54322
        shadow_port = 54320
        major_version = 15
        """)
        project.write(".env", "DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres\n")
        let scan = project.scan()
        #expect(scan.databases.count == 1)
        let db = try #require(scan.databases.first)
        #expect(db.port == 54322 && db.environment == .local && db.providers == [.supabase])
        #expect(db.sources.map(\.file) == [".env", "supabase/config.toml"])
    }

    @Test func hostedSupabasePoolerAndDirectAreOneDatabase() throws {
        let project = FixtureProject()
        project.write(".env", """
        DATABASE_URL="postgresql://postgres.abcdefghijklmnop:Sup4_secret@aws-0-us-east-1.pooler.supabase.com:6543/postgres?pgbouncer=true"
        DIRECT_URL="postgresql://postgres:Sup4_secret@db.abcdefghijklmnop.supabase.co:5432/postgres"
        NEXT_PUBLIC_SUPABASE_URL=https://abcdefghijklmnop.supabase.co
        """)
        let scan = project.scan()
        #expect(scan.databases.count == 1)
        let db = try #require(scan.databases.first)
        #expect(db.providers == [.supabase] && db.environment == .remote && db.hasPooledAndDirect)
        #expect(db.host == "db.abcdefghijklmnop.supabase.co")
        #expect(!visibleText(scan).contains("Sup4_secret"))
    }

    // MARK: environment from the host

    @Test func environmentComesFromTheHost() {
        #expect(DatabaseEnvironment.classify(host: "127.0.0.1") == .local)
        #expect(DatabaseEnvironment.classify(host: "localhost") == .local)
        #expect(DatabaseEnvironment.classify(host: "::1") == .local)
        #expect(DatabaseEnvironment.classify(host: "[::1]") == .local)
        #expect(DatabaseEnvironment.classify(host: "shop.test") == .local)
        #expect(DatabaseEnvironment.classify(host: nil, socket: "/Users/me/Library/Application Support/Herd/mysql.sock") == .local)
        #expect(DatabaseEnvironment.classify(host: "/var/run/postgresql") == .local)
        #expect(DatabaseEnvironment.classify(host: "host.docker.internal") == .development)
        #expect(DatabaseEnvironment.classify(host: "postgres.acme.orb.local") == .development)
        #expect(DatabaseEnvironment.classify(host: "db") == .development)
        #expect(DatabaseEnvironment.classify(host: "10.0.0.5") == .remote)
        #expect(DatabaseEnvironment.classify(host: "db.example.com") == .remote)
        #expect(DatabaseEnvironment.classify(host: "localhost.example.com") == .remote)
        #expect(DatabaseEnvironment.classify(host: "127.0.0.1.nip.io") == .remote)
    }

    @Test func remoteMySQLIsTaggedRemote() throws {
        let project = FixtureProject()
        project.write(".env", "DB_CONNECTION=mysql\nDB_HOST=mysql-prod.c9akciq32.eu-west-1.rds.amazonaws.com\nDB_DATABASE=shop\nDB_USERNAME=admin\nDB_PASSWORD=Rds!2024\n")
        let db = try #require(project.scan().databases.first)
        #expect(db.environment == .remote && db.providers.isEmpty && db.name == "shop")
    }

    // MARK: examples, ORMs, other engines

    @Test func exampleIsShapeOnlyAndOnlyWithoutALiveFile() throws {
        let project = FixtureProject()
        project.write(".env.example", "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_DATABASE=laravel\nDB_USERNAME=root\nDB_PASSWORD=\n")
        let db = try #require(project.scan().databases.first)
        #expect(!db.isConnection && db.environment == .unknown && db.note?.contains(".env.example") == true)
        #expect(Databases.credentials(for: db, root: project.root) == nil)
        project.write(".env", "DB_CONNECTION=mysql\nDB_DATABASE=shop\n")
        let live = project.scan()
        #expect(live.databases.count == 1 && live.databases.first?.isConnection == true && live.databases.first?.name == "shop")
    }

    @Test func drizzleKeyThatNothingSets() throws {
        let project = FixtureProject()
        project.write("drizzle.config.ts", """
        import { defineConfig } from "drizzle-kit";
        export default defineConfig({
          out: "./drizzle",
          schema: "./src/db/schema.ts",
          dialect: "postgresql",
          dbCredentials: { url: process.env.DATABASE_URL! },
        });
        """)
        let db = try #require(project.scan().databases.first)
        #expect(!db.isConnection && db.engine == .postgres && db.name == "DATABASE_URL" && db.tools == ["Drizzle"])
        project.write(".env", "DATABASE_URL=postgres://postgres:pw@localhost:5432/app\n")
        let live = try #require(project.scan().databases.first)
        #expect(live.isConnection && live.tools == ["Drizzle"] && project.scan().databases.count == 1)
    }

    @Test func prismaSQLiteFileNextToTheSchema() throws {
        let project = FixtureProject()
        project.write("prisma/schema.prisma", "datasource db {\n  provider = \"sqlite\"\n  url      = env(\"DATABASE_URL\")\n}\n")
        project.write(".env", "DATABASE_URL=\"file:./dev.db\"\n")
        project.write("prisma/dev.db", data: Data("SQLite format 3\0".utf8) + Data(count: 84))
        let scan = project.scan()
        #expect(scan.databases.count == 1, "\(scan.databases.map(\.id))")
        let db = try #require(scan.databases.first)
        #expect(db.engine == .sqlite && db.filePath == project.root + "/prisma/dev.db" && db.tools == ["Prisma"])
    }

    @Test func mongoAndTurso() throws {
        let project = FixtureProject()
        project.write(".env", """
        MONGODB_URI=mongodb+srv://app:M0ngo_pw@cluster0.ab1cd.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0
        TURSO_DATABASE_URL=libsql://acme-db-acme.turso.io
        TURSO_AUTH_TOKEN=eyJhbGciOiJFZERTQSJ9.turso.token
        LEGACY_MONGO_URL=mongodb://a:pw2@m1.example.net:27017,m2.example.net:27017/legacy?replicaSet=rs0
        """)
        let scan = project.scan()
        let mongo = try #require(scan.databases.first { $0.engine == .mongodb && $0.providers == [.mongoAtlas] })
        #expect(mongo.name == "cluster0" && mongo.environment == .remote && mongo.masked.hasPrefix("mongodb+srv://app:•••@cluster0"))
        let turso = try #require(scan.databases.first { $0.engine == .libsql })
        #expect(turso.providers == [.turso] && turso.environment == .remote)
        #expect(!visibleText(scan).contains("M0ngo_pw") && !visibleText(scan).contains("turso.token"))
    }

    // MARK: SQLite files

    @Test func sqliteFilesByHeaderNotExtension() {
        let project = FixtureProject()
        let header = Data("SQLite format 3\0".utf8) + Data(count: 84)
        project.write("database/database.sqlite", data: header)
        project.write("data/cache.db", data: header)
        project.write("notes.db", "not a database")
        project.write("node_modules/pkg/test.sqlite", data: header)
        project.write(".git/x.db", data: header)
        project.write("a/b/c/d/deep.sqlite3", data: header)
        let names = project.scan().databases.map(\.name).sorted()
        #expect(names == ["cache.db", "database.sqlite"])
    }

    // MARK: parsing

    @Test func envParsingSurvivesMalformedLines() {
        let entries = EnvFile.parse("""
        \u{FEFF}# comment
        export PGHOST=db.local
        this line is not valid
        =novalue
        1BAD=x
        DB_HOST
        SPACED = value with spaces   # trailing comment
        SINGLE='literal ${PGHOST} #not-comment'
        DOUBLE="line1\\nline2 ${PGHOST}"
        URL=postgres://u:p#w@h/db
        HASH=a#b
        KEY="-----BEGIN KEY-----
        abc
        -----END KEY-----"
        UNCLOSED="abc
        AFTER=1\r
        """)
        let values = EnvFile.values(entries)
        #expect(values["PGHOST"] == "db.local")
        #expect(values["SPACED"] == "value with spaces")
        #expect(values["SINGLE"] == "literal ${PGHOST} #not-comment")
        #expect(values["DOUBLE"] == "line1\nline2 db.local")
        #expect(values["URL"] == "postgres://u:p#w@h/db")
        #expect(values["HASH"] == "a#b")
        #expect(values["KEY"] == "-----BEGIN KEY-----\nabc\n-----END KEY-----")
        #expect(values["UNCLOSED"] == "abc")
        #expect(values["AFTER"] == "1")
        #expect(values["1BAD"] == nil && values["DB_HOST"] == nil && values[""] == nil)
    }

    @Test func urlParsingAndMasking() throws {
        let raw = try #require(DatabaseURL("mysql://root:p@ss/w?rd@127.0.0.1:3307/app?charset=utf8mb4"))
        #expect(raw.user == "root" && raw.password == "p@ss/w?rd" && raw.host == "127.0.0.1" && raw.port == 3307 && raw.database == "app")
        let socket = try #require(DatabaseURL("postgresql:///app?host=/var/run/postgresql&user=me"))
        #expect(socket.socket == "/var/run/postgresql" && socket.host == nil && socket.user == "me" && socket.database == "app")
        let v6 = try #require(DatabaseURL("postgres://u@[::1]:5433/x"))
        #expect(v6.host == "::1" && v6.port == 5433)
        let accelerate = try #require(DatabaseURL("prisma+postgres://accelerate.prisma-data.net/?api_key=eyJsecret"))
        #expect(accelerate.masked == "prisma+postgres://accelerate.prisma-data.net/?api_key=•••")
        #expect(DatabaseURL("https://example.com") == nil && DatabaseURL("not a url") == nil)
    }

    // MARK: terminal hand-off

    @Test func clientCommandsNeverCarryThePassword() throws {
        let project = FixtureProject()
        project.write(".env", Self.laravelEnv)
        let mysql = try #require(project.scan().databases.first)
        let line = DatabaseClientCommand.commandLine(for: mysql, program: "/opt/homebrew/bin/mysql", secretFile: "/tmp/x/a b.cnf")
        #expect(line == "/opt/homebrew/bin/mysql '--defaults-extra-file=/tmp/x/a b.cnf' --host=127.0.0.1 --port=3306 --user=root shop")
        #expect(!line.contains("s3cr"))
        #expect(DatabaseClientCommand.secretFileContents(for: .mysql, password: #"a"b\c"#) == "[client]\npassword=\"a\\\"b\\\\c\"\n")

        project.write(".env", "DATABASE_URL=postgres://app:pg:pass\\word@localhost:5433/app_dev\n")
        let pg = try #require(project.scan().databases.first)
        let args = DatabaseClientCommand.arguments(for: pg, program: "psql", secretFile: "/tmp/p.pgpass")
        #expect(args == ["psql", "host='localhost' port='5433' dbname='app_dev' user='app' passfile='/tmp/p.pgpass'"])
        #expect(!args.joined().contains("pass\\word"))
        #expect(DatabaseClientCommand.secretFileContents(for: .postgres, password: #"pg:pass\word"#) == #"*:*:*:*:pg\:pass\\word"# + "\n")
    }

    @Test func redactorCoversErrorText() {
        let text = DatabaseMask.redact("connection to postgres://app:Hunter2@db.example.com/app failed; retry with password=Hunter2&sslmode=require")
        #expect(!text.contains("Hunter2") && text.contains("postgres://app:•••@db.example.com/app") && text.contains("sslmode=require"))
    }
}
