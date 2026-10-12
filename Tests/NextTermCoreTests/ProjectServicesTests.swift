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
