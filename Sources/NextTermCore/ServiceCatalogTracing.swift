import Foundation

// LLM tracing and evals, most used first. A tool a project points at its own server (a `*_HOST` or `*_URL` value)
// opens that server; else the vendor's cloud, where its SDK sends traces by default. A server value no link may use
// (another value in it, a user or password, plain `http` off this Mac) leaves no vendor page in its place.

extension ServiceCatalog {
    static let tracing: [ServiceEntry] = [langsmith, liteLLM, langfuse, mlflow, braintrust, opik, weave, arizePhoenix,
                                          helicone]

    // MARK: LangSmith, LiteLLM, Langfuse

    /// The SDK's API endpoint, read as the site a person opens: `eu.api.smith.langchain.com` is
    /// `eu.smith.langchain.com`; a self-hosted one is opened at its own origin.
    static let langsmithEndpoint = OriginRule(["LANGSMITH_ENDPOINT", "LANGCHAIN_ENDPOINT"], mapping: .langsmithSite)
    static let langsmithSignals: [Signal] = [
        .key("LANGSMITH_API_KEY"), .key("LANGCHAIN_API_KEY"), .key("LANGSMITH_TRACING"), .key("LANGCHAIN_TRACING_V2"),
        .origin("LANGSMITH_ENDPOINT", nil), .origin("LANGCHAIN_ENDPOINT", nil),
    ]
    /// A project's page needs ids only LangSmith's API gives, so the project's name goes in the tooltip.
    static let langsmithLinks: [LinkTemplate] = [
        LinkTemplate("projects", "Projects", .configured(langsmithEndpoint)),
        .web("projects", "Projects", "smith.langchain.com"),
    ]
    static let langsmithValues: [String: KeyRole] = [
        "LANGSMITH_ENDPOINT": .url, "LANGCHAIN_ENDPOINT": .url, "LANGSMITH_PROJECT": .name, "LANGCHAIN_PROJECT": .name,
    ]
    static let langsmith = ServiceEntry("langsmith", "LangSmith", kind: .tracing, rank: 1, place: .cloud,
                                        signals: langsmithSignals, values: langsmithValues, links: langsmithLinks,
                                        notes: [ServiceNote("Project", [.value("LANGSMITH_PROJECT"),
                                                                        .value("LANGCHAIN_PROJECT")])])

    /// The proxy's admin UI. Its package alone names no row: most installs use LiteLLM as a library.
    static let liteLLMImages = ["berriai/litellm", "berriai/litellm-database"]
    static let liteLLMServer = OriginRule(["LITELLM_PROXY_BASE_URL", "LITELLM_API_BASE"], localPort: 4000)
    static let liteLLMPort = LocalPort("localhost", liteLLMImages.map { (image: String) -> PortSource in
        .compose(image, target: 4000)
    } + [.start(["litellm"])], default: 4000)
    static let liteLLMSignals: [Signal] = liteLLMImages.map { (image: String) -> Signal in .image(image) } + [
        .key("LITELLM_MASTER_KEY"), .origin("LITELLM_PROXY_BASE_URL", nil), .origin("LITELLM_API_BASE", nil),
    ]
    static let liteLLMLinks: [LinkTemplate] = [
        LinkTemplate("ui", "Admin UI", .configured(liteLLMServer), path: [.text("/ui")]),
        LinkTemplate("ui", "Admin UI", .local(liteLLMPort), path: [.text("/ui")]),
    ]
    static let liteLLM = ServiceEntry("litellm", "LiteLLM", kind: .tracing, rank: 2, place: .local,
                                      signals: liteLLMSignals,
                                      values: ["LITELLM_PROXY_BASE_URL": .url, "LITELLM_API_BASE": .url],
                                      links: liteLLMLinks)

    /// Langfuse's web image, matched whole: its worker image beside it has no page.
    static let langfuseServer = OriginRule(["LANGFUSE_BASE_URL", "LANGFUSE_HOST"])
    static let langfuseCompose = LocalPort("localhost", [.compose("langfuse/langfuse", target: 3000)], default: nil)
    static let langfuseSignals: [Signal] = [
        .key("LANGFUSE_SECRET_KEY"), .key("LANGFUSE_PUBLIC_KEY"),
        .origin("LANGFUSE_BASE_URL", nil), .origin("LANGFUSE_HOST", nil), .image("langfuse/langfuse"),
        .dependency(.pypi, "langfuse"), .dependency(.npm, "langfuse"),
    ]
    static let langfuseLinks: [LinkTemplate] = [
        LinkTemplate("projects", "Projects", .configured(langfuseServer)),
        LinkTemplate("projects", "Projects", .local(langfuseCompose)),
        .web("projects", "Projects", "cloud.langfuse.com"),
    ]
    static let langfuse = ServiceEntry("langfuse", "Langfuse", kind: .tracing, rank: 3, place: .cloud,
                                       signals: langfuseSignals,
                                       values: ["LANGFUSE_BASE_URL": .url, "LANGFUSE_HOST": .url], links: langfuseLinks)
}

// MARK: - MLflow, Braintrust, Opik

extension ServiceCatalog {
    /// A tracking server opens at the experiment `MLFLOW_EXPERIMENT_ID` names, on Databricks under `/ml`. A tracking
    /// URI that names a store (`file:`, `sqlite:`) is no server: the row opens `mlflow ui` on this Mac.
    static let mlflowServer = OriginRule(["MLFLOW_TRACKING_URI"])
    static let databricksServer = OriginRule(["MLFLOW_TRACKING_URI"], hosts: [
        .domain("cloud.databricks.com"), .domain("azuredatabricks.net"), .domain("gcp.databricks.com"),
    ])
    static let mlflowExperiment: Piece = .fact([.value("MLFLOW_EXPERIMENT_ID")], .digits)
    static let mlflowUI = LocalPort("127.0.0.1", [.start(["mlflow ui", "mlflow server"])], default: 5000)
    static let mlflowSignals: [Signal] = [
        .origin("MLFLOW_TRACKING_URI", nil),
        .all([.dependency(.pypi, "mlflow"), .any([.file("mlruns/", .local), .file("mlflow.db", .local)])]),
        .start("mlflow ui"), .start("mlflow server"),
    ]
    static let mlflowLinks: [LinkTemplate] = [
        LinkTemplate("experiment", "Experiment", .configured(databricksServer),
                     path: [.text("/ml/experiments/"), mlflowExperiment], about: "experiment"),
        LinkTemplate("experiment", "Experiment", .configured(mlflowServer), path: [.text("/")],
                     fragment: [.text("/experiments/"), mlflowExperiment], about: "experiment"),
        LinkTemplate("experiments", "Experiments", .configured(mlflowServer)),
        LinkTemplate("experiments", "Experiments", .local(mlflowUI)),
    ]
    static let mlflow = ServiceEntry("mlflow", "MLflow", kind: .tracing, rank: 4, place: .local, signals: mlflowSignals,
                                     values: ["MLFLOW_TRACKING_URI": .url, "MLFLOW_EXPERIMENT_ID": .id],
                                     links: mlflowLinks)

    /// The project's logs, as Braintrust's SDK builds the address, on its own app or the one a value names.
    static let braintrustApp = OriginRule(["BRAINTRUST_APP_PUBLIC_URL", "BRAINTRUST_APP_URL"])
    static let braintrustLogs: [Piece] = [
        .text("/app/"), .fact([.value("BRAINTRUST_ORG_NAME")], .name),
        .text("/p/"), .fact([.value("BRAINTRUST_DEFAULT_PROJECT")], .name), .text("/logs"),
    ]
    static let braintrustSignals: [Signal] = [
        .key("BRAINTRUST_API_KEY"), .dependency(.pypi, "braintrust"), .dependency(.npm, "braintrust"),
        .origin("BRAINTRUST_APP_PUBLIC_URL", nil), .origin("BRAINTRUST_APP_URL", nil),
    ]
    static let braintrustLinks: [LinkTemplate] = [
        LinkTemplate("logs", "Logs", .configured(braintrustApp), path: braintrustLogs),
        LinkTemplate("logs", "Logs", .web("www.braintrust.dev"), path: braintrustLogs),
        LinkTemplate("app", "Dashboard", .configured(braintrustApp), path: [.text("/app")]),
        .web("app", "Dashboard", "www.braintrust.dev", "/app"),
    ]
    static let braintrustValues: [String: KeyRole] = [
        "BRAINTRUST_ORG_NAME": .name, "BRAINTRUST_DEFAULT_PROJECT": .name,
        "BRAINTRUST_APP_PUBLIC_URL": .url, "BRAINTRUST_APP_URL": .url,
    ]
    static let braintrust = ServiceEntry("braintrust", "Braintrust", kind: .tracing, rank: 5, place: .cloud,
                                         signals: braintrustSignals, values: braintrustValues, links: braintrustLinks)

    /// The workspace's projects. Comet's own host serves Opik under `/opik/`; a server of its own, at its root.
    static let opikServer = OriginRule(["OPIK_URL_OVERRIDE"])
    static let opikOnComet = OriginRule(["OPIK_URL_OVERRIDE"], hosts: [.domain("comet.com")])
    static let opikWorkspace: Piece = .fact([.value("OPIK_WORKSPACE")], .name)
    static let opikLinks: [LinkTemplate] = [
        LinkTemplate("projects", "Projects", .configured(opikOnComet),
                     path: [.text("/opik/"), opikWorkspace, .text("/projects")], about: "workspace"),
        LinkTemplate("projects", "Projects", .configured(opikServer),
                     path: [.text("/"), opikWorkspace, .text("/projects")], about: "workspace"),
        LinkTemplate("home", "Projects", .configured(opikOnComet), path: [.text("/opik/")]),
        LinkTemplate("home", "Projects", .configured(opikServer)),
        LinkTemplate("projects", "Projects", .web("www.comet.com"),
                     path: [.text("/opik/"), opikWorkspace, .text("/projects")], about: "workspace"),
        .web("home", "Projects", "www.comet.com", "/opik/"),
    ]
    static let opikSignals: [Signal] = [
        .key("OPIK_API_KEY"), .dependency(.pypi, "opik"), .origin("OPIK_URL_OVERRIDE", nil),
    ]
    static let opik = ServiceEntry("opik", "Opik", kind: .tracing, rank: 6, place: .cloud, signals: opikSignals,
                                   values: ["OPIK_URL_OVERRIDE": .url, "OPIK_WORKSPACE": .name], links: opikLinks)
}

// MARK: - W&B Weave, Arize Phoenix, Helicone

extension ServiceCatalog {
    /// `{app}/{entity}/{project}/weave`, where the app is `WANDB_APP_URL`, else `WANDB_BASE_URL`'s API host as its
    /// app (as wandb maps it), else wandb.ai.
    static let wandbAppURL = OriginRule(["WANDB_APP_URL"])
    static let wandbBaseURL = OriginRule(["WANDB_BASE_URL"], mapping: .wandbApp)
    static let weavePath: [Piece] = [
        .text("/"), .fact([.value("WANDB_ENTITY")], .name), .text("/"), .fact([.value("WANDB_PROJECT")], .name),
        .text("/weave"),
    ]
    static let weaveLinks: [LinkTemplate] = [
        LinkTemplate("weave", "Weave", .configured(wandbAppURL), path: weavePath),
        LinkTemplate("weave", "Weave", .configured(wandbBaseURL), path: weavePath),
        LinkTemplate("weave", "Weave", .web("wandb.ai"), path: weavePath),
        LinkTemplate("home", "Home", .configured(wandbAppURL), badge: "Weave"),
        LinkTemplate("home", "Home", .configured(wandbBaseURL), badge: "Weave"),
        .web("home", "Home", "wandb.ai", "/home", badge: "Weave"),
    ]
    static let weaveSignals: [Signal] = [
        .key("WANDB_API_KEY"), .dependency(.pypi, "weave"), .dependency(.pypi, "wandb"),
        .origin("WANDB_APP_URL", nil), .origin("WANDB_BASE_URL", nil),
    ]
    static let weaveValues: [String: KeyRole] = [
        "WANDB_ENTITY": .name, "WANDB_PROJECT": .name, "WANDB_APP_URL": .url, "WANDB_BASE_URL": .url,
    ]
    static let weave = ServiceEntry("wandb-weave", "W&B Weave", kind: .tracing, rank: 7, place: .cloud,
                                    signals: weaveSignals, values: weaveValues, links: weaveLinks)

    /// The client's base URL, then the collector's; Phoenix on this Mac answers on 6006. `PHOENIX_HOST` is where a
    /// server listens, not where a client sends, so it is never a link's host. Phoenix Cloud's space is in the
    /// endpoint's path, which is never kept, so its link is the cloud's own home.
    static let phoenixKeys = ["PHOENIX_ENDPOINT", "PHOENIX_COLLECTOR_ENDPOINT"]
    static let phoenixCloud = OriginRule(phoenixKeys, hosts: [.domain("phoenix.arize.com")])
    static let phoenixServer = OriginRule(phoenixKeys, localPort: 6006)
    static let phoenixPort = LocalPort("localhost", [.compose("arizephoenix/phoenix", target: 6006),
                                                     .env("PHOENIX_PORT"), .start(["phoenix serve"])], default: 6006)
    static let phoenixSignals: [Signal] = [
        .origin("PHOENIX_ENDPOINT", nil), .origin("PHOENIX_COLLECTOR_ENDPOINT", nil), .image("arizephoenix/phoenix"),
        .file(".env.phoenix", .local), .dependency(.pypi, "arize-phoenix"), .dependency(.pypi, "arize-phoenix-otel"),
    ]
    static let phoenixLinks: [LinkTemplate] = [
        LinkTemplate("projects", "Projects", .configured(phoenixCloud)),
        LinkTemplate("projects", "Projects", .configured(phoenixServer), path: [.text("/projects")]),
        LinkTemplate("projects", "Projects", .local(phoenixPort), path: [.text("/projects")]),
    ]
    static let arizePhoenix = ServiceEntry("arize-phoenix", "Arize Phoenix", kind: .tracing, rank: 8, place: .local,
                                           signals: phoenixSignals,
                                           values: ["PHOENIX_ENDPOINT": .url, "PHOENIX_COLLECTOR_ENDPOINT": .url,
                                                    "PHOENIX_PORT": .port],
                                           links: phoenixLinks)

    /// A base URL on Helicone's gateway names it; its EU hosts open the EU app.
    static let heliconeLinks: [LinkTemplate] = [
        .web("requests-eu", "Requests", "eu.helicone.ai", "/requests",
             when: .host(.around(prefix: "eu.", suffix: ".helicone.ai"))),
        .web("requests", "Requests", "us.helicone.ai", "/requests"),
    ]
    static let helicone = ServiceEntry("helicone", "Helicone", kind: .tracing, rank: 9, place: .cloud,
                                       signals: [.key("HELICONE_API_KEY"), .host(.domain("helicone.ai"))],
                                       links: heliconeLinks)
}
