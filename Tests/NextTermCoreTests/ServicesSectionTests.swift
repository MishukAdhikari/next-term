import Foundation
import Testing
@testable import NextTermCore

/// What the sidebar's Services section says beyond each row's own text: the group's tooltip, the file Reveal Source
/// File selects, and what VoiceOver reads for a row. Every project, key and value here is made up.
@Suite struct ServicesSectionTests {
    /// A Python RAG project on this Mac: OpenAI, Qdrant in Compose, LangSmith tracing and FastAPI.
    static func ragProject() -> FixtureProject {
        FixtureProject([
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
    }

    func row(_ scan: ServiceScan, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> ServiceRow {
        try #require(scan.rows.first { (row: ServiceRow) -> Bool in row.name == name }, "\(scan.rows.map(\.id))",
                     sourceLocation: sourceLocation)
    }

    @Test func theGroupsTooltipListsTheKindsFoundInTheirOrder() {
        let scan = Self.ragProject().services()
        #expect(scan.kinds == [.aiModel, .vectorStore, .tracing, .localServer])
        let lines = scan.tooltip.components(separatedBy: "\n")
        #expect(lines == [
            "Services this project’s files name, found offline: AI models, vector stores, tracing and evals, local servers.",
            "Secret keys (API keys, tokens, passwords) are read by name only. A badge opens its page in your browser.",
        ])
    }

    /// The scan reads the values of address, port, name and id keys (LANGSMITH_PROJECT gives "Project: support-bot"),
    /// so the group's tooltip promises name-only reading for secrets alone.
    @Test func theGroupsTooltipPromisesNameOnlyForSecretsAlone() throws {
        let scan = Self.ragProject().services()
        #expect(try row(scan, "LangSmith").notes == ["Project: support-bot"], "a value the scan reads")
        #expect(!scan.tooltip.contains("Keys are read by name only"))
        #expect(scan.tooltip.contains("Secret keys (API keys, tokens, passwords) are read by name only."))
    }

    @Test func aKindIsListedOnceHoweverManyRowsItHas() {
        let project = FixtureProject([".env": "OPENAI_API_KEY=NOT-A-KEY\nANTHROPIC_API_KEY=NOT-A-KEY\n"])
        let scan = project.services()
        #expect(scan.rows.count == 2)
        #expect(scan.kinds == [.aiModel])
        #expect(scan.tooltip.hasPrefix("Services this project’s files name, found offline: AI models.\n"))
    }

    @Test func everyKindHasAPluralForTheTooltip() {
        let plurals = ServiceKind.allCases.map(\.plural)
        #expect(plurals == ["AI models", "vector stores", "tracing and evals", "agents", "local servers", "backends",
                            "hosting"])
    }

    @Test func revealSelectsTheFileTheDetailNames() throws {
        let scan = Self.ragProject().services()
        let qdrant = try row(scan, "Qdrant")
        #expect(qdrant.sourceFile == "compose.yaml", "the file that gave the port")
        #expect(qdrant.detail == "vector store · compose.yaml")
        let fastAPI = try row(scan, "FastAPI")
        #expect(fastAPI.sourceFile == "pyproject.toml", "a default port: the file that named the framework")
        #expect(fastAPI.detail == "local server · pyproject.toml")
        for row in scan.rows {
            let file = try #require(row.sourceFile, "\(row.id)")
            #expect(row.detail == row.kind.title + " · " + file)
            #expect(!file.hasPrefix("/") && !file.contains(".."), "\(file) stays in the project")
        }
    }

    /// No file named the row (none listed, or a blank name): the detail is the kind alone, and the menu leaves Reveal
    /// Source File out, as it reads `sourceFile`.
    @Test func aRowNoFileNamedHasNothingToReveal() throws {
        let url = try #require(URL(string: "https://platform.openai.com"))
        let link = ServiceLink(id: "openai.cloud.platform", badge: "Platform", title: "Open OpenAI Platform",
                               tooltip: "Open OpenAI Platform", url: url)
        func openAI(_ sources: [ServiceSource]) -> ServiceRow {
            ServiceRow(id: "openai.cloud", entryID: "openai", name: "OpenAI", kind: .aiModel, place: .cloud,
                       sources: sources, notes: [], links: [link], isLocal: false)
        }
        for row in [openAI([]), openAI([ServiceSource(file: "", names: ["OPENAI_API_KEY"])])] {
            #expect(row.sourceFile == nil, "\(row.sources)")
            #expect(row.detail == "AI model")
        }
        #expect(openAI([ServiceSource(file: ".env", names: ["OPENAI_API_KEY"])]).sourceFile == ".env")
    }

    @Test func voiceOverReadsTheNameTheKindAndWhetherItIsOnThisMac() throws {
        let scan = Self.ragProject().services()
        #expect(try row(scan, "Qdrant").accessibilityLabel == "Qdrant, vector store, on this Mac")
        #expect(try row(scan, "FastAPI").accessibilityLabel == "FastAPI, local server, on this Mac")
        #expect(try row(scan, "OpenAI").accessibilityLabel == "OpenAI, AI model")
        #expect(try row(scan, "LangSmith").accessibilityLabel == "LangSmith, tracing")
    }

    @Test func noMadeUpSecretInTheSectionsText() {
        let scan = Self.ragProject().services()
        var text = [scan.tooltip]
        for row in scan.rows { text += [row.accessibilityLabel, row.sourceFile ?? ""] }
        let all = text.joined(separator: "\n")
        for secret in ["NOT-A-", "sk-test", "lsv2"] {
            #expect(!all.contains(secret), "\(secret) in \(all)")
        }
        expectNoSecret(scan)
    }

    @Test func anEmptyScanHasNoKinds() {
        #expect(ServiceScan().kinds.isEmpty)
    }

    @Test func aRowHasOneBadgeOpeningItsMainPage() throws {
        let scan = Self.ragProject().services()
        let qdrant = try row(scan, "Qdrant")
        #expect(qdrant.badges.map(\.word) == [":6334"])
        #expect(qdrant.badges.first?.link?.url.absoluteString == "http://localhost:6334/dashboard")
        for row in scan.rows {
            #expect(row.badges == [ServiceBadge(word: row.link.badge, link: row.link)], "\(row.id)")
        }
    }

    @Test func aServiceWithTwoPagesStillShowsOneBadgeAndItsMenuHasBoth() throws {
        let project = FixtureProject([".env": """
        UPSTASH_REDIS_REST_URL=https://wise-cat-12345.upstash.io
        UPSTASH_VECTOR_REST_URL=https://shop-vectors-12345-us1-vector.upstash.io
        """])
        let upstash = try row(project.services(), "Upstash")
        #expect(upstash.links.count == 2)
        #expect(upstash.badges.count == 1)
        #expect(upstash.badges.first?.link == upstash.links.first)
    }
}
