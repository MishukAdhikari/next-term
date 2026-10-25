import Foundation
import Testing
@testable import NextTermCore

/// The sidebar's one scan job: the Databases rows and the Services rows from one read of the project's files, a new
/// scan after a change to any file those readers look at, and a redraw only of a group whose rows changed. Every
/// project, key and value here is made up.
@Suite struct ProjectScanTests {
    /// A Python RAG project on this Mac: OpenAI, Qdrant in Compose, LangSmith and FastAPI.
    static let ragProject: [String: String] = [
        "pyproject.toml": """
        [project]
        name = "support-bot"
        dependencies = ["qdrant-client>=1.15", "openai", "langsmith", "fastapi[standard]"]
        """,
        ".env": """
        OPENAI_API_KEY=sk-test-NOT-A-KEY
        QDRANT_URL=http://qdrant:6333
        LANGSMITH_TRACING=true
        LANGSMITH_API_KEY=lsv2-test-NOT-A-KEY
        LANGSMITH_PROJECT=support-bot
        DATABASE_URL=postgresql://bot:NOT-A-PASSWORD@localhost:5432/support
        """,
        "compose.yaml": composeFile("qdrant", "qdrant/qdrant:v1.15.0", ["6334:6333"]),
    ]

    func summary(_ scan: ServiceScan) -> [String] {
        scan.rows.map { (row: ServiceRow) -> String in row.name + " " + row.link.badge }
    }

    // MARK: one read

    /// One scan gives both groups, the Services rows as their own pass gives them after the Databases pass, and the
    /// fact readers open each file once (`facts.read` records every file they open). The Databases pass's own
    /// connection reads (`EnvFile.read`, the Vercel CLI header, `.vercel/project.json`, `supabase/config.toml`) are
    /// older than this count and outside it; the Services pass opens nothing (`theServicesPassOpensNoFile`).
    @Test func oneScanGivesBothGroupsAndTheFactReadersOpenEachFileOnce() {
        let project = FixtureProject(Self.ragProject)
        let scan = ProjectScan.scan(root: project.root, herdInstalled: false)
        #expect(scan.databases.databases.map(\.name) == ["support"])
        #expect(summary(scan.services) == ["OpenAI Platform", "Qdrant :6334", "LangSmith Projects", "FastAPI :8000"])
        #expect(scan.services == project.services())
        let read = scan.databases.facts.read
        #expect(read.count == Set(read).count, "\(read)")
        #expect(Set(read) == [".env", "compose.yaml", "pyproject.toml"])
        expectNoSecret(scan.services)
    }

    /// The Services pass reads no file: with the project's files gone, the facts the Databases pass handed on give
    /// the same rows.
    @Test func theServicesPassOpensNoFile() throws {
        let project = FixtureProject(Self.ragProject)
        let scan = ProjectScan.scan(root: project.root, herdInstalled: false)
        for file in Self.ragProject.keys { try FileManager.default.removeItem(atPath: project.root + "/" + file) }
        let again = ProjectServices.scan(root: project.root, databases: scan.databases.databases,
                                         facts: scan.databases.facts, herdInstalled: false)
        #expect(again == scan.services)
        #expect(!again.isEmpty)
    }

    // MARK: a redraw only for what a row shows

    /// A change no row shows: a secret's value, a comment, a dependency no service is named by, a new README. Both
    /// groups compare equal, so neither reloads a row.
    @Test func aChangeNoRowShowsLeavesBothGroupsEqual() {
        let project = FixtureProject(Self.ragProject)
        let before = ProjectScan.scan(root: project.root, herdInstalled: false)
        let env = Self.ragProject[".env", default: ""]
        let rotated = env.replacingOccurrences(of: "sk-test-NOT-A-KEY", with: "sk-test-NOT-A-KEY-2")
        project.write(".env", "# keys for the bot\n" + rotated)
        let pyproject = Self.ragProject["pyproject.toml", default: ""]
        project.write("pyproject.toml", pyproject.replacingOccurrences(of: "\"openai\"", with: "\"openai\", \"tqdm\""))
        project.write("README.md", "# Support bot\n")
        let after = ProjectScan.scan(root: project.root, herdInstalled: false)
        #expect(after.databases == before.databases)
        #expect(after.services == before.services)
        #expect(after == before)
    }

    /// A change only the Services rows show (Compose publishes Qdrant on another port) changes those rows and leaves
    /// the Databases group equal, so only Services redraws.
    @Test func aComposePortChangesTheServicesGroupOnly() throws {
        let project = FixtureProject(Self.ragProject)
        let before = ProjectScan.scan(root: project.root, herdInstalled: false)
        project.write("compose.yaml", composeFile("qdrant", "qdrant/qdrant:v1.15.0", ["6335:6333"]))
        let after = ProjectScan.scan(root: project.root, herdInstalled: false)
        #expect(after.databases == before.databases)
        #expect(after.services != before.services)
        let qdrant = try #require(after.services.rows.first { (row: ServiceRow) -> Bool in row.name == "Qdrant" })
        #expect(qdrant.link.url.absoluteString == "http://localhost:6335/dashboard")
    }

    /// A change only a database row shows leaves the Services group equal.
    @Test func aNewDatabaseChangesTheDatabasesGroupOnly() {
        let project = FixtureProject(Self.ragProject)
        let before = ProjectScan.scan(root: project.root, herdInstalled: false)
        let env = Self.ragProject[".env", default: ""]
        project.write(".env", env + "\nCACHE_DATABASE_URL=postgresql://bot:NOT-A-PASSWORD@localhost:5433/cache\n")
        let after = ProjectScan.scan(root: project.root, herdInstalled: false)
        #expect(after.databases != before.databases)
        #expect(after.services == before.services)
    }

    // MARK: what sets off a scan

    /// The folder FSEvents names for a change to `file` (a folder ends in `/` and names itself), relative to the
    /// project: "" for the project's own.
    static func folder(of file: String) -> String {
        let path = file.hasSuffix("/") ? String(file.dropLast()) : (file as NSString).deletingLastPathComponent
        return path
    }

    static func mayChange(_ relative: String, root: String = "/Users/me/support-bot") -> Bool {
        Databases.scanMayChange(after: relative.isEmpty ? root + "/" : root + "/" + relative + "/", root: root)
    }

    /// The readers' own files, from a run of them that opens nothing, with the catalog's marker files: a new reader's
    /// file is watched with no second list to keep.
    @Test func theReadersFilesAreWatched() {
        let watched = Set(ServiceCatalog.watchedFiles)
        let expected = [".env", ".env.local", ".env.example", ".flaskenv", ".env.phoenix", "compose.yaml",
                        "docker-compose.yml", "pyproject.toml", "Pipfile", "package.json", "requirements/", "Procfile",
                        "Makefile", "supabase/.temp/project-ref", "supabase/config.toml", ".ddev/config.yaml",
                        ".streamlit/config.toml", ".vercel/project.json", "src/mastra/index.ts", "vite.config.ts",
                        "wrangler.toml", ".chainlit/config.toml", "langgraph.json", "mlruns/"]
        for file in expected { #expect(watched.contains(file), "\(file)") }
        #expect(ServiceCatalog.watchedFiles.count == watched.count, "each once")
        #expect(!watched.contains("") && !watched.contains("/"))
        let folders = ServiceCatalog.watchedFolders
        for folder in ["supabase/.temp", ".ddev", ".streamlit", ".chainlit", ".vercel", "requirements"] {
            #expect(folders.contains(folder), "\(folder)")
        }
        #expect(!folders.contains(""), "the project's own folder sets off a scan anyway")
    }

    /// A change to any file the readers look at sets off a scan, by the folder FSEvents reports for it.
    @Test func everyWatchedFileCanChangeTheScan() {
        for file in ServiceCatalog.watchedFiles {
            #expect(Self.mayChange(Self.folder(of: file)), "\(file)")
        }
    }

    /// Every file a scan opens is one the readers' listing named, sits in a folder it named (`requirements/dev.txt`),
    /// or is at the project's top (`requirements-dev.txt`); and a change to it sets off a scan.
    @Test func everyFileAScanOpensIsWatched() {
        let files = [".env", ".env.local", ".flaskenv", "compose.yaml", "pyproject.toml", "requirements.txt",
                     "requirements/dev.txt", "package.json", "Procfile", "supabase/.temp/project-ref",
                     "supabase/config.toml", ".ddev/config.yaml", ".streamlit/config.toml", ".chainlit/config.toml",
                     "src/mastra/index.ts", "vite.config.ts", ".vercel/project.json", "wrangler.toml", "fly.toml",
                     "herd.yml", "inngest.json", "trigger.config.ts", ".neon", "cog.yaml"]
        let project = FixtureProject()
        for file in files { project.write(file, "# made up\n") }
        let read = project.scan().facts.read
        // A marker file is looked for, never opened.
        let markers: Set<String> = [".chainlit/config.toml"]
        #expect(Set(read) == Set(files).subtracting(markers), "\(read)")
        let watched = Set(ServiceCatalog.watchedFiles)
        for file in read {
            let folder = Self.folder(of: file)
            let named: Bool = watched.contains(file) || folder.isEmpty || watched.contains(folder + "/")
            #expect(named, "\(file)")
            #expect(Self.mayChange(folder), "\(file)")
        }
    }

    /// The fact readers open only a file whose change sets off a scan, by the folder FSEvents names for it. A reader
    /// that opens a file another one names (an env file `langgraph.json` points at) in a hidden, dependency or deep
    /// folder gets nothing, so its own tests fail before the sidebar could keep a fact that no change refreshes.
    @Test func theReadersOpenOnlyAFileWhoseChangeSetsOffAScan() {
        let opened = [".env", "requirements/dev.txt", "supabase/config.toml", "supabase/.temp/project-ref",
                      ".ddev/config.yaml", ".vercel/project.json", "apps/agent/.env"]
        let refused = [".config/agent.env", "apps/.agent/.env", "node_modules/pkg/package.json", "a/b/c/d/notes.txt",
                       "storage/framework/x.env"]
        let project = FixtureProject()
        for file in opened + refused { project.write(file, "# made up\n") }
        var reader = FactReader(root: project.root)
        for file in opened { #expect(reader.text(file) == "# made up\n", "\(file)") }
        for file in refused {
            #expect(reader.text(file) == nil, "\(file)")
            #expect(!Self.mayChange(Self.folder(of: file), root: project.root), "\(file)")
        }
        #expect(reader.opened == opened)
    }

    // MARK: printing

    /// A printed scan, as a log or a debugger shows it, names kinds and counts only: each database row's engine,
    /// whether a Vercel project is linked, the Services rows' ids and the facts' counts. No host, user, port, path,
    /// project name or value.
    @Test func aPrintedScanShowsKindsAndCountsOnly() {
        var files = Self.ragProject
        files[".env"] = """
        OPENAI_API_KEY=sk-test-NOT-A-KEY
        QDRANT_URL=http://qdrant:6333/?api_key=NOT-A-KEY
        DATABASE_URL=postgresql://made-up-user:NOT-A-PASSWORD@db.made-up.example:5544/support
        """
        files[".vercel/project.json"] = #"{"projectId":"prj_madeup1","orgId":"team_madeup1","projectName":"made-up-app"}"#
        let project = FixtureProject(files)
        project.write("database/app.sqlite", data: Data("SQLite format 3\0".utf8) + Data(count: 84))
        let scan = ProjectScan.scan(root: project.root, herdInstalled: false)
        #expect(scan.databases.databases.count == 2)
        #expect(scan.databases.isVercelLinked)
        var dumped = ""
        dump(scan, to: &dumped)
        let secrets = ["NOT-A-", "sk-test", "api_key", "made-up-user", "db.made-up.example", "5544", "made-up-app",
                       "prj_madeup1", "team_madeup1", project.root, "app.sqlite", "support"]
        for text in [String(describing: scan), String(reflecting: scan), dumped, "\(scan)"] {
            for secret in secrets { #expect(!text.contains(secret), "\(secret) in \(text)") }
            #expect(text.contains("postgres") && text.contains("sqlite"), "\(text)")
        }
        #expect(String(describing: scan).hasPrefix("ProjectScan("))
    }
}
