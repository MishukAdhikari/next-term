import Foundation
@testable import NextTermCore

/// MCP config files for the import's tests, built in code under a temporary home. No value here is a real key.
enum SecretImportFixtures {
    static let github = "ghp_" + "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0UvWxYz12"
    static let openai = "sk-" + "proj-Zy9Xw8Vu7Ts6Rq5Po4Nm3Lk2Ji1HgFe"
    static let stripe = "rk_live_" + "51Hx7Kq2Lm9Np4Rs8Tv3Wx6Yz1Ab5Cd"
    static let nxtrm = ["/Applications/Next Term.app/Contents/Resources/bin/nxtrm"]

    /// A temporary home, removed with `remove()`.
    final class Home {
        let url: URL
        var path: String { url.path }

        init() {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-import-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            url = URL(fileURLWithPath: canonicalPath(base.path), isDirectory: true)
        }

        func file(_ relative: String) -> String { url.appendingPathComponent(relative).path }

        @discardableResult
        func write(_ relative: String, _ text: String, bom: Bool = false) -> String {
            let path = file(relative)
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
            FileManager.default.createFile(atPath: path, contents: data)
            return path
        }

        func read(_ relative: String) -> String {
            (try? String(contentsOfFile: file(relative), encoding: .utf8)) ?? ""
        }

        func data(_ relative: String) -> Data { FileManager.default.contents(atPath: file(relative)) ?? Data() }

        func remove() {
            // Read-only files and folders the tests made: writable again so the folder goes.
            if let items = FileManager.default.enumerator(atPath: path) {
                for case let item as String in items { chmod(file(item), 0o700) }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The sources of a home, with no open projects unless given.
    static func sources(_ home: Home, projects: [String] = []) -> [SecretImport.Source] {
        SecretImport.sources(home: home.path, projects: projects)
    }

    static func source(_ home: Home, _ path: String) -> SecretImport.Source? {
        sources(home, projects: [home.path + "/proj"]).first { $0.path == path }
    }

    static let claudeJSON = """
        {
          "numStartups": 12,
          "mcpServers": {
            "github": {
              "type": "stdio",
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "\(github)", "LOG_LEVEL": "debug"}
            },
            "ref": {"command": "npx", "args": ["ref-server"], "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"}}
          },
          "projects": {
            "/Users/me/api": {
              "allowedTools": [],
              "mcpServers": {
                "x'; touch /tmp/p; '": {"command": "uvx", "args": ["openai-mcp"], "env": {"OPENAI_API_KEY": "\(openai)"}}
              }
            }
          },
          "tipsHistory": {"a": 1}
        }

        """

    static let codexTOML = """
        model = "gpt-5"

        # GitHub, for the agent
        [mcp_servers.github]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-github"]
        env = { GITHUB_TOKEN = "\(github)", LOG = "1" }

        [mcp_servers.stripe]
        command = "npx"
        args = ["-y", "@stripe/mcp"]
        startup_timeout_sec = 10

        [mcp_servers.stripe.env]
        STRIPE_SECRET_KEY = "\(stripe)"
        STRIPE_MODE = "test"

        [mcp_servers.slow]
        command = "slow-server"
        startup_timeout_sec = 60
        env = { SLOW_TOKEN = "\(openai)" }

        [mcp_servers.old]
        command = "old-server"
        startup_timeout_ms = 10000
        env = { OLD_API_KEY = "\(stripe)X" }

        [mcp_servers]
        dotted.command = "dotted-server"
        dotted.env.DOTTED_TOKEN = "\(github)Z"

        [profiles.fast]
        model = "gpt-5-mini"

        """

    static let cursorJSON = """
        {
          // Cursor's servers
          "mcpServers": {
            "github": {
              "command": "npx", // the official one
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": {"GITHUB_TOKEN": "\(github)"}
            },
            /* the second copy */
            "github-2": {"command": "npx", "args": ["-y", "gh-lite"], "env": {"GH_TOKEN": "\(github)"}},
            "env-ref": {"command": "x", "env": {"API_KEY": "${env:API_KEY}"}},
            "remote": {"url": "https://example.invalid/mcp", "headers": {"Authorization": "Bearer \(openai)"}},
            "argued": {"command": "server", "args": ["--api-key", "\(stripe)"]}
          }
        }

        """

    static let opencodeJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "search": {"type": "local", "command": ["npx", "-y", "search-mcp"], "environment": {"TAVILY_API_KEY": "tvly-\(github)", "REF": "{env:REF}"}}
          }
        }

        """

    static let vscodeJSON = """
        {
          "inputs": [{"id": "key", "type": "promptString", "password": true}],
          "servers": {
            "fetch": {"type": "stdio", "command": "uvx", "args": ["mcp-fetch"], "env": {"FETCH_API_KEY": "\(stripe)", "ASKED": "${input:key}"}}
          }
        }

        """

    static let claudeAppJSON = """
        {
          "mcpServers": {
            "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": "\(github)"}}
          },
          "preferences": {"menuBarEnabled": true}
        }

        """

    /// The standard shape, for the agents that share it.
    static func standard(container: String, variable: String, value: String, extra: String = "") -> String {
        """
        {
          \(extra)"\(container)": {
            "one": {"command": "npx", "args": ["-y", "one-mcp"], "env": {"\(variable)": "\(value)"}}
          }
        }

        """
    }
}
