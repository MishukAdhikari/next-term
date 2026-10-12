import Foundation
import Testing
@testable import NextTermCore

/// Whole made-up projects, one per kind of work (Python RAG here and in the cloud, a JS app, Python and TypeScript
/// agents, a PHP site), and the exact Services rows each gives: their order, badges, links and tooltips, with no
/// made-up key value anywhere.
@Suite struct ServiceProjectsTests {
    func summary(_ scan: ServiceScan) -> [String] {
        scan.rows.map { (row: ServiceRow) -> String in row.name + " " + row.link.badge }
    }

    func row(_ scan: ServiceScan, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> ServiceRow {
        try #require(scan.rows.first { (row: ServiceRow) -> Bool in row.name == name }, "\(summary(scan))",
                     sourceLocation: sourceLocation)
    }

    @Test func aPythonRAGProjectOnThisMac() throws {
        let project = FixtureProject([
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
            """,
            "compose.yaml": composeFile("qdrant", "qdrant/qdrant:v1.15.0", ["6334:6333"]),
        ])
        let scan = project.services()
        #expect(summary(scan) == ["OpenAI Platform", "Qdrant :6334", "LangSmith Projects", "FastAPI :8000"])
        let qdrant = try row(scan, "Qdrant")
        #expect(qdrant.link.url.absoluteString == "http://localhost:6334/dashboard")
        #expect(qdrant.tooltip.contains("(from compose.yaml)"))
        let langsmith = try row(scan, "LangSmith")
        #expect(langsmith.link.url.absoluteString == "https://smith.langchain.com")
        #expect(langsmith.tooltip.contains("Project: support-bot"))
        let fastAPI = try row(scan, "FastAPI")
        #expect(fastAPI.link.url.absoluteString == "http://localhost:8000/docs")
        #expect(fastAPI.tooltip.contains("(default port)"))
        expectNoSecret(scan)
    }

    @Test func aPythonRAGProjectInTheCloud() throws {
        let project = FixtureProject([".env": """
        QDRANT_URL=https://abc-123.eu-central-1-0.aws.cloud.qdrant.io:6333?api_key=NOT-A-KEY
        PINECONE_API_KEY=pc-NOT-A-KEY
        LANGSMITH_ENDPOINT=https://eu.api.smith.langchain.com
        LANGSMITH_API_KEY=lsv2-NOT-A-KEY
        """])
        let scan = project.services()
        #expect(summary(scan) == ["Qdrant Dashboard", "Pinecone Console", "LangSmith Projects"])
        #expect(try row(scan, "Qdrant").link.url.absoluteString
            == "https://abc-123.eu-central-1-0.aws.cloud.qdrant.io:6333/dashboard")
        #expect(try row(scan, "Pinecone").link.url.absoluteString
            == "https://app.pinecone.io/organizations/-/projects/-/indexes")
        #expect(try row(scan, "LangSmith").link.url.absoluteString == "https://eu.smith.langchain.com")
        expectNoSecret(scan)
    }

    static let jsApp: [String: String] = [
        "package.json": packageJSON(["next", "@supabase/supabase-js", "@upstash/redis", "@ai-sdk/anthropic"],
                                    scripts: ["dev": "next dev -p 3100"]),
        ".env.local": """
        NEXT_PUBLIC_SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co
        KV_REST_API_URL=https://wise-cat-12345.upstash.io
        KV_REST_API_TOKEN=NOT-A-TOKEN
        ANTHROPIC_API_KEY=NOT-A-KEY
        """,
        ".vercel/project.json": #"{"projectId": "prj_abc123", "orgId": "team_abc123", "projectName": "shop-web"}"#,
    ]

    @Test func aJSApp() throws {
        let scan = FixtureProject(Self.jsApp).services()
        #expect(summary(scan) == ["Anthropic Console", "Next.js :3100", "Supabase Dashboard", "Upstash Console",
                                  "Vercel Dashboard"])
        let next = try row(scan, "Next.js")
        #expect(next.link.tooltip == "Open Next.js at localhost:3100 (from package.json's dev script)")
        #expect(try row(scan, "Supabase").link.url.absoluteString
            == "https://supabase.com/dashboard/project/abcdefghijklmnopqrst")
        #expect(try row(scan, "Vercel").tooltip.contains("Project: shop-web"))
        expectNoSecret(scan)
    }

    /// The database row carries Supabase, with the same page, so the services list leaves it out.
    @Test func aJSAppWithItsSupabaseDatabase() throws {
        var files = Self.jsApp
        files[".env"] = "DATABASE_URL=postgres://app:NOT-A-PASSWORD@db.abcdefghijklmnopqrst.supabase.co:5432/postgres\n"
        let project = FixtureProject(files)
        let database = try #require(project.scan().databases.first)
        #expect(database.links.first?.url.absoluteString == "https://supabase.com/dashboard/project/abcdefghijklmnopqrst")
        let scan = project.services()
        #expect(!scan.rows.contains { (row: ServiceRow) -> Bool in row.entryID == "supabase" })
        #expect(summary(scan) == ["Anthropic Console", "Next.js :3100", "Upstash Console", "Vercel Dashboard"])
        expectNoSecret(scan)
    }

    /// `vercel env pull` writes the database's URL to `.env.local`, so its row carries Vercel too. That badge opens the
    /// team's storage, not the project: the Vercel hosting row stays, with its project's name. Only Supabase leaves.
    @Test func aVercelLinkedJSAppWithItsSupabaseDatabase() throws {
        var files = Self.jsApp
        let url = "DATABASE_URL=postgres://app:NOT-A-PASSWORD@db.abcdefghijklmnopqrst.supabase.co:5432/postgres"
        files[".env.local"] = (files[".env.local"] ?? "") + "\n" + url + "\n"
        let project = FixtureProject(files)
        let database = try #require(project.scan().databases.first)
        #expect(database.providers == [.supabase, .vercel])
        let scan = project.services()
        #expect(summary(scan) == ["Anthropic Console", "Next.js :3100", "Upstash Console", "Vercel Dashboard"])
        let vercel = try row(scan, "Vercel")
        #expect(vercel.link.url.absoluteString == "https://vercel.com/dashboard")
        #expect(vercel.tooltip.contains("Project: shop-web"))
        expectNoSecret(scan)
    }
}

// MARK: - Agents, a PHP site, and what never opens

extension ServiceProjectsTests {
    @Test func aPythonAgentProject() throws {
        let project = FixtureProject([
            "langgraph.json": #"{"graphs": {"agent": "./src/agent.py:graph"}}"#,
            "pyproject.toml": """
            [project]
            name = "agent"
            dependencies = ["langgraph", "langgraph-cli[inmem]", "anthropic", "langfuse"]

            [tool.poe.tasks]
            dev = "langgraph dev --port 2100"
            """,
            "compose.yaml": composeFile("langfuse-web", "langfuse/langfuse:3", ["3030:3000"]),
            ".env": """
            ANTHROPIC_API_KEY=NOT-A-KEY
            LANGFUSE_HOST=http://localhost:3030
            LANGFUSE_SECRET_KEY=sk-lf-NOT-A-KEY
            LANGFUSE_PUBLIC_KEY=pk-lf-NOT-A-KEY
            """,
        ])
        let scan = project.services()
        #expect(summary(scan) == ["Anthropic Console", "Langfuse :3030", "LangGraph Studio"])
        #expect(try row(scan, "Langfuse").link.url.absoluteString == "http://localhost:3030")
        #expect(try row(scan, "LangGraph").link.url.absoluteString
            == "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2100")
        #expect(!project.scan().facts.envValues.contains { (fact: ServiceFact) -> Bool in fact.key == "LANGFUSE_PUBLIC_KEY" })
        expectNoSecret(scan)
    }

    @Test func aTypeScriptAgentProject() throws {
        let project = FixtureProject([
            "package.json": packageJSON(["@mastra/core", "@trigger.dev/sdk", "inngest"]),
            "src/mastra/index.ts": "export const mastra = new Mastra({ server: { port: 4200 } })\n",
            "trigger.config.ts": "export default defineConfig({ project: \"proj_abcdefghijklmnop\" })\n",
        ])
        let scan = project.services()
        #expect(summary(scan) == ["Inngest :8288", "Mastra :4200", "Trigger.dev Project"])
        #expect(try row(scan, "Inngest").tooltip.contains("(default port)"))
        #expect(try row(scan, "Mastra").link.tooltip == "Open Mastra Studio at localhost:4200 (from src/mastra/index.ts)")
        #expect(try row(scan, "Trigger.dev").link.url.absoluteString
            == "https://cloud.trigger.dev/projects/v3/proj_abcdefghijklmnop")
        expectNoSecret(scan)
    }

    @Test func aPHPSite() throws {
        let herd = FixtureProject(["artisan": "\n", ".env": "APP_URL=https://shop.test\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\n"])
        let database = try #require(herd.scan(herd: true).databases.first)
        #expect(database.links.first?.url.absoluteString == "https://shop.test")
        #expect(herd.services(herd: true).rows.isEmpty, "the database row's badge opens the site")
        let ddev = FixtureProject([".ddev/config.yaml": "name: shop\ntype: laravel\n", "artisan": "\n"])
        let scan = ddev.services()
        #expect(summary(scan) == ["DDEV Site"])
        #expect(try row(scan, "DDEV").links.map { (link: ServiceLink) -> String in link.url.absoluteString }
            == ["https://shop.ddev.site", "https://shop.ddev.site:8026"])
    }

    /// No unsafe value opens: a script, a file path, a value that names another, plain http off this Mac. Each tool
    /// falls back to what Compose or its own default on this Mac gives, or makes no row; never to a vendor's page.
    @Test func nothingUnsafeOpens() throws {
        let project = FixtureProject([".env": """
        N8N_EDITOR_BASE_URL=javascript:alert(1)
        MLFLOW_TRACKING_URI=file:///tmp/mlruns
        WEAVIATE_URL=${WEAVIATE_HOST}
        LANGFUSE_HOST=http://langfuse.example.com
        """])
        let scan = project.services()
        #expect(summary(scan) == ["MLflow :5000"])
        #expect(try row(scan, "MLflow").link.url.absoluteString == "http://127.0.0.1:5000")
        let text = serviceText(scan)
        for value in ["javascript", "alert", "/tmp/mlruns", "WEAVIATE_HOST", "langfuse.example.com"] {
            #expect(!text.contains(value), "\(value)")
        }
        expectNoSecret(scan)
    }

    @Test func aPortAloneNamesNothing() {
        let project = FixtureProject(["compose.yaml": composeFile("api", "example/api:1", ["8000:8000"])])
        #expect(project.services().rows.isEmpty)
    }
}
