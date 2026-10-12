import Foundation

// AI model providers, most used first (last month's downloads of each one's own SDK). Each is named by its API key's
// name, its SDK, or its API host in a base-URL value, and opens its console, where the keys and the usage are. A key's
// name says which provider; its value is never read. A gateway that logs a request and sends it on to the provider,
// with the provider's own key (Helicone's `oai.` and `anthropic.` hosts), counts as the provider's host.

extension ServiceCatalog {
    static let aiModels: [ServiceEntry] = [openAI, anthropic, googleAIStudio, huggingFace, mistral, groq, openRouter,
                                           cohere, bedrock, vertexAI, azureOpenAI, replicate, together, deepSeek, xAI,
                                           fireworks]

    // MARK: OpenAI, Anthropic, Google AI Studio

    static let openAIAgents: Signal = .any([.dependency(.pypi, "openai-agents"), .dependency(.npm, "@openai/agents")])
    static let openAISignals: [Signal] = [
        .key("OPENAI_API_KEY"),
        .dependency(.pypi, "openai"), .dependency(.pypi, "langchain-openai"),
        .dependency(.npm, "openai"), .dependency(.npm, "@ai-sdk/openai"), openAIAgents,
        .host(.domain("api.openai.com")), .host(.domain("oai.helicone.ai")),
    ]
    static let openAILinks: [LinkTemplate] = [
        .web("platform", "Platform", "platform.openai.com", "/"),
        .web("api-keys", "API Keys", "platform.openai.com", "/settings/organization/api-keys", extra: true),
        .web("usage", "Usage", "platform.openai.com", "/usage", extra: true),
        .web("traces", "Traces", "platform.openai.com", "/traces", extra: true, when: openAIAgents),
    ]
    static let openAI = ServiceEntry("openai", "OpenAI", kind: .aiModel, rank: 1, place: .cloud, signals: openAISignals,
                                     routes: ["OPENAI_BASE_URL", "OPENAI_API_BASE"],
                                     values: ["OPENAI_BASE_URL": .url, "OPENAI_API_BASE": .url], links: openAILinks)

    static let anthropicSignals: [Signal] = [
        .key("ANTHROPIC_API_KEY"), .key("ANTHROPIC_AUTH_TOKEN"),
        .dependency(.pypi, "anthropic"), .dependency(.npm, "@anthropic-ai/sdk"), .dependency(.npm, "@ai-sdk/anthropic"),
        .host(.domain("api.anthropic.com")), .host(.domain("anthropic.helicone.ai")),
    ]
    static let anthropicLinks: [LinkTemplate] = [
        .web("console", "Console", "platform.claude.com", "/"),
        .web("keys", "Keys", "platform.claude.com", "/settings/keys", extra: true),
        .web("usage", "Usage", "platform.claude.com", "/usage", extra: true),
    ]
    static let anthropic = ServiceEntry("anthropic", "Anthropic", kind: .aiModel, rank: 2, place: .cloud,
                                        signals: anthropicSignals, routes: ["ANTHROPIC_BASE_URL"],
                                        values: ["ANTHROPIC_BASE_URL": .url], links: anthropicLinks)

    static let geminiPackages: [Signal] = [
        .dependency(.pypi, "google-genai"), .dependency(.npm, "@google/genai"), .dependency(.npm, "@ai-sdk/google"),
    ]
    /// `GOOGLE_API_KEY` serves many Google APIs, so it names Gemini only beside Gemini's SDK.
    static let googleAIStudioSignals: [Signal] = [
        .key("GEMINI_API_KEY"), .key("GOOGLE_GENERATIVE_AI_API_KEY"),
        .all([.key("GOOGLE_API_KEY"), .any(geminiPackages)]),
    ] + geminiPackages
    static let googleAIStudioLinks: [LinkTemplate] = [
        .web("api-keys", "API Keys", "aistudio.google.com", "/apikey", badge: "AI Studio"),
        .web("usage", "Usage", "aistudio.google.com", "/usage", extra: true),
    ]
    static let googleAIStudio = ServiceEntry("google-ai-studio", "Google AI Studio", kind: .aiModel, rank: 3,
                                             place: .cloud, signals: googleAIStudioSignals, links: googleAIStudioLinks)

    // MARK: Hugging Face, Mistral, Groq, OpenRouter, Cohere

    /// Its packages alone name no row: most installs come with another library.
    static let huggingFaceSignals: [Signal] = [
        .key("HF_TOKEN"), .key("HUGGING_FACE_HUB_TOKEN"), .key("HUGGINGFACE_API_KEY"),
        .host(.domain("router.huggingface.co")),
    ]
    static let huggingFace = ServiceEntry("huggingface", "Hugging Face", kind: .aiModel, rank: 4, place: .cloud,
                                          signals: huggingFaceSignals,
                                          links: [.web("tokens", "Tokens", "huggingface.co", "/settings/tokens", badge: "Hub")])

    static let mistralSignals: [Signal] = [
        .key("MISTRAL_API_KEY"), .dependency(.pypi, "mistralai"), .dependency(.npm, "@mistralai/mistralai"),
    ]
    static let mistral = ServiceEntry("mistral", "Mistral", kind: .aiModel, rank: 5, place: .cloud,
                                      signals: mistralSignals,
                                      links: [.web("api-keys", "Console", "console.mistral.ai", "/api-keys")])

    static let groqSignals: [Signal] = [
        .key("GROQ_API_KEY"), .dependency(.pypi, "groq"), .dependency(.npm, "groq-sdk"), .host(.domain("api.groq.com")),
    ]
    static let groqLinks: [LinkTemplate] = [
        .web("dashboard", "Console", "console.groq.com", "/dashboard"),
        .web("keys", "Keys", "console.groq.com", "/keys", extra: true),
    ]
    static let groq = ServiceEntry("groq", "Groq", kind: .aiModel, rank: 6, place: .cloud, signals: groqSignals,
                                   links: groqLinks)

    static let openRouterLinks: [LinkTemplate] = [
        .web("activity", "Activity", "openrouter.ai", "/activity"),
        .web("credits", "Credits", "openrouter.ai", "/settings/credits", extra: true),
    ]
    static let openRouter = ServiceEntry("openrouter", "OpenRouter", kind: .aiModel, rank: 7, place: .cloud,
                                         signals: [.key("OPENROUTER_API_KEY"), .host(.domain("openrouter.ai"))],
                                         links: openRouterLinks)

    static let cohereSignals: [Signal] = [
        .key("CO_API_KEY"), .key("COHERE_API_KEY"), .dependency(.pypi, "cohere"), .dependency(.npm, "cohere-ai"),
    ]
    static let cohere = ServiceEntry("cohere", "Cohere", kind: .aiModel, rank: 8, place: .cloud, signals: cohereSignals,
                                     links: [.web("api-keys", "Dashboard", "dashboard.cohere.com", "/api-keys")])
}

// MARK: - Cloud platforms' model services

extension ServiceCatalog {
    static let bedrockSignals: [Signal] = [
        .key("AWS_BEARER_TOKEN_BEDROCK"), .key("CLAUDE_CODE_USE_BEDROCK"),
        .dependency(.npm, "@ai-sdk/amazon-bedrock"), .dependency(.pypi, "langchain-aws"),
        .host(.around(prefix: "bedrock-runtime.", suffix: ".amazonaws.com")),
    ]
    static let awsRegion: [FactRef] = [.value("AWS_REGION")]
    static let bedrockLinks: [LinkTemplate] = [
        LinkTemplate("console", "Console", .awsConsole(awsRegion), path: [.text("/bedrock/home")],
                     query: [QueryPiece("region", [.fact(awsRegion, .awsRegion)])]),
        .web("home", "Console", "console.aws.amazon.com", "/bedrock/"),
    ]
    static let bedrock = ServiceEntry("aws-bedrock", "AWS Bedrock", kind: .aiModel, rank: 9, place: .cloud,
                                      signals: bedrockSignals, values: ["AWS_REGION": .region], links: bedrockLinks)

    /// `GOOGLE_CLOUD_PROJECT` serves every Google Cloud product, so it only fills the link.
    static let vertexSignals: [Signal] = [
        .key("GOOGLE_GENAI_USE_VERTEXAI"), .key("CLAUDE_CODE_USE_VERTEX"), .key("ANTHROPIC_VERTEX_PROJECT_ID"),
        .host(.suffix("aiplatform.googleapis.com")),
    ]
    static let vertexProject: [FactRef] = [.value("ANTHROPIC_VERTEX_PROJECT_ID"), .value("GOOGLE_CLOUD_PROJECT")]
    static let vertexLinks: [LinkTemplate] = [
        LinkTemplate("model-garden", "Console", .web("console.cloud.google.com"),
                     path: [.text("/vertex-ai/model-garden")],
                     query: [QueryPiece("project", [.fact(vertexProject, .gcpProject)])], about: "project"),
        .web("home", "Console", "console.cloud.google.com", "/vertex-ai/model-garden"),
    ]
    static let vertexAI = ServiceEntry("vertex-ai", "Vertex AI", kind: .aiModel, rank: 10, place: .cloud,
                                       signals: vertexSignals,
                                       values: ["ANTHROPIC_VERTEX_PROJECT_ID": .id, "GOOGLE_CLOUD_PROJECT": .id],
                                       links: vertexLinks)

    static let azureDomains = ["openai.azure.com", "services.ai.azure.com", "cognitiveservices.azure.com"]
    static let azureSignals: [Signal] = [.key("AZURE_OPENAI_API_KEY")] + azureDomains.map { (domain: String) -> Signal in
        .host(.domain(domain))
    }
    /// The resource's own page needs a subscription no file names, so its name goes in the tooltip only.
    static let azureResource: [FactRef] = azureDomains.map { (domain: String) -> FactRef in
        .hostLabel(["AZURE_OPENAI_ENDPOINT"], domain: domain, index: 0, count: 1)
    }
    static let azureOpenAI = ServiceEntry("azure-openai", "Azure OpenAI", kind: .aiModel, rank: 11, place: .cloud,
                                          signals: azureSignals, values: ["AZURE_OPENAI_ENDPOINT": .url],
                                          links: [.web("foundry", "Foundry Portal", "ai.azure.com", "/", badge: "Foundry")],
                                          notes: [ServiceNote("Resource", azureResource)])

    // MARK: Replicate, Together, DeepSeek, xAI, Fireworks

    static let replicateSignals: [Signal] = [
        .key("REPLICATE_API_TOKEN"), .dependency(.pypi, "replicate"), .dependency(.npm, "replicate"),
        .named(.replicateOwner, nil),
    ]
    static let replicateModel: [Piece] = [
        .text("/"), .fact([.named(.replicateOwner)], .replicateName),
        .text("/"), .fact([.named(.replicateModel)], .replicateName),
    ]
    static let replicateLinks: [LinkTemplate] = [
        LinkTemplate("model", "Model", .web("replicate.com"), path: replicateModel, badge: "Replicate"),
        .web("api-tokens", "API Tokens", "replicate.com", "/account/api-tokens", badge: "Replicate"),
    ]
    static let replicate = ServiceEntry("replicate", "Replicate", kind: .aiModel, rank: 12, place: .cloud,
                                        signals: replicateSignals, links: replicateLinks)

    static let togetherSignals: [Signal] = [
        .key("TOGETHER_API_KEY"), .dependency(.pypi, "together"), .dependency(.npm, "together-ai"),
        .host(.domain("api.together.ai")), .host(.domain("api.together.xyz")),
    ]
    static let together = ServiceEntry("together", "Together", kind: .aiModel, rank: 13, place: .cloud,
                                       signals: togetherSignals,
                                       links: [.web("api-keys", "Console", "api.together.ai",
                                                    "/settings/projects/~current/api-keys")])

    static let deepSeek = ServiceEntry("deepseek", "DeepSeek", kind: .aiModel, rank: 14, place: .cloud,
                                       signals: [.key("DEEPSEEK_API_KEY"), .host(.domain("api.deepseek.com"))],
                                       links: [.web("api-keys", "Platform", "platform.deepseek.com", "/api_keys")])

    static let xAISignals: [Signal] = [
        .key("XAI_API_KEY"), .dependency(.pypi, "xai-sdk"), .dependency(.npm, "@ai-sdk/xai"), .host(.domain("api.x.ai")),
    ]
    static let xAI = ServiceEntry("xai", "xAI", kind: .aiModel, rank: 15, place: .cloud, signals: xAISignals,
                                  links: [.web("console", "Console", "console.x.ai", "/")])

    static let fireworksSignals: [Signal] = [
        .key("FIREWORKS_API_KEY"), .dependency(.pypi, "fireworks-ai"), .host(.domain("api.fireworks.ai")),
    ]
    static let fireworks = ServiceEntry("fireworks", "Fireworks", kind: .aiModel, rank: 16, place: .cloud,
                                        signals: fireworksSignals,
                                        links: [.web("api-keys", "Console", "app.fireworks.ai", "/settings/users/api-keys")])
}
