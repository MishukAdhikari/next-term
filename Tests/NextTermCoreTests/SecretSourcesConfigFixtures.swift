import Foundation
@testable import NextTermCore

/// TOML, YAML and agents' config files for the import's tests: made-up projects, servers and values. Each value is a
/// provider's head and filler, put together at run time, so no file here holds a key-shaped string whole.
enum ConfigFixtures {
    typealias F = SecretSourcesFixtures
    typealias E = ExportFixtures

    static let github = "ghp_" + "Lp9Zc3Hd7Kf1Wj5Ys0EaQm4Rt8Vx2Bn6Mq7T"
    static let azure = "4f8a1c9e" + "2b7d6a3f" + "0e5c9b1d" + "8a2f7c4e"
    static let cargo = "cio" + "Qm4Rt8Vx2Bn6Lp9Zc3Hd7Kf1Wj5Ys0Ea"
    static let registry = "made-up-" + "Wq8Lm2Np7Rt4Vx9Bc3Df6Gh1Jk"
    static let password = "Wq8Lm2Np7Rt4" + "Vx9Bc3Df"

    static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// Codex's `config.toml`: a model provider's bearer token, an MCP server's env as an inline table and as a table,
    /// a server that only names the variable holding its token, and the shell's `set`.
    static var codexTOML: String {
        """
        model = "gpt-5"
        model_provider = "azure"

        [model_providers.azure]
        name = "Azure"
        base_url = "https://made-up.openai.example/openai"
        env_key = "AZURE_OPENAI_API_KEY"
        experimental_bearer_token = "\(azure)"

        [mcp_servers.github]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-github"]
        env = { GITHUB_PERSONAL_ACCESS_TOKEN = "\(github)", LOG_LEVEL = "debug" }

        [mcp_servers.linear]
        url = "https://mcp.linear.example/mcp"
        bearer_token_env_var = "LINEAR_API_KEY"

        [mcp_servers.search.env]
        TAVILY_API_KEY = "\(E.tavily)"

        [shell_environment_policy]
        inherit = "core"
        set = { OPENAI_API_KEY = "\(F.openAI)", PATH_EXTRA = "/opt/made-up/bin" }

        """
    }

    /// Streamlit's `.streamlit/secrets.toml`: a key at the root, and keys in sections.
    static var streamlitTOML: String {
        """
        OPENAI_API_KEY = "\(F.openAI)"
        page_title = "Rag demo"

        [pinecone]
        api_key = "\(F.pinecone)"
        environment = "us-east-1"

        [connections.postgresql]
        dialect = "postgresql"
        host = "localhost"
        password = "\(password)"

        """
    }

    /// Cargo's `credentials.toml`: crates.io's token and another registry's.
    static var cargoTOML: String {
        """
        [registry]
        token = "\(cargo)"

        [registries.made-up-registry]
        token = "\(registry)"

        """
    }

    /// A Compose service's `environment` as a map.
    static var composeMap: String {
        """
        services:
          api:
            image: example.invalid/rag-api:1.4
            environment:
              OPENAI_API_KEY: \(F.openAI)
              LOG_LEVEL: info
              PINECONE_API_KEY: ${PINECONE_API_KEY}
              FROM_SHELL:

        """
    }

    /// The same service's `environment` as a list.
    static var composeList: String {
        """
        services:
          api:
            image: example.invalid/rag-api:1.4
            environment:
              - OPENAI_API_KEY=\(F.openAI)
              - LOG_LEVEL=info
              - PINECONE_API_KEY=${PINECONE_API_KEY}
              - FROM_SHELL

        """
    }
}
