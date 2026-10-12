import Foundation
import Testing
@testable import NextTermCore

/// The Services rows a whole project gives: which services, in which order, with which badges, links, tooltips and
/// sources, and never a key's value. Every project, key and value here is made up.
@Suite struct ProjectServicesTests {
    func row(_ scan: ServiceScan, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> ServiceRow {
        try #require(scan.rows.first { (row: ServiceRow) -> Bool in row.id == id }, "\(scan.rows.map(\.id))",
                     sourceLocation: sourceLocation)
    }

    func urls(_ row: ServiceRow) -> [String] {
        row.links.map { (link: ServiceLink) -> String in link.url.absoluteString }
    }

    // MARK: AI models

    @Test func aKeyAndADependencyNameOneRowWithBothSources() throws {
        let project = FixtureProject([".env": "OPENAI_API_KEY=sk-test-NOT-A-KEY\n", "requirements.txt": "openai>=1.0\n"])
        let scan = project.services()
        #expect(scan.rows.map(\.id) == ["openai.cloud"])
        let openAI = try row(scan, "openai.cloud")
        #expect(openAI.kind == .aiModel && openAI.place == .cloud && openAI.entryID == "openai")
        #expect(openAI.sources == [ServiceSource(file: ".env", names: ["OPENAI_API_KEY"]),
                                   ServiceSource(file: "requirements.txt", names: ["openai"])])
        #expect(openAI.detail == "AI model · .env")
        #expect(openAI.tooltip == "Open OpenAI Platform\nFrom .env: OPENAI_API_KEY; requirements.txt: openai")
        let titles = openAI.links.map(\.title)
        #expect(titles == ["Open OpenAI Platform", "Open OpenAI API Keys", "Open OpenAI Usage"])
        #expect(urls(openAI) == ["https://platform.openai.com/", "https://platform.openai.com/settings/organization/api-keys",
                                 "https://platform.openai.com/usage"])
        #expect(openAI.link.id == "openai.platform" && openAI.link.source == nil)
        expectNoSecret(scan)
    }

    @Test func theAgentsSDKAddsOpenAITraces() throws {
        let project = FixtureProject(["requirements.txt": "openai-agents\nopenai\n"])
        let openAI = try row(project.services(), "openai.cloud")
        #expect(openAI.links.last?.title == "Open OpenAI Traces")
        #expect(openAI.links.last?.url.absoluteString == "https://platform.openai.com/traces")
    }

    @Test func aBaseURLNamesTheProviderOfItsHost() throws {
        let project = FixtureProject(["requirements.txt": "openai\n",
                                      ".env": "OPENAI_BASE_URL=https://openrouter.ai/api/v1\nOPENAI_API_KEY=sk-or-NOT-A-KEY\n"])
        let scan = project.services()
        #expect(scan.rows.map(\.id) == ["openrouter.cloud"])
        let openRouter = try row(scan, "openrouter.cloud")
        #expect(openRouter.sources == [ServiceSource(file: ".env", names: ["OPENAI_BASE_URL"])])
        #expect(urls(openRouter) == ["https://openrouter.ai/activity", "https://openrouter.ai/settings/credits"])
        expectNoSecret(scan)
    }

    @Test func aLoopbackBaseURLNamesNoCloudProvider() {
        let project = FixtureProject(["requirements.txt": "openai\n", ".env": "OPENAI_BASE_URL=http://localhost:11434/v1\n"])
        #expect(project.services().rows.isEmpty)
    }

    @Test func theSDKsOwnHostKeepsItsProvider() {
        let project = FixtureProject([".env": "OPENAI_BASE_URL=https://api.openai.com/v1\nOPENAI_API_KEY=NOT-A-KEY\n"])
        #expect(project.services().rows.map(\.id) == ["openai.cloud"])
    }

    @Test func aBaseURLThatNamesAnotherValueRoutesNothing() {
        // Unresolved, so where it points is not known: the SDK's own provider stays.
        let project = FixtureProject([".env": "ANTHROPIC_BASE_URL=${PROXY_URL}\nANTHROPIC_API_KEY=NOT-A-KEY\n"])
        #expect(project.services().rows.map(\.id) == ["anthropic.cloud"])
    }

    @Test func googlesKeyNamesAIStudioOnlyBesideAGeminiDependency() throws {
        let alone = FixtureProject([".env": "GOOGLE_API_KEY=NOT-A-KEY\n"])
        #expect(alone.services().rows.isEmpty)
        let project = FixtureProject([".env": "GOOGLE_API_KEY=NOT-A-KEY\n", "requirements.txt": "google-genai\n"])
        let studio = try row(project.services(), "google-ai-studio.cloud")
        #expect(studio.sources == [ServiceSource(file: ".env", names: ["GOOGLE_API_KEY"]),
                                   ServiceSource(file: "requirements.txt", names: ["google-genai"])])
        #expect(urls(studio) == ["https://aistudio.google.com/apikey", "https://aistudio.google.com/usage"])
    }

    @Test func bedrockOpensTheRegionsConsoleOrTheHome() throws {
        let gov = FixtureProject([".env": "AWS_BEARER_TOKEN_BEDROCK=NOT-A-TOKEN\nAWS_REGION=us-gov-west-1\n"])
        let govRow = try row(gov.services(), "aws-bedrock.cloud")
        #expect(govRow.link.url.absoluteString
            == "https://console.amazonaws-us-gov.com/bedrock/home?region=us-gov-west-1")
        #expect(govRow.link.tooltip == "Open AWS Bedrock Console: us-gov-west-1")
        let bad = FixtureProject([".env": "CLAUDE_CODE_USE_BEDROCK=1\nAWS_REGION=eu-west-1/../x\n"])
        #expect(try row(bad.services(), "aws-bedrock.cloud").link.url.absoluteString == "https://console.aws.amazon.com/bedrock/")
        let host = FixtureProject([".env": "ANTHROPIC_BEDROCK_BASE_URL=https://bedrock-runtime.eu-west-1.amazonaws.com\n"])
        #expect(host.services().rows.isEmpty, "a base URL key the catalog does not read names nothing")
    }

    @Test func vertexWithoutAProjectOpensModelGarden() throws {
        let project = FixtureProject([".env": "GOOGLE_GENAI_USE_VERTEXAI=true\nGOOGLE_CLOUD_PROJECT=Not_A_Project\n"])
        let vertex = try row(project.services(), "vertex-ai.cloud")
        #expect(vertex.link.url.absoluteString == "https://console.cloud.google.com/vertex-ai/model-garden")
        let named = FixtureProject([".env": "GOOGLE_GENAI_USE_VERTEXAI=true\nGOOGLE_CLOUD_PROJECT=shop-ai-123\n"])
        let link = try row(named.services(), "vertex-ai.cloud").link
        #expect(link.url.absoluteString == "https://console.cloud.google.com/vertex-ai/model-garden?project=shop-ai-123")
        #expect(link.tooltip == "Open Vertex AI Console: project shop-ai-123" && link.source == ".env")
    }

    @Test func azureNamesItsResourceInTheTooltipOnly() throws {
        let project = FixtureProject([".env": "AZURE_OPENAI_API_KEY=NOT-A-KEY\nAZURE_OPENAI_ENDPOINT=https://shop-ai.openai.azure.com/\n"])
        let azure = try row(project.services(), "azure-openai.cloud")
        #expect(azure.notes == ["Resource: shop-ai"])
        #expect(azure.link.url.absoluteString == "https://ai.azure.com/")
        #expect(azure.tooltip.contains("Resource: shop-ai"))
    }

    @Test func replicateWithoutAModelOpensTheTokens() throws {
        let project = FixtureProject([".env": "REPLICATE_API_TOKEN=r8_NOT-A-TOKEN\n"])
        let replicate = try row(project.services(), "replicate.cloud")
        #expect(replicate.link.url.absoluteString == "https://replicate.com/account/api-tokens")
    }

    @Test func aiModelsAreInTheirRankOrder() {
        let project = FixtureProject([".env": "FIREWORKS_API_KEY=NOT-A-KEY\nGROQ_API_KEY=NOT-A-KEY\nANTHROPIC_API_KEY=NOT-A-KEY\n",
                                      "requirements.txt": "openai\nmistralai\n"])
        let ids = project.services().rows.map(\.entryID)
        #expect(ids == ["openai", "anthropic", "mistral", "groq", "fireworks"])
    }

    @Test func theScanPrintsIdsAndCountsOnly() {
        let project = FixtureProject([".env": "OPENAI_API_KEY=sk-test-NOT-A-KEY\nAWS_REGION=eu-west-1\nCLAUDE_CODE_USE_BEDROCK=1\n"])
        let scan = project.services()
        #expect(String(describing: scan) == "ServiceScan(rows: [openai.cloud, aws-bedrock.cloud])")
        #expect(!String(describing: scan.rows[1]).contains("eu-west-1"))
        expectNoSecret(scan)
    }
}

// MARK: - Vector stores

extension ProjectServicesTests {
    @Test func aComposeServiceInAURLOpensItsPublishedPort() throws {
        let project = FixtureProject([".env": "QDRANT_URL=http://qdrant:6333\n",
                                      "requirements.txt": "qdrant-client\n",
                                      "compose.yaml": composeFile("qdrant", "qdrant/qdrant:v1.15.0", ["6334:6333"])])
        let scan = project.services()
        #expect(scan.rows.map(\.id) == ["qdrant.local"])
        let qdrant = try row(scan, "qdrant.local")
        #expect(urls(qdrant) == ["http://localhost:6334/dashboard"])
        #expect(qdrant.link.badge == ":6334" && qdrant.link.source == "compose.yaml")
        #expect(qdrant.link.tooltip == "Open Qdrant Dashboard at localhost:6334 (from compose.yaml)")
        #expect(qdrant.tooltip.hasPrefix("Open Qdrant Dashboard at localhost:6334 (from compose.yaml), if it is running\n"))
        #expect(qdrant.sources == [ServiceSource(file: ".env", names: ["QDRANT_URL"]),
                                   ServiceSource(file: "compose.yaml", names: ["qdrant/qdrant"]),
                                   ServiceSource(file: "requirements.txt", names: ["qdrant-client"])])
        #expect(qdrant.detail == "vector store · compose.yaml")
        expectNoSecret(scan)
    }

    @Test func aCloudURLOpensItsDashboardWithoutItsQuery() throws {
        let value = "https://abc-123.eu-central-1-0.aws.cloud.qdrant.io:6333?api_key=NOT-A-KEY"
        let project = FixtureProject([".env": "QDRANT_URL=\(value)\nPINECONE_API_KEY=pc-NOT-A-KEY\n"])
        let scan = project.services()
        #expect(scan.rows.map(\.id) == ["qdrant.cloud", "pinecone.cloud"])
        let qdrant = try row(scan, "qdrant.cloud")
        #expect(qdrant.name == "Qdrant" && qdrant.link.badge == "Dashboard")
        #expect(urls(qdrant) == ["https://abc-123.eu-central-1-0.aws.cloud.qdrant.io:6333/dashboard", "https://cloud.qdrant.io"])
        #expect(qdrant.links.map(\.title) == ["Open Qdrant Dashboard", "Open Qdrant Console"])
        let pinecone = try row(scan, "pinecone.cloud")
        #expect(urls(pinecone) == ["https://app.pinecone.io/organizations/-/projects/-/indexes"])
        expectNoSecret(scan)
    }

    @Test func aStoreOnThisMacAndInTheCloudGivesTwoRows() throws {
        let project = FixtureProject([".env.local": "QDRANT_URL=https://abc-123.cloud.qdrant.io\n",
                                      "compose.yaml": composeFile("qdrant", "qdrant/qdrant", ["6334:6333"])])
        let scan = project.services()
        #expect(scan.rows.map(\.name) == ["Qdrant", "Qdrant Cloud"])
        let local = try row(scan, "qdrant.local")
        #expect(urls(local) == ["http://localhost:6334/dashboard"])
        #expect(local.sources == [ServiceSource(file: "compose.yaml", names: ["qdrant/qdrant"])])
        let cloud = try row(scan, "qdrant.cloud")
        #expect(cloud.link.url.absoluteString == "https://abc-123.cloud.qdrant.io:6333/dashboard")
        #expect(cloud.link.title == "Open Qdrant Cloud Dashboard")
        #expect(cloud.sources == [ServiceSource(file: ".env.local", names: ["QDRANT_URL"])])
    }

    /// The project said where its server is, in a form no link may use: no vendor page stands in, but Compose still
    /// runs one here.
    @Test func aRefusedURLFallsBackOnlyToCompose() throws {
        let alone = FixtureProject([".env": "QDRANT_URL=${QDRANT_HOST}\n", "requirements.txt": "qdrant-client\n"])
        #expect(alone.services().rows.isEmpty)
        let composed = FixtureProject([".env": "QDRANT_URL=https://${QDRANT_HOST}\n",
                                       "compose.yaml": composeFile("qdrant", "qdrant/qdrant", ["6333:6333"])])
        let qdrant = try row(composed.services(), "qdrant.local")
        #expect(urls(qdrant) == ["http://localhost:6333/dashboard"])
        #expect(!qdrant.tooltip.contains("QDRANT_HOST"))
    }

    @Test func chromaTakesItsHostAndPortKeys() throws {
        let local = FixtureProject([".env": "CHROMA_HOST=localhost\nCHROMA_PORT=8100\n"])
        let chroma = try row(local.services(), "chroma.local")
        #expect(urls(chroma) == ["http://localhost:8100/docs"])
        #expect(chroma.link.tooltip == "Open Chroma API Docs at localhost:8100 (from .env)")
        let cloud = FixtureProject([".env": "CHROMA_HOST=api.trychroma.com\n"])
        #expect(try row(cloud.services(), "chroma.cloud").link.url.absoluteString == "https://www.trychroma.com/dashboard")
    }

    @Test func milvusOnThisMacOpensItsWebUIAndAttu() throws {
        let compose = """
        services:
          standalone:
            image: milvusdb/milvus:v2.6.0
            ports:
              - "19530:19530"
              - "9092:9091"
          attu:
            image: zilliz/attu:v2.6
            ports:
              - "8000:3000"
        """
        let milvus = try row(FixtureProject(["compose.yaml": compose]).services(), "milvus.local")
        #expect(urls(milvus) == ["http://localhost:9092/webui", "http://localhost:8000"])
        #expect(milvus.links.map(\.title) == ["Open Milvus WebUI", "Open Milvus Attu"])
        let lite = FixtureProject([".env": "MILVUS_URI=./milvus_demo.db\n", "requirements.txt": "pymilvus\n"])
        #expect(lite.services().rows.isEmpty)
    }
}

// MARK: - Tracing

extension ProjectServicesTests {
    @Test func langSmithOpensItsRegionsSiteAndNamesTheProject() throws {
        let project = FixtureProject([".env": """
        LANGSMITH_ENDPOINT=https://eu.api.smith.langchain.com
        LANGSMITH_API_KEY=lsv2-NOT-A-KEY
        LANGSMITH_PROJECT=support-bot
        """])
        let langsmith = try row(project.services(), "langsmith.cloud")
        #expect(urls(langsmith) == ["https://eu.smith.langchain.com"])
        #expect(langsmith.notes == ["Project: support-bot"])
        #expect(langsmith.tooltip == """
        Open LangSmith Projects at eu.smith.langchain.com
        Project: support-bot
        From .env: LANGSMITH_API_KEY, LANGSMITH_ENDPOINT
        """)
        expectNoSecret(project.services())
    }

    /// The project placed its server where no link may go: no vendor page stands in. Compose still runs one here.
    @Test func aRefusedServerLeavesNoVendorPage() throws {
        let remote = FixtureProject([".env": "LANGFUSE_HOST=http://langfuse.example.com\nLANGFUSE_SECRET_KEY=NOT-A-KEY\n",
                                     "requirements.txt": "langfuse\n"])
        #expect(remote.services().rows.isEmpty)
        let composed = FixtureProject([".env": "LANGFUSE_HOST=http://langfuse.example.com\n",
                                       "compose.yaml": composeFile("langfuse-web", "docker.langfuse.com/langfuse/langfuse:4",
                                                                   ["3000:3000"])])
        let langfuse = try row(composed.services(), "langfuse.local")
        #expect(urls(langfuse) == ["http://localhost:3000"])
        let endpoint = FixtureProject([".env": "LANGSMITH_ENDPOINT=${LANGSMITH_HOST}\nLANGSMITH_TRACING=true\n"])
        #expect(endpoint.services().rows.isEmpty)
    }

    @Test func aLocalLangfuseOpensTheAddressTheProjectGives() throws {
        let project = FixtureProject([".env": """
        LANGFUSE_HOST=http://localhost:3030
        LANGFUSE_SECRET_KEY=sk-lf-NOT-A-KEY
        LANGFUSE_PUBLIC_KEY=pk-lf-NOT-A-KEY
        """, "compose.yaml": composeFile("langfuse-web", "langfuse/langfuse:3", ["3030:3000"])])
        let scan = project.services()
        #expect(scan.rows.map(\.id) == ["langfuse.local"])
        let langfuse = try row(scan, "langfuse.local")
        #expect(urls(langfuse) == ["http://localhost:3030"])
        #expect(langfuse.link.badge == ":3030" && langfuse.link.title == "Open Langfuse Projects")
        #expect(!String(describing: project.scan().facts).contains("LANGFUSE_PUBLIC_KEY"), "its value is never read")
        expectNoSecret(scan)
    }

    @Test func mlflowOpensItsServerExperimentOrItsLocalUI() throws {
        let server = FixtureProject([".env": "MLFLOW_TRACKING_URI=https://mlflow.example.com\nMLFLOW_EXPERIMENT_ID=7\n"])
        let remote = try row(server.services(), "mlflow.cloud")
        #expect(urls(remote) == ["https://mlflow.example.com/#/experiments/7"])
        #expect(remote.link.tooltip == "Open MLflow Experiment at mlflow.example.com")
        let databricks = FixtureProject([".env": "MLFLOW_TRACKING_URI=https://dbc-1234.cloud.databricks.com\nMLFLOW_EXPERIMENT_ID=42\n"])
        #expect(try row(databricks.services(), "mlflow.cloud").link.url.absoluteString
            == "https://dbc-1234.cloud.databricks.com/ml/experiments/42")
        let store = FixtureProject([".env": "MLFLOW_TRACKING_URI=file:///tmp/mlruns\n"])
        let local = try row(store.services(), "mlflow.local")
        #expect(urls(local) == ["http://127.0.0.1:5000"])
        #expect(local.link.tooltip
            == "Open MLflow Experiments at 127.0.0.1:5000 (default port; macOS AirPlay Receiver also listens on 5000)")
        let script = FixtureProject(["Makefile": "ui:\n\tmlflow ui --port 5050\n"])
        #expect(try row(script.services(), "mlflow.local").link.tooltip
            == "Open MLflow Experiments at 127.0.0.1:5050 (from Makefile's ui target)")
    }

    @Test func braintrustEncodesItsProjectsName() throws {
        let project = FixtureProject([".env": """
        BRAINTRUST_API_KEY=NOT-A-KEY
        BRAINTRUST_ORG_NAME=acme
        BRAINTRUST_DEFAULT_PROJECT="My App"
        BRAINTRUST_APP_URL=https://braintrust.example.com
        """])
        let braintrust = try row(project.services(), "braintrust.cloud")
        #expect(urls(braintrust) == ["https://braintrust.example.com/app/acme/p/My%20App/logs"])
        let dots = FixtureProject([".env": "BRAINTRUST_API_KEY=NOT-A-KEY\nBRAINTRUST_ORG_NAME=acme\nBRAINTRUST_DEFAULT_PROJECT=..\n"])
        #expect(try row(dots.services(), "braintrust.cloud").link.url.absoluteString == "https://www.braintrust.dev/app")
    }

    @Test func weaveFindsItsAppAsWandbDoes() throws {
        let project = FixtureProject([".env": "WANDB_BASE_URL=https://api.ml.example.com\nWANDB_ENTITY=acme\nWANDB_PROJECT=bot\n"])
        #expect(try row(project.services(), "wandb-weave.cloud").link.url.absoluteString
            == "https://app.ml.example.com/acme/bot/weave")
        let home = FixtureProject(["requirements.txt": "weave\n"])
        #expect(try row(home.services(), "wandb-weave.cloud").link.url.absoluteString == "https://wandb.ai/home")
    }

    @Test func phoenixAndHeliconeFollowTheirEndpoints() throws {
        let cloud = FixtureProject([".env": "PHOENIX_COLLECTOR_ENDPOINT=https://app.phoenix.arize.com/s/acme/v1/traces\n"])
        #expect(try row(cloud.services(), "arize-phoenix.cloud").link.url.absoluteString == "https://app.phoenix.arize.com")
        let port = FixtureProject([".env.phoenix": "PHOENIX_PORT=6100\n"])
        #expect(try row(port.services(), "arize-phoenix.local").link.url.absoluteString == "http://localhost:6100/projects")
        let eu = FixtureProject([".env": "ANTHROPIC_BASE_URL=https://eu.helicone.ai/anthropic\n"])
        let scan = eu.services()
        #expect(scan.rows.map(\.id) == ["helicone.cloud"])
        #expect(try row(scan, "helicone.cloud").link.url.absoluteString == "https://eu.helicone.ai/requests")
    }
}

// MARK: - Agents

extension ProjectServicesTests {
    @Test func studioOpensOnTheLangSmithSiteForTheDevServersPort() throws {
        let project = FixtureProject(["langgraph.json": "{}\n", "Makefile": "dev:\n\tuv run langgraph dev --port 2100\n",
                                      ".env": "LANGSMITH_ENDPOINT=https://eu.api.smith.langchain.com\n"])
        let langGraph = try row(project.services(), "langgraph.local")
        #expect(urls(langGraph) == ["https://eu.smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2100",
                                    "http://127.0.0.1:2100/docs"])
        #expect(langGraph.link.badge == "Studio")
        #expect(langGraph.link.tooltip == "Open LangGraph Studio at 127.0.0.1:2100 (from Makefile's dev target)")
        #expect(langGraph.links.map(\.title) == ["Open LangGraph Studio", "Open LangGraph API Docs"])
    }

    @Test func temporalOpensItsDevUIOrItsCloudNamespace() throws {
        let cloud = FixtureProject([".env": "TEMPORAL_ADDRESS=shop.a1b2c.tmprl.cloud:7233\n"])
        let namespace = try row(cloud.services(), "temporal.cloud")
        #expect(namespace.name == "Temporal Cloud")
        #expect(urls(namespace) == ["https://cloud.temporal.io/namespaces/shop.a1b2c"])
        #expect(namespace.link.tooltip == "Open Temporal Cloud Namespace: namespace shop.a1b2c")
        let compose = FixtureProject(["compose.yaml": composeFile("temporal-ui", "temporalio/ui:2.40.0", ["8081:8080"]),
                                      ".env": "TEMPORAL_ADDRESS=localhost:7233\n"])
        let ui = try row(compose.services(), "temporal.local")
        #expect(urls(ui) == ["http://localhost:8081"])
        #expect(ui.link.tooltip == "Open Temporal UI at localhost:8081 (from compose.yaml)")
        let script = FixtureProject(["Procfile": "temporal: temporal server start-dev --port 7300\n"])
        #expect(try row(script.services(), "temporal.local").link.url.absoluteString == "http://localhost:8300")
    }

    @Test func inngestKeepsItsCloudBesideTheDevServer() throws {
        let project = FixtureProject(["package.json": #"{"dependencies": {"inngest": "^3.40.0"}}"#,
                                      "inngest.json": #"{"port": 8299}"#])
        let inngest = try row(project.services(), "inngest.local")
        #expect(urls(inngest) == ["http://localhost:8299", "https://app.inngest.com"])
        #expect(inngest.links.map(\.title) == ["Open Inngest Dev Server", "Open Inngest Cloud"])
        #expect(inngest.links.map(\.badge) == [":8299", "Cloud"])
    }

    @Test func n8nOpensItsEditorsOriginNeverItsPath() throws {
        let project = FixtureProject([".env": "N8N_EDITOR_BASE_URL=https://n8n.example.com/webhook/NOT-A-SECRET-PATH\n"])
        let n8n = try row(project.services(), "n8n.cloud")
        #expect(urls(n8n) == ["https://n8n.example.com"])
        expectNoSecret(project.services())
    }
}

// MARK: - Local servers

extension ProjectServicesTests {
    @Test func aDefaultPortSaysSo() throws {
        let project = FixtureProject(["pyproject.toml": "[project]\nname = \"api\"\ndependencies = [\"fastapi\"]\n"])
        let fastAPI = try row(project.services(), "fastapi.local")
        #expect(fastAPI.link.title == "Open FastAPI Docs" && fastAPI.link.badge == ":8000")
        #expect(fastAPI.tooltip == """
        Open FastAPI Docs at localhost:8000 (default port), if it is running
        From pyproject.toml: fastapi
        """)
        #expect(fastAPI.isLocal && fastAPI.link.source == nil)
    }

    @Test func aPortComesFromTheFilesInOrder() throws {
        let django = FixtureProject(["manage.py": "\n", "requirements.txt": "django\n",
                                     "Procfile": "web: python manage.py runserver 0.0.0.0:8001\n"])
        let row1 = try row(django.services(), "django.local")
        #expect(row1.link.url.absoluteString == "http://127.0.0.1:8001")
        #expect(row1.link.tooltip == "Open Django at 127.0.0.1:8001 (from Procfile's web process)")
        let vite = FixtureProject(["package.json": packageJSON(["vite"], scripts: ["dev": "vite --port 6000"]),
                                   "vite.config.ts": "export default defineConfig({ server: { https: true, port: 5180 } })\n"])
        let row2 = try row(vite.services(), "vite.local")
        #expect(row2.link.url.absoluteString == "https://localhost:5180")
        #expect(row2.link.tooltip == "Open Vite at localhost:5180 (from vite.config.ts)")
        let flask = FixtureProject(["requirements.txt": "flask\n", ".env": "FLASK_RUN_PORT=${PORT}\n"])
        #expect(try row(flask.services(), "flask.local").link.tooltip
            == "Open Flask at 127.0.0.1:5000 (default port; macOS AirPlay Receiver also listens on 5000)")
    }

    @Test func aPortAloneNamesNothing() {
        let project = FixtureProject(["compose.yaml": composeFile("api", "example/api:1", ["8000:8000"]),
                                      "Procfile": "web: gunicorn app:app --port 3000\n"])
        #expect(project.services().rows.isEmpty)
    }

    @Test func ddevOpensItsSiteAndMailpit() throws {
        let project = FixtureProject([".ddev/config.yaml": "name: shop\ntype: laravel\nmailpit_https_port: \"8126\"\n"])
        let ddev = try row(project.services(), "ddev.local")
        #expect(urls(ddev) == ["https://shop.ddev.site", "https://shop.ddev.site:8126"])
        #expect(ddev.links.map(\.title) == ["Open DDEV Site", "Open DDEV Mailpit"])
        #expect(ddev.link.tooltip == "Open DDEV Site at shop.ddev.site")
        let tld = FixtureProject([".ddev/config.yaml": "name: shop\nproject_tld: site.example\nrouter_https_port: 8443\n"])
        #expect(urls(try row(tld.services(), "ddev.local")) == ["https://shop.site.example:8443", "https://shop.site.example:8026"])
    }

    @Test func aTestSiteIsHerdsOrValets() throws {
        let valet = FixtureProject([".env": "APP_URL=http://shop.test\n"])
        let site = try row(valet.services(), "herd.local")
        #expect(site.name == "Valet" && urls(site) == ["http://shop.test"])
        #expect(site.link.tooltip == "Open Valet Site at shop.test (from .env)")
        #expect(try row(valet.services(herd: true), "herd.local").name == "Herd")
        let userinfo = FixtureProject([".env": "APP_URL=http://admin:NOT-A-PASSWORD@shop.test\n"])
        #expect(userinfo.services(herd: true).rows.isEmpty)
        expectNoSecret(userinfo.services(herd: true))
    }

    /// The database row's Herd badge opens the site already, so the services list does not repeat it.
    @Test func aDatabaseRowsHerdIsNotListedAgain() {
        let project = FixtureProject(["artisan": "\n", ".env": "APP_URL=https://shop.test\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\n"])
        let databases = project.scan(herd: true)
        #expect(databases.databases.contains { (db: DetectedDatabase) -> Bool in db.providers.contains(.herd) })
        #expect(!project.services(herd: true).rows.contains { (row: ServiceRow) -> Bool in row.entryID == "herd" })
        #expect(project.services(herd: false).rows.map(\.id) == ["herd.local"])
    }
}

// MARK: - Backends

extension ProjectServicesTests {
    /// A database row that carries Supabase shows its page; the services list does not repeat it.
    @Test func aDatabaseRowsProviderIsNotListedAgain() throws {
        let files: [String: String] = [
            ".env.local": "NEXT_PUBLIC_SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co\n",
            "package.json": packageJSON(["@supabase/supabase-js"]),
        ]
        let alone = FixtureProject(files)
        let supabase = try row(alone.services(), "supabase.cloud")
        #expect(supabase.link.tooltip == "Open Supabase Dashboard: project abcdefghijklmnopqrst")
        #expect(supabase.link.source == ".env.local")
        var withDatabase = files
        withDatabase[".env"] = "DATABASE_URL=postgres://app:NOT-A-PASSWORD@db.abcdefghijklmnopqrst.supabase.co:5432/postgres\n"
        let project = FixtureProject(withDatabase)
        #expect(project.scan().databases.first?.providers == [.supabase])
        #expect(project.services().rows.isEmpty)
        expectNoSecret(project.services())
    }

    /// The local stack opens Studio, unless its database row shows Studio already; `config.toml`'s `project_id` is a
    /// local name, never a ref.
    @Test func theLocalStackOpensStudioUnlessItsDatabaseRowDoes() throws {
        let bare = FixtureProject(["package.json": packageJSON(["@supabase/supabase-js"]),
                                   "supabase/config.toml": "project_id = \"shop\"\n\n[studio]\nport = 54423\n"])
        let local = try row(bare.services(), "supabase.local")
        #expect(urls(local) == ["http://127.0.0.1:54423", "http://127.0.0.1:54324"])
        #expect(local.links.map(\.title) == ["Open Supabase Studio", "Open Supabase Email"])
        #expect(local.link.tooltip == "Open Supabase Studio at 127.0.0.1:54423 (from supabase/config.toml)")
        #expect(!local.tooltip.contains("shop"))
        let withDatabase = FixtureProject(["supabase/config.toml": "project_id = \"shop\"\n\n[db]\nport = 54322\n"])
        #expect(withDatabase.scan().databases.first?.providers == [.supabase])
        #expect(withDatabase.services().rows.isEmpty)
        let cloud = FixtureProject(["package.json": packageJSON(["@supabase/supabase-js"])])
        #expect(try row(cloud.services(), "supabase.cloud").link.url.absoluteString
            == "https://supabase.com/dashboard/project/_")
    }

    @Test func oneUpstashRowHasAPageForEachProduct() throws {
        let project = FixtureProject([".env": """
        UPSTASH_REDIS_REST_URL=https://wise-cat-12345.upstash.io
        UPSTASH_REDIS_REST_TOKEN=NOT-A-TOKEN
        UPSTASH_VECTOR_REST_URL=https://shop-vectors-12345-us1-vector.upstash.io
        UPSTASH_VECTOR_REST_TOKEN=NOT-A-TOKEN
        """])
        let scan = project.services()
        #expect(scan.rows.map(\.id) == ["upstash.cloud"])
        let upstash = try row(scan, "upstash.cloud")
        #expect(upstash.links.map(\.title) == ["Open Upstash Redis", "Open Upstash Vector"])
        #expect(urls(upstash) == ["https://console.upstash.com/redis", "https://console.upstash.com/vector"])
        let vector = try row(FixtureProject([".env": "UPSTASH_VECTOR_REST_URL=https://v.upstash.io\n"]).services(),
                             "upstash.cloud")
        #expect(urls(vector) == ["https://console.upstash.com/vector"])
        expectNoSecret(scan)
    }

    @Test func firebaseOpensItsEmulatorUIBesideTheConsole() throws {
        let project = FixtureProject([".firebaserc": #"{"projects": {"default": "shop-prod"}}"#,
                                      "firebase.json": #"{"emulators": {"ui": {"enabled": true, "port": 4100}}}"#])
        let firebase = try row(project.services(), "firebase.cloud")
        #expect(urls(firebase) == ["https://console.firebase.google.com/project/shop-prod/overview", "http://127.0.0.1:4100"])
        #expect(firebase.links.map(\.title) == ["Open Firebase Console", "Open Firebase Emulator UI"])
        #expect(!firebase.isLocal)
    }

    @Test func convexOpensTheDeploymentItsURLNames() throws {
        let project = FixtureProject([".env.local": "VITE_CONVEX_URL=https://happy-otter-123.convex.cloud\n"])
        #expect(try row(project.services(), "convex.cloud").link.url.absoluteString
            == "https://dashboard.convex.dev/d/happy-otter-123")
        let local = FixtureProject([".env.local": "CONVEX_DEPLOYMENT=anonymous:shop\nVITE_CONVEX_URL=http://127.0.0.1:3210\n"])
        #expect(local.services().rows.isEmpty)
    }
}
