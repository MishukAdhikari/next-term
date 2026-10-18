import Foundation
@testable import NextTermCore

/// Kubernetes manifests and agents' configs for the import's tests, all made up.
extension ConfigFixtures {
    /// Bytes that aren't UTF-8.
    static let notText = Data([0xFF, 0xFE, 0x00, 0x41]).base64EncodedString()

    /// A Secret with both `stringData` and base64 `data`, a TLS Secret, and a Deployment's env.
    static var kubernetesYAML: String {
        """
        apiVersion: v1
        kind: Secret
        metadata:
          name: openai
        type: Opaque
        stringData:
          api-key: \(F.openAI)
        data:
          api-key: \(base64(F.openAIOld))
          org-id: \(base64("org-made-up-0000\n"))
          binary: \(notText)
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: web-tls
        type: kubernetes.io/tls
        data:
          tls.crt: \(base64("made-up certificate"))
          tls.key: \(base64("made-up key"))
        ---
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: api
        spec:
          template:
            spec:
              containers:
                - name: api
                  image: example.invalid/api:1
                  env:
                    - name: LANGSMITH_API_KEY
                      value: \(F.langSmith)
                    - name: PINECONE_API_KEY
                      valueFrom:
                        secretKeyRef: {name: pinecone, key: api-key}

        """
    }

    /// goose's `config.yaml`: its settings at the root, and an extension's `envs`.
    static var gooseYAML: String {
        """
        GOOSE_PROVIDER: openai
        GOOSE_MODEL: gpt-5
        extensions:
          github:
            name: GitHub
            cmd: npx
            args: [-y, "@modelcontextprotocol/server-github"]
            enabled: true
            envs:
              GITHUB_PERSONAL_ACCESS_TOKEN: \(github)
            type: stdio
          developer:
            enabled: true
            type: builtin

        """
    }

    /// Continue's `config.yaml`: a model's `apiKey`, and an MCP server's `env` with a secret of Continue's own.
    static var continueYAML: String {
        """
        name: Made-up Assistant
        version: 1.0.0
        schema: v1
        models:
          - name: Claude
            provider: anthropic
            model: claude-made-up
            apiKey: \(E.anthropic)
        mcpServers:
          - name: search
            command: npx
            args: ["-y", "search-mcp"]
            env:
              TAVILY_API_KEY: \(E.tavily)
              SHARED: ${{ secrets.SHARED_KEY }}

        """
    }

    /// Zed's `settings.json`: a server's `env`, one in the older `command` object, and an extension's settings.
    static var zedJSON: String {
        """
        {
          // made up for a test
          "theme": "One Dark",
          "context_servers": {
            "github": {
              "source": "custom",
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "\(github)" }
            },
            "older-shape": {
              "command": { "path": "uvx", "args": ["search-mcp"], "env": { "TAVILY_API_KEY": "\(E.tavily)" } }
            },
            "mcp-server-linear": {
              "source": "extension",
              "settings": { "linear_api_key": "\(E.linear)" }
            }
          },
        }
        """
    }

    /// Devin Desktop's `mcp_config.json`.
    static var devinJSON: String {
        """
        {"mcpServers": {"search": {"command": "npx", "args": ["-y", "search-mcp"], "env": {"TAVILY_API_KEY": "\(E.tavily)"}}}}
        """
    }

    /// Claude Code's `settings.json`, with its `env`.
    static var claudeSettingsJSON: String {
        """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "permissions": { "allow": ["Bash(npm run test)"] },
          "env": { "ANTHROPIC_API_KEY": "\(E.anthropic)", "CLAUDE_CODE_ENABLE_TELEMETRY": "0" }
        }
        """
    }
}
