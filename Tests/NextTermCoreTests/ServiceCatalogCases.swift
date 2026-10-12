import Foundation
@testable import NextTermCore

// One case per catalog entry, by kind: a made-up project that names it, its row's name, badge and main link, and a
// project that must not name it (a near miss where there is one). Values like NOT-A-KEY must never come back out.

extension ServiceCatalogTests {
    static let aiModels: [EntryCase] = [
        EntryCase("openai", [".env": "OPENAI_API_KEY=sk-test-NOT-A-KEY\n"],
                  name: "OpenAI", badge: "Platform", url: "https://platform.openai.com/",
                  not: ["requirements.txt": "openai\n", ".env": "OPENAI_BASE_URL=http://localhost:11434/v1\n"]),
        EntryCase("anthropic", ["package.json": #"{"dependencies": {"@anthropic-ai/sdk": "^0.60.0"}}"#],
                  name: "Anthropic", badge: "Console", url: "https://platform.claude.com/",
                  not: [".env": "ANTHROPIC_BASE_URL=http://localhost:4000\nANTHROPIC_API_KEY=NOT-A-KEY\n"]),
        EntryCase("google-ai-studio", [".env": "GEMINI_API_KEY=NOT-A-KEY\n"],
                  name: "Google AI Studio", badge: "AI Studio", url: "https://aistudio.google.com/apikey",
                  not: [".env": "GOOGLE_API_KEY=NOT-A-KEY\n"]),
        EntryCase("huggingface", [".env": "HF_TOKEN=hf_NOT-A-TOKEN\n"],
                  name: "Hugging Face", badge: "Hub", url: "https://huggingface.co/settings/tokens",
                  not: ["requirements.txt": "transformers\nhuggingface_hub\n"]),
        EntryCase("mistral", ["requirements.txt": "mistralai>=1.0\n"],
                  name: "Mistral", badge: "Console", url: "https://console.mistral.ai/api-keys",
                  not: ["requirements.txt": "mistral-common\n"]),
        EntryCase("groq", ["package.json": #"{"dependencies": {"groq-sdk": "^0.30.0"}}"#],
                  name: "Groq", badge: "Console", url: "https://console.groq.com/dashboard",
                  not: ["package.json": #"{"dependencies": {"graphql": "^16.0.0"}}"#]),
        EntryCase("openrouter", [".env": "OPENAI_BASE_URL=https://openrouter.ai/api/v1\n"],
                  name: "OpenRouter", badge: "Activity", url: "https://openrouter.ai/activity",
                  not: [".env": "OPENAI_BASE_URL=https://openrouter.example.com/api/v1\n"]),
        EntryCase("cohere", [".env": "CO_API_KEY=NOT-A-KEY\n"],
                  name: "Cohere", badge: "Dashboard", url: "https://dashboard.cohere.com/api-keys",
                  not: ["requirements.txt": "coherence\n"]),
        EntryCase("aws-bedrock", [".env": "CLAUDE_CODE_USE_BEDROCK=1\nAWS_REGION=eu-west-1\n"],
                  name: "AWS Bedrock", badge: "Console",
                  url: "https://eu-west-1.console.aws.amazon.com/bedrock/home?region=eu-west-1",
                  not: [".env": "AWS_REGION=eu-west-1\n"]),
        EntryCase("vertex-ai", [".env": "CLAUDE_CODE_USE_VERTEX=1\nANTHROPIC_VERTEX_PROJECT_ID=shop-ai-123\n"],
                  name: "Vertex AI", badge: "Console",
                  url: "https://console.cloud.google.com/vertex-ai/model-garden?project=shop-ai-123",
                  not: [".env": "GOOGLE_CLOUD_PROJECT=shop-ai-123\n"]),
        EntryCase("azure-openai", [".env": "AZURE_OPENAI_ENDPOINT=https://shop-ai.openai.azure.com/\n"],
                  name: "Azure OpenAI", badge: "Foundry", url: "https://ai.azure.com/",
                  not: [".env": "AZURE_OPENAI_ENDPOINT=https://shop-ai.example.com/\n"]),
        EntryCase("replicate", ["cog.yaml": "image: r8.im/acme/shop-model\n"],
                  name: "Replicate", badge: "Replicate", url: "https://replicate.com/acme/shop-model",
                  not: ["cog.yaml": "image: ghcr.io/acme/shop-model\n"]),
        EntryCase("together", ["requirements.txt": "together==1.5\n"],
                  name: "Together", badge: "Console", url: "https://api.together.ai/settings/projects/~current/api-keys",
                  not: ["requirements.txt": "togetherjs\n"]),
        EntryCase("deepseek", [".env": "DEEPSEEK_API_KEY=NOT-A-KEY\n"],
                  name: "DeepSeek", badge: "Platform", url: "https://platform.deepseek.com/api_keys",
                  not: [".env": "DEEPSEEK_MODEL=deepseek-chat\n"]),
        EntryCase("xai", ["package.json": #"{"dependencies": {"@ai-sdk/xai": "^2.0.0"}}"#],
                  name: "xAI", badge: "Console", url: "https://console.x.ai/",
                  not: ["package.json": #"{"dependencies": {"xai-tools": "^1.0.0"}}"#]),
        EntryCase("fireworks", [".env": "FIREWORKS_API_KEY=NOT-A-KEY\n"],
                  name: "Fireworks", badge: "Console", url: "https://app.fireworks.ai/settings/users/api-keys",
                  not: [".env": "FIREWORKS_MODEL=llama\n"]),
    ]
}

/// A Compose file that runs one service of this image, publishing `ports` ("6334:6333").
func composeFile(_ service: String, _ image: String, _ ports: [String] = []) -> String {
    var text = "services:\n  \(service):\n    image: \(image)\n"
    if !ports.isEmpty { text += "    ports:\n" + ports.map { (port: String) -> String in "      - \"\(port)\"\n" }.joined() }
    return text
}

extension ServiceCatalogTests {
    static let vectorStores: [EntryCase] = [
        EntryCase("qdrant", ["compose.yaml": composeFile("qdrant", "qdrant/qdrant:v1.15.0", ["6334:6333"])],
                  name: "Qdrant", badge: ":6334", url: "http://localhost:6334/dashboard",
                  not: ["requirements.txt": "qdrant-client\n"]),
        EntryCase("weaviate", [".env": "WEAVIATE_URL=shop-vectors.c0.europe-west3.gcp.weaviate.cloud\n"],
                  name: "Weaviate", badge: "Console", url: "https://console.weaviate.cloud",
                  not: [".env": "WEAVIATE_URL=http://localhost:8080\n", "requirements.txt": "weaviate-client\n"]),
        EntryCase("lancedb", [".env": "LANCEDB_URI=db://shop-vectors\n"],
                  name: "LanceDB Cloud", badge: "Cloud", url: "https://cloud.lancedb.com",
                  not: [".env": "LANCEDB_URI=./data/lancedb\n"]),
        EntryCase("chroma", ["compose.yaml": composeFile("chroma", "chromadb/chroma:1.0.0", ["8001:8000"])],
                  name: "Chroma", badge: ":8001", url: "http://localhost:8001/docs",
                  not: ["requirements.txt": "chromadb\n"]),
        EntryCase("pinecone", [".env": "PINECONE_API_KEY=pc-NOT-A-KEY\n"],
                  name: "Pinecone", badge: "Console", url: "https://app.pinecone.io/organizations/-/projects/-/indexes",
                  not: [".env": "PINECONE_INDEX=shop\n"]),
        EntryCase("milvus", [".env": "MILVUS_URI=https://in03-abc.serverless.gcp-us-west1.cloud.zilliz.com\n"],
                  name: "Zilliz Cloud", badge: "Cloud", url: "https://cloud.zilliz.com",
                  not: [".env": "MILVUS_URI=./milvus.db\n", "requirements.txt": "pymilvus\n"]),
    ]
}
