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

extension ServiceCatalogTests {
    static let tracing: [EntryCase] = [
        EntryCase("langsmith", [".env": "LANGSMITH_TRACING=true\nLANGSMITH_API_KEY=lsv2-NOT-A-KEY\n"],
                  name: "LangSmith", badge: "Projects", url: "https://smith.langchain.com",
                  not: ["requirements.txt": "langsmith\n"]),
        EntryCase("litellm", ["compose.yaml": composeFile("proxy", "ghcr.io/berriai/litellm:main-stable", ["4001:4000"])],
                  name: "LiteLLM", badge: ":4001", url: "http://localhost:4001/ui",
                  not: ["requirements.txt": "litellm\n"]),
        EntryCase("langfuse", [".env": "LANGFUSE_SECRET_KEY=sk-lf-NOT-A-KEY\n"],
                  name: "Langfuse", badge: "Projects", url: "https://cloud.langfuse.com",
                  not: [".env": "LANGFUSE_HOST=http://langfuse.example.com\n", "requirements.txt": "langfuse\n"]),
        EntryCase("mlflow", ["requirements.txt": "mlflow\n", "mlruns/0/meta.yaml": "name: Default\n"],
                  name: "MLflow", badge: ":5000", url: "http://127.0.0.1:5000",
                  not: ["requirements.txt": "mlflow\n"]),
        EntryCase("braintrust", [".env": "BRAINTRUST_ORG_NAME=acme\nBRAINTRUST_DEFAULT_PROJECT=\"My App\"\n",
                                 "package.json": #"{"dependencies": {"braintrust": "^0.4.0"}}"#],
                  name: "Braintrust", badge: "Logs", url: "https://www.braintrust.dev/app/acme/p/My%20App/logs",
                  not: [".env": "BRAINTRUST_ORG_NAME=acme\n"]),
        EntryCase("opik", ["requirements.txt": "opik\n"],
                  name: "Opik", badge: "Projects", url: "https://www.comet.com/opik/",
                  not: ["requirements.txt": "opik-optimizer\n"]),
        EntryCase("wandb-weave", [".env": "WANDB_API_KEY=NOT-A-KEY\nWANDB_ENTITY=acme\nWANDB_PROJECT=shop-bot\n"],
                  name: "W&B Weave", badge: "Weave", url: "https://wandb.ai/acme/shop-bot/weave",
                  not: [".env": "WANDB_MODE=offline\n"]),
        EntryCase("arize-phoenix", ["requirements.txt": "arize-phoenix\n"],
                  name: "Arize Phoenix", badge: ":6006", url: "http://localhost:6006/projects",
                  not: ["requirements.txt": "phoenix-utils\n"]),
        EntryCase("helicone", [".env": "OPENAI_BASE_URL=https://oai.helicone.ai/v1\n"],
                  name: "Helicone", badge: "Requests", url: "https://us.helicone.ai/requests",
                  not: [".env": "OPENAI_BASE_URL=https://helicone.example.com/v1\n"]),
    ]
}

extension ServiceCatalogTests {
    static let agents: [EntryCase] = [
        EntryCase("langgraph", ["langgraph.json": #"{"graphs": {"agent": "./agent.py:graph"}}"#],
                  name: "LangGraph", badge: "Studio", url: "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024",
                  not: ["requirements.txt": "langgraph\n"]),
        EntryCase("temporal", [".env": "TEMPORAL_ADDRESS=localhost:7233\n"],
                  name: "Temporal", badge: ":8233", url: "http://localhost:8233",
                  not: ["requirements.txt": "temporalio\n"]),
        EntryCase("google-adk", ["requirements.txt": "google-adk\n"],
                  name: "Google ADK", badge: ":8000", url: "http://localhost:8000",
                  not: ["requirements.txt": "google-genai\n"]),
        EntryCase("inngest", ["package.json": #"{"dependencies": {"inngest": "^3.40.0"}}"#],
                  name: "Inngest", badge: ":8288", url: "http://localhost:8288",
                  not: ["package.json": #"{"devDependencies": {"@inngest/eslint-plugin": "^0.0.7"}}"#]),
        EntryCase("mastra", ["package.json": #"{"dependencies": {"@mastra/core": "^0.20.0"}}"#],
                  name: "Mastra", badge: ":4111", url: "http://localhost:4111",
                  not: ["package.json": #"{"dependencies": {"@mastra/client-js": "^0.20.0"}}"#]),
        EntryCase("trigger-dev", ["trigger.config.ts": "export default defineConfig({ project: \"proj_abcdefghijklmnop\" })\n"],
                  name: "Trigger.dev", badge: "Project", url: "https://cloud.trigger.dev/projects/v3/proj_abcdefghijklmnop",
                  not: ["trigger.config.ts": "export default defineConfig({ project: process.env.TRIGGER_PROJECT })\n"]),
        EntryCase("crewai", ["pyproject.toml": "[project]\nname = \"crew\"\n\n[tool.crewai]\ntype = \"crew\"\n"],
                  name: "CrewAI", badge: "AMP", url: "https://app.crewai.com",
                  not: ["requirements.txt": "crewai-tools-lite\n"]),
        EntryCase("n8n", ["compose.yaml": composeFile("n8n", "docker.n8n.io/n8nio/n8n:1.110.0", ["5679:5678"])],
                  name: "n8n", badge: ":5679", url: "http://localhost:5679",
                  not: [".env": "N8N_EDITOR_BASE_URL=javascript:alert(1)\n"]),
        EntryCase("langflow", ["requirements.txt": "langflow==1.5\n"],
                  name: "Langflow", badge: ":7860", url: "http://localhost:7860",
                  not: ["requirements.txt": "langchain\n"]),
    ]
}

/// A `package.json` with these dependencies and scripts.
func packageJSON(_ dependencies: [String], scripts: [String: String] = [:]) -> String {
    let deps = dependencies.map { (name: String) -> String in "\"\(name)\": \"^1.0.0\"" }.joined(separator: ", ")
    let lines = scripts.keys.sorted().map { (name: String) -> String in "\"\(name)\": \"\(scripts[name] ?? "")\"" }
    return "{\"dependencies\": {\(deps)}, \"scripts\": {\(lines.joined(separator: ", "))}}"
}

extension ServiceCatalogTests {
    static let localServers: [EntryCase] = [
        EntryCase("vite", ["package.json": packageJSON(["vite"], scripts: ["dev": "vite --port 5174"])],
                  name: "Vite", badge: ":5174", url: "http://localhost:5174",
                  not: ["package.json": packageJSON(["vitest"])]),
        EntryCase("fastapi", ["requirements.txt": "fastapi[standard]>=0.115\n"],
                  name: "FastAPI", badge: ":8000", url: "http://localhost:8000/docs",
                  not: ["requirements.txt": "fastapi-utils\n"]),
        EntryCase("nextjs", ["package.json": packageJSON(["next"], scripts: ["dev": "next dev -p 3100"])],
                  name: "Next.js", badge: ":3100", url: "http://localhost:3100",
                  not: ["package.json": packageJSON(["next-auth"])]),
        EntryCase("flask", ["requirements.txt": "Flask==3.1\n", ".flaskenv": "FLASK_RUN_PORT=5050\n"],
                  name: "Flask", badge: ":5050", url: "http://127.0.0.1:5050",
                  not: ["requirements.txt": "flask-cors\n"]),
        EntryCase("storybook", ["package.json": packageJSON(["storybook"], scripts: ["storybook": "storybook dev -p 6007"])],
                  name: "Storybook", badge: ":6007", url: "http://localhost:6007",
                  not: ["package.json": packageJSON(["@storybook/addon-docs"])]),
        EntryCase("django", ["manage.py": "#!/usr/bin/env python\n", "requirements.txt": "Django>=5.2\n"],
                  name: "Django", badge: ":8000", url: "http://127.0.0.1:8000",
                  not: ["requirements.txt": "django\n"]),
        EntryCase("jupyter", ["requirements.txt": "jupyterlab\n", "analysis.ipynb": "{}\n"],
                  name: "Jupyter", badge: ":8888", url: "http://localhost:8888/lab",
                  not: ["requirements.txt": "jupyterlab\n"]),
        EntryCase("astro", ["package.json": packageJSON(["astro"]), "astro.config.mjs": "export default { server: { port: 4400 } }\n"],
                  name: "Astro", badge: ":4400", url: "http://localhost:4400",
                  not: ["package.json": packageJSON(["astro-icon"])]),
        EntryCase("streamlit", [".streamlit/config.toml": "[server]\nport = 8600\n"],
                  name: "Streamlit", badge: ":8600", url: "http://localhost:8600",
                  not: ["requirements.txt": "streamlit-aggrid\n"]),
        EntryCase("nuxt", ["package.json": packageJSON(["nuxt"])],
                  name: "Nuxt", badge: ":3000", url: "http://localhost:3000",
                  not: ["package.json": packageJSON(["nuxt-icon"])]),
        EntryCase("gradio", ["requirements.txt": "gradio\n"],
                  name: "Gradio", badge: ":7860", url: "http://127.0.0.1:7860",
                  not: ["requirements.txt": "gradio-client\n"]),
        EntryCase("chainlit", ["requirements.txt": "chainlit\n", "chainlit.md": "# Welcome\n"],
                  name: "Chainlit", badge: ":8000", url: "http://localhost:8000",
                  not: ["requirements.txt": "chainlit\n"]),
        EntryCase("rails", ["Gemfile": "source \"https://rubygems.org\"\ngem \"rails\", \"~> 8.0\"\n"],
                  name: "Rails", badge: ":3000", url: "http://localhost:3000",
                  not: ["Gemfile": "gem \"railties\"\n"]),
        EntryCase("phoenix", ["mix.exs": "defp deps do\n  [{:phoenix, \"~> 1.8\"}]\nend\n"],
                  name: "Phoenix", badge: ":4000", url: "http://localhost:4000",
                  not: ["mix.exs": "defp deps do\n  [{:phoenix_html, \"~> 4.0\"}]\nend\n"]),
        EntryCase("herd", ["herd.yml": "name: shop\nsecured: true\n"],
                  name: "Herd", badge: "Site", url: "https://shop.test",
                  not: [".env": "APP_URL=http://localhost:8000\n"]),
        EntryCase("ddev", [".ddev/config.yaml": "name: shop\ntype: laravel\n"],
                  name: "DDEV", badge: "Site", url: "https://shop.ddev.site",
                  not: [".ddev/README.txt": "Not a config\n"]),
    ]
}

extension ServiceCatalogTests {
    static let backends: [EntryCase] = [
        EntryCase("supabase", [".env.local": "NEXT_PUBLIC_SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co\n"],
                  name: "Supabase", badge: "Dashboard", url: "https://supabase.com/dashboard/project/abcdefghijklmnopqrst",
                  not: [".env": "SUPABASE_URL=http://127.0.0.1:54321\n"]),
        EntryCase("firebase", [".firebaserc": #"{"projects": {"default": "shop-prod"}}"#],
                  name: "Firebase", badge: "Console", url: "https://console.firebase.google.com/project/shop-prod/overview",
                  not: [".env": "FIREBASE_TOKEN=NOT-A-TOKEN\n"]),
        EntryCase("upstash", [".env": "UPSTASH_REDIS_REST_URL=https://wise-cat-12345.upstash.io\n"],
                  name: "Upstash", badge: "Console", url: "https://console.upstash.com/redis",
                  not: [".env": "REDIS_URL=redis://localhost:6379\n"]),
        EntryCase("convex", [".env.local": "CONVEX_DEPLOYMENT=dev:happy-otter-123 # team: acme, project: shop\n"],
                  name: "Convex", badge: "Dashboard", url: "https://dashboard.convex.dev/d/happy-otter-123",
                  not: [".env.local": "CONVEX_DEPLOYMENT=local:shop-dev\n"]),
    ]
}

extension ServiceCatalogTests {
    static let hosting: [EntryCase] = [
        EntryCase("vercel", [".vercel/project.json": #"{"projectId": "prj_abc123", "orgId": "team_abc123", "projectName": "shop-web"}"#],
                  name: "Vercel", badge: "Dashboard", url: "https://vercel.com/dashboard",
                  not: [".vercel/README.txt": "Not a project link\n"]),
        EntryCase("cloudflare", ["wrangler.toml": "name = \"shop\"\naccount_id = \"0123456789abcdef0123456789abcdef\"\n"],
                  name: "Cloudflare", badge: "Dashboard",
                  url: "https://dash.cloudflare.com/0123456789abcdef0123456789abcdef/workers-and-pages",
                  not: ["wrangler.example.toml": "name = \"shop\"\n"]),
        EntryCase("fly", ["fly.toml": "app = \"shop-api\"\nprimary_region = \"ams\"\n"],
                  name: "Fly.io", badge: "App", url: "https://fly.io/apps/shop-api",
                  not: ["fly.example.toml": "app = \"shop-api\"\n"]),
        EntryCase("railway", ["railway.json": #"{"build": {"builder": "NIXPACKS"}}"#],
                  name: "Railway", badge: "Dashboard", url: "https://railway.com/dashboard",
                  not: [".env": "RAILWAY_TOKEN=NOT-A-TOKEN\n"]),
        EntryCase("render", ["render.yaml": "services:\n  - type: web\n    name: shop\n"],
                  name: "Render", badge: "Dashboard", url: "https://dashboard.render.com",
                  not: [".env": "RENDER_API_KEY=NOT-A-KEY\n"]),
    ]
}
