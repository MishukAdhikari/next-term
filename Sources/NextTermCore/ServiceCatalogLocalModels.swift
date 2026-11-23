import Foundation

// Model servers on this Mac (plan 044, item 2): Ollama, LM Studio and vLLM, for a project whose files name one. Each is
// an AI model row on this Mac whose badge opens the server's own model list (Ollama's `/api/tags`, the OpenAI-style
// `/v1/models` of the others), and whose menu starts it, pulls a model the files name, or copies its base URL. A
// base-URL key on Ollama's port is Ollama's, not OpenAI's: the OpenAI row already steps aside for a base URL on
// another host (`routes`).

/// How a model server's row starts it, pulls a model and gives its base URL. Data, as the catalog's entries are.
public struct RuntimeSpec: Sendable, Hashable {
    /// Typed and run in a new tab in the project's folder: `ollama serve`.
    public let start: String?
    /// Typed, not run, before a model's name: `ollama pull`.
    public let pull: String?
    /// The keys whose values name the models to pull: `OLLAMA_MODEL`, `OLLAMA_EMBED_MODEL`.
    public let modelKeys: KeyPattern?
    /// After the server's origin in the base URL its clients take: `/v1` for an OpenAI-compatible one.
    public let basePath: String
    /// The tool offered when the project needs it and no copy is found.
    public let tool: ProjectTool?

    public init(start: String?, pull: String? = nil, modelKeys: KeyPattern? = nil, basePath: String = "",
                tool: ProjectTool?) {
        self.start = start
        self.pull = pull
        self.modelKeys = modelKeys
        self.basePath = basePath
        self.tool = tool
    }
}

/// What a model server's row does beyond opening its page, as its menu offers it.
public struct LocalRuntime: Sendable, Equatable {
    /// "ollama serve", typed and run in a new tab.
    public let start: String?
    /// "ollama pull": typed with a space after it when no model is named, for the user to finish.
    public let pull: String?
    /// The models the project's files name, in the order found, each a name a pull may take: `llama3.2`, `qwen3:8b`.
    public let models: [String]
    /// What Copy Base URL copies: `http://localhost:11434`, `http://localhost:1234/v1`.
    public let baseURL: String
    public let tool: ProjectTool?

    public init(start: String?, pull: String?, models: [String], baseURL: String, tool: ProjectTool?) {
        self.start = start
        self.pull = pull
        self.models = models
        self.baseURL = baseURL
        self.tool = tool
    }

    /// `ollama pull llama3.2`, typed for the user's Return.
    public func pullCommand(_ model: String) -> String? {
        guard let pull, Self.isModelName(model) else { return nil }
        return pull + " " + model
    }

    /// A model's name as Ollama's library writes it, with a tag or not: letters, digits, `.`, `_` and `-`, then
    /// `:tag`. Nothing a shell reads as more than a word.
    public static func isModelName(_ name: String) -> Bool {
        name.wholeMatch(of: modelName) != nil
    }

    private static let modelName = #/[A-Za-z0-9][A-Za-z0-9._-]{0,79}(:[A-Za-z0-9][A-Za-z0-9._-]{0,59})?/#
}

extension ServiceCatalog {
    static let localModels: [ServiceEntry] = [ollama, lmStudio, vllm]

    /// Keys read by the shape of their name: any base URL (for the port it points at), and Ollama's model keys.
    public static let valuePatterns: [KeyPattern] = [baseURLKeys, ollamaModelKeys]
    static let baseURLKeys = KeyPattern(suffix: "_BASE_URL", role: .url)
    static let ollamaModelKeys = KeyPattern(prefix: "OLLAMA_", suffix: "MODEL", role: .name)

    // MARK: Ollama

    static let ollamaPort = 11434
    static let ollamaHost = OriginRule(["OLLAMA_HOST", "OLLAMA_BASE_URL"], mapping: .bindAddress, localPort: ollamaPort)
    static let ollamaSignals: [Signal] = [
        .origin("OLLAMA_HOST", nil), .origin("OLLAMA_BASE_URL", nil),
        .dependency(.pypi, "ollama"), .dependency(.pypi, "langchain-ollama"), .dependency(.pypi, "llama-index-llms-ollama"),
        .dependency(.npm, "ollama"), .dependency(.npm, "ollama-ai-provider"), .dependency(.cargo, "ollama-rs"),
        .image("ollama/ollama"), .start("ollama serve"), .loopbackPort("_BASE_URL", ollamaPort),
    ]
    static let ollamaLocal = LocalPort("localhost", [.compose("ollama/ollama", target: ollamaPort)], default: ollamaPort)
    static let ollamaLinks: [LinkTemplate] = [
        LinkTemplate("models", "Models", .configured(ollamaHost), path: [.text("/api/tags")]),
        LinkTemplate("models", "Models", .local(ollamaLocal), path: [.text("/api/tags")]),
    ]
    static let ollama = ServiceEntry("ollama", "Ollama", kind: .aiModel, rank: 17, place: .local, signals: ollamaSignals,
                                     values: ["OLLAMA_HOST": .url, "OLLAMA_BASE_URL": .url], links: ollamaLinks,
                                     runtime: RuntimeSpec(start: "ollama serve", pull: "ollama pull",
                                                          modelKeys: ollamaModelKeys, tool: .ollama))

    // MARK: LM Studio, vLLM

    static let lmStudioPort = 1234
    static let lmStudioSignals: [Signal] = [
        .start("lms server start"), .loopbackPort("_BASE_URL", lmStudioPort),
        .dependency(.npm, "@lmstudio/sdk"), .dependency(.pypi, "lmstudio"),
    ]
    static let lmStudioLocal = LocalPort("localhost", [.start(["lms server start"])], default: lmStudioPort)
    static let lmStudio = ServiceEntry("lm-studio", "LM Studio", kind: .aiModel, rank: 18, place: .local,
                                       signals: lmStudioSignals,
                                       links: [LinkTemplate("models", "Models", .local(lmStudioLocal), path: [.text("/v1/models")])],
                                       runtime: RuntimeSpec(start: "lms server start", basePath: "/v1", tool: .lmStudio))

    /// Started by the project's own script, which names the model: no Start Server of its own, and nothing to offer.
    static let vllmLocal = LocalPort("localhost", [.start(["vllm serve"])], default: 8000)
    static let vllm = ServiceEntry("vllm", "vLLM", kind: .aiModel, rank: 19, place: .local, signals: [.start("vllm serve")],
                                   links: [LinkTemplate("models", "Models", .local(vllmLocal), path: [.text("/v1/models")])],
                                   runtime: RuntimeSpec(start: nil, basePath: "/v1", tool: nil))
}
