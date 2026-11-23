import Foundation
import Testing
@testable import NextTermCore

/// What an Always grant's definition reads from the disk, and the bridges "Use as an MCP Server" carries over. Every
/// folder is a fixture of the test's own; every value is made up.
@Suite struct SecretAlwaysFactsTests {
    @Test func theExecutableIsResolvedWithThePathGiven() throws {
        let folder = try SecretAlwaysTests.fixture("always-facts")
        let bin = folder + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let tool = bin + "/tool"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: tool))
        chmod(tool, 0o755)
        #expect(SecretAlwaysFacts.resolve("tool", path: "/nowhere:" + bin, folder: folder) == canonicalPath(tool))
        #expect(SecretAlwaysFacts.resolve("tool", path: "/usr/bin", folder: folder) == nil)
        #expect(SecretAlwaysFacts.resolve("./bin/tool", path: nil, folder: folder) == canonicalPath(tool))
        // Another PATH is another definition, even when it finds the same file.
        let one = SecretAlwaysFacts.command(door: .tool, words: ["tool"], keys: ["K": "K"], folder: folder, path: bin, warned: [:],
                                            warnings: [], git: nil)
        let two = SecretAlwaysFacts.command(door: .tool, words: ["tool"], keys: ["K": "K"], folder: folder, path: bin + ":/usr/bin",
                                            warned: [:], warnings: [], git: nil)
        #expect(one.definition.executable == canonicalPath(tool))
        #expect(one.definition.digest != two.definition.digest)
        // Its executable in the scope: refused.
        #expect(SecretAlwaysRules.refusal(one.command, scopes: [folder], writable: { _ in false }) != nil)
    }

    /// The tool's file rewritten in place: its stamp, so the definition, changes.
    @Test func aRewrittenExecutableIsAnotherDefinition() throws {
        let folder = try SecretAlwaysTests.fixture("always-facts")
        let tool = folder + "/tool"
        try Data("#!/bin/sh\necho one\n".utf8).write(to: URL(fileURLWithPath: tool))
        chmod(tool, 0o755)
        let before = SecretAlwaysFacts.command(door: .wrapper, words: [tool], keys: ["K": "K"], folder: folder, path: nil, warned: [:],
                                               warnings: [], git: nil)
        Thread.sleep(forTimeInterval: 0.02)
        try Data("#!/bin/sh\necho two\n".utf8).write(to: URL(fileURLWithPath: tool))
        let after = SecretAlwaysFacts.command(door: .wrapper, words: [tool], keys: ["K": "K"], folder: folder, path: nil, warned: [:],
                                              warnings: [], git: nil)
        #expect(before.definition.digest != after.definition.digest)
    }

    /// The folder's `.env` and `.npmrc` are in the definition: a changed one asks again.
    @Test func theFilesThatChangeWhatItDoesAreBound() throws {
        let folder = try SecretAlwaysTests.fixture("always-facts")
        func made() -> String {
            SecretAlwaysFacts.command(door: .wrapper, words: ["/usr/bin/curl", "-sS", "https://api.example.com"], keys: ["K": "K"],
                                      folder: folder, path: nil, warned: [:], warnings: [], git: nil).definition.digest
        }
        let plain = made()
        try Data("registry=https://evil.example.com\n".utf8).write(to: URL(fileURLWithPath: folder + "/.npmrc"))
        let npmrc = made()
        try Data("API_BASE_URL=https://evil.example.com\n".utf8).write(to: URL(fileURLWithPath: folder + "/.env"))
        let env = made()
        #expect(Set([plain, npmrc, env]).count == 3)
    }

    @Test func anInterpretersScriptIsFound() throws {
        let folder = try SecretAlwaysTests.fixture("always-facts")
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/server.js"))
        #expect(SecretAlwaysFacts.script(of: ["node", "--trace-warnings", "server.js"], folder: folder) == canonicalPath(folder + "/server.js"))
        #expect(SecretAlwaysFacts.script(of: ["python3", "-m", "http.server"], folder: folder) == nil)
        #expect(SecretAlwaysFacts.script(of: ["node", "-e", "1"], folder: folder) == nil)
    }

    /// git hooks, by git's own path for them: any hook there refuses `git`, and each is in the definition.
    @Test func gitHooksAreSeen() throws {
        let folder = try SecretAlwaysTests.fixture("always-facts")
        try SecretAlwaysTests.git(["init", "-q"], in: folder)
        let none = SecretAlwaysFacts.hooks(folder: folder, git: "/usr/bin/git")
        #expect(!none.any)
        let hook = folder + "/.git/hooks/pre-push"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: hook))
        let some = SecretAlwaysFacts.hooks(folder: folder, git: "/usr/bin/git")
        #expect(some.any)
        #expect(some.digest != none.digest)
        let made = SecretAlwaysFacts.command(door: .wrapper, words: ["git", "push"], keys: ["K": "K"], folder: folder, path: "/usr/bin",
                                             warned: [:], warnings: [], git: "/usr/bin/git")
        #expect(SecretAlwaysRules.refusal(made.command, scopes: [folder], writable: { _ in false })?.contains("hooks") == true)
    }

    // MARK: bridges

    @Test func mcpRemoteBridgesToItsURL() {
        let words = ["npx", "-y", "mcp-remote@0.15.2", "https://mcp.example.com/mcp", "--header", "Authorization: Bearer ${NXTRM_API_TOKEN}"]
        let server = SecretAlwaysBridge.server(words, keys: ["API_TOKEN": "NXTRM_API_TOKEN"])
        #expect(server == SecretAlwaysBridge.Server(name: "example", url: "https://mcp.example.com/mcp",
                                                    headers: ["Authorization": "Bearer ${secret:API_TOKEN}"]))
        // Its key's variable named but no key sets it: nothing to carry over.
        #expect(SecretAlwaysBridge.server(words, keys: [:]) == nil)
        // Not a bridge, plain http, or an option it can't carry.
        #expect(SecretAlwaysBridge.server(["npx", "-y", "@acme/server@1.0.0"]) == nil)
        #expect(SecretAlwaysBridge.server(["npx", "mcp-remote@0.15.2", "http://mcp.example.com/mcp"]) == nil)
        #expect(SecretAlwaysBridge.server(["npx", "mcp-remote@0.15.2", "https://mcp.example.com/mcp", "--transport", "sse"]) == nil)
        #expect(SecretAlwaysBridge.server(["curl", "https://mcp.example.com/mcp"]) == nil)
    }
}
