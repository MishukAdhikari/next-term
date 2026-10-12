import Foundation

// Agent frameworks and workflow engines, most used first. A framework with a dev server opens its studio on the port
// the files give, else its documented one; a hosted platform opens the project its config names, else its dashboard.
// An SDK that says nothing of where its server runs (Temporal's) names no row.

extension ServiceCatalog {
    static let agents: [ServiceEntry] = [langGraph, temporal, googleADK, inngest, mastra, triggerDev, crewAI, n8n,
                                         langflow]

    // MARK: LangGraph, Temporal, Google ADK

    /// `langgraph dev` serves on 127.0.0.1:2024 and is opened in LangGraph Studio, a hosted page on LangSmith's site
    /// (the one a script's `--studio-url` or the project's LangSmith endpoint names) that reaches back to it. When
    /// that site is written in a form no link may use, the row opens the server's own API docs instead.
    static let langGraphServer = LocalPort("127.0.0.1", [.start(["langgraph dev"])], default: 2024)
    static let langGraphSignals: [Signal] = [
        .file("langgraph.json", .local), .start("langgraph dev"),
        .dependency(.pypi, "langgraph-cli"), .dependency(.npm, "@langchain/langgraph-cli"),
    ]
    static let langGraphLinks: [LinkTemplate] = [
        LinkTemplate("studio", "Studio", .studio(langGraphServer, langsmithEndpoint)),
        LinkTemplate("docs", "API Docs", .local(langGraphServer), path: [.text("/docs")]),
        LinkTemplate("docs", "API Docs", .local(langGraphServer), path: [.text("/docs")], extra: true),
    ]
    static let langGraph = ServiceEntry("langgraph", "LangGraph", kind: .agent, rank: 1, place: .local,
                                        signals: langGraphSignals,
                                        values: ["LANGSMITH_ENDPOINT": .url, "LANGCHAIN_ENDPOINT": .url],
                                        links: langGraphLinks)

    /// The dev server's UI is its port plus 1000 (8233 by default), or what Compose publishes for `temporalio/ui`.
    /// Temporal Cloud's address is `<namespace>.<account>.tmprl.cloud:7233`.
    static let temporalUI = LocalPort("localhost", [
        .compose("temporalio/ui", target: 8080), .startUI(["temporal server start-dev"]),
        .startPlus(["temporal server start-dev"], 1000), .valuePlus("TEMPORAL_ADDRESS", 1000),
    ], default: 8233)
    static let temporalNamespace: [Piece] = [
        .text("/namespaces/"), .fact([.hostLabel(["TEMPORAL_ADDRESS"], domain: "tmprl.cloud", index: 0, count: 2)], .slug),
        .text("."), .fact([.hostLabel(["TEMPORAL_ADDRESS"], domain: "tmprl.cloud", index: 1, count: 2)], .slug),
    ]
    static let temporalSignals: [Signal] = [
        .origin("TEMPORAL_ADDRESS", nil), .image("temporalio/ui"), .start("temporal server start-dev"),
    ]
    static let temporalLinks: [LinkTemplate] = [
        LinkTemplate("ui", "UI", .local(temporalUI)),
        LinkTemplate("namespace", "Namespace", .web("cloud.temporal.io"), path: temporalNamespace, badge: "Cloud",
                     about: "namespace"),
        .web("cloud", "Cloud", "cloud.temporal.io"),
    ]
    static let temporal = ServiceEntry("temporal", "Temporal", cloudName: "Temporal Cloud", kind: .agent, rank: 2,
                                       place: nil, signals: temporalSignals, values: ["TEMPORAL_ADDRESS": .host],
                                       links: temporalLinks)

    static let googleADK = ServiceEntry("google-adk", "Google ADK", kind: .agent, rank: 3, place: .local,
                                        signals: [.dependency(.pypi, "google-adk"), .start("adk web")],
                                        links: [LinkTemplate("web", "Dev UI", .local(LocalPort("localhost",
                                            [.start(["adk web"])], default: 8000)))])
}

// MARK: - Inngest, Mastra, Trigger.dev

extension ServiceCatalog {
    /// The dev server on 8288, or the one `INNGEST_BASE_URL` names; Inngest Cloud beside it.
    static let inngestServer = OriginRule(["INNGEST_BASE_URL"], localPort: 8288)
    static let inngestPort = LocalPort("localhost", [.named(.inngestPort), .start(["inngest-cli dev", "inngest dev"])],
                                       default: 8288)
    static let inngestSignals: [Signal] = [
        .dependency(.npm, "inngest"), .dependency(.pypi, "inngest"), .origin("INNGEST_BASE_URL", nil),
        .start("inngest-cli dev"),
    ]
    static let inngestLinks: [LinkTemplate] = [
        LinkTemplate("dev", "Dev Server", .configured(inngestServer)),
        LinkTemplate("dev", "Dev Server", .local(inngestPort)),
        LinkTemplate("cloud", "Cloud", .web("app.inngest.com"), extra: true, place: .local),
    ]
    static let inngest = ServiceEntry("inngest", "Inngest", kind: .agent, rank: 4, place: .local, signals: inngestSignals,
                                      values: ["INNGEST_BASE_URL": .url], links: inngestLinks)

    /// Mastra Studio on 4111, or the literal port `src/mastra/index.ts` gives its server; its API docs beside it.
    static let mastraPort = LocalPort("localhost", [.named(.mastraPort), .start(["mastra dev"])], default: 4111)
    static let mastraLinks: [LinkTemplate] = [
        LinkTemplate("studio", "Studio", .local(mastraPort)),
        LinkTemplate("swagger", "API Docs", .local(mastraPort), path: [.text("/swagger-ui")], extra: true),
    ]
    static let mastra = ServiceEntry("mastra", "Mastra", kind: .agent, rank: 5, place: .local,
                                     signals: [.dependency(.npm, "@mastra/core"), .start("mastra dev")],
                                     links: mastraLinks)

    /// The project `trigger.config.ts` names, as Trigger.dev's own app routes it. It has no local UI.
    static let triggerProject: [Piece] = [.text("/projects/v3/"), .fact([.named(.triggerProjectRef)], .triggerRef)]
    static let triggerLinks: [LinkTemplate] = [
        LinkTemplate("project", "Project", .web("cloud.trigger.dev"), path: triggerProject, about: "project"),
        .web("dashboard", "Dashboard", "cloud.trigger.dev"),
    ]
    static let triggerDev = ServiceEntry("trigger-dev", "Trigger.dev", kind: .agent, rank: 6, place: .cloud,
                                         signals: [.named(.triggerProjectRef, .cloud),
                                                   .dependency(.npm, "@trigger.dev/sdk")],
                                         links: triggerLinks)
}

// MARK: - CrewAI, n8n, Langflow

extension ServiceCatalog {
    /// CrewAI's hosted platform; a crew has no local server.
    static let crewAI = ServiceEntry("crewai", "CrewAI", kind: .agent, rank: 7, place: .cloud,
                                     signals: [.pyprojectTool("crewai"), .dependency(.pypi, "crewai")],
                                     links: [.web("amp", "AMP", "app.crewai.com")])

    /// The editor, at the origin `N8N_EDITOR_BASE_URL` gives (its path is never kept: webhook paths act as secrets),
    /// else the port Compose publishes, else 5678.
    static let n8nServer = OriginRule(["N8N_EDITOR_BASE_URL"], localPort: 5678)
    static let n8nPort = LocalPort("localhost", [.compose("n8nio/n8n", target: 5678), .env("N8N_PORT")], default: 5678)
    static let n8nLinks: [LinkTemplate] = [
        LinkTemplate("editor", "Editor", .configured(n8nServer)),
        LinkTemplate("editor", "Editor", .local(n8nPort)),
    ]
    static let n8n = ServiceEntry("n8n", "n8n", kind: .agent, rank: 8, place: .local,
                                  signals: [.image("n8nio/n8n"), .origin("N8N_EDITOR_BASE_URL", nil)],
                                  values: ["N8N_EDITOR_BASE_URL": .url, "N8N_PORT": .port], links: n8nLinks)

    static let langflowPort = LocalPort("localhost", [.compose("langflowai/langflow", target: 7860),
                                                      .start(["langflow run"]), .env("LANGFLOW_PORT")], default: 7860)
    static let langflow = ServiceEntry("langflow", "Langflow", kind: .agent, rank: 9, place: .local,
                                       signals: [.image("langflowai/langflow"), .dependency(.pypi, "langflow"),
                                                 .start("langflow run")],
                                       values: ["LANGFLOW_PORT": .port],
                                       links: [LinkTemplate("app", nil, .local(langflowPort))])
}
