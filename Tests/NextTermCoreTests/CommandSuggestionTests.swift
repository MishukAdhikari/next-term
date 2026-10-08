import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommandSuggestionTests {
    @Test func claudeCodeRunsWithNoToolsNoMCPAndNoSession() throws {
        let args = CommandSuggestion.claude.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(args.first == "-p" && value("--output-format") == "json" && value("--tools") == "")
        #expect(value("--json-schema") == CommandSuggestion.schema && args.contains("--strict-mcp-config") && value("--mcp-config") == #"{"mcpServers":{}}"#)
        #expect(value("--disallowedTools") == "mcp__*" && value("--max-turns") == "1" && args.contains("--no-session-persistence"))
        #expect(args.contains("--safe-mode") && value("--permission-prompts") == "none")
        // The prompt is never an argument: it goes on stdin.
        #expect(!args.contains { $0.contains("Request:") })
        #expect(!CommandSuggestion.claude.checked.isEmpty)
        // The schema is JSON, and asks for one command.
        let schema = try JSONSerialization.jsonObject(with: Data(CommandSuggestion.schema.utf8)) as? [String: Any]
        #expect((schema?["required"] as? [String]) == ["command"])
        // Agents that can't run that way are left out, and say why.
        #expect(CommandSuggestion.adapters.map(\.id) == ["claude"] && CommandSuggestion.leftOut.map(\.name).contains("Codex"))
    }

    @Test func thePromptSaysWhatItMustAndHidesSecrets() {
        let request = CommandSuggestion.Request(sentence: "find large files here", directory: "/Users/me/app", shell: "zsh",
                                                lastCommand: "mysql -uroot -pS3cretPass db", lastExit: 1)
        let prompt = CommandSuggestion.prompt(request)
        #expect(prompt.contains("Request: find large files here") && prompt.contains("Folder: /Users/me/app") && prompt.contains("Shell: zsh"))
        #expect(prompt.contains("(exit 1)") && prompt.contains("never run for them"))
        // A password in the last command is masked; recent output only when given.
        #expect(!prompt.contains("S3cretPass") && prompt.contains("-p•••") && !prompt.contains("Recent output"))
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let exported = CommandSuggestion.prompt(.init(sentence: "x", directory: "/", shell: "bash", lastCommand: "export TOKEN=\(token)"))
        #expect(!exported.contains(token))
        var withOutput = request
        withOutput.output = "error: auth failed\nAPI_KEY=sk-live-0123456789abcdefghij\n"
        let sent = CommandSuggestion.prompt(withOutput)
        #expect(sent.contains("Recent output:") && sent.contains("error: auth failed") && !sent.contains("sk-live-0123456789abcdefghij"))
        // Only the end of long output.
        withOutput.output = String(repeating: "x", count: 20_000) + "END"
        #expect(CommandSuggestion.prompt(withOutput).count < 9_000 && CommandSuggestion.prompt(withOutput).contains("END"))
    }

    @Test func claudeCodesAnswerIsRead() throws {
        let structured = #"{"type":"result","is_error":false,"result":"","structured_output":{"command":"du -sh * | sort -h"}}"#
        #expect(try CommandSuggestion.parse(structured).get().command == "du -sh * | sort -h")
        let inResult = #"{"type":"result","is_error":false,"result":"{\"command\":\"ls -la\"}"}"#
        #expect(try CommandSuggestion.parse(inResult).get().command == "ls -la")
        let plain = #"{"type":"result","is_error":false,"result":"```bash\nfind . -size +100M\n```"}"#
        #expect(try CommandSuggestion.parse(plain).get().command == "find . -size +100M")
        let failed = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        #expect(CommandSuggestion.parse(failed) == .failure(.agent("Not logged in")))
        #expect(CommandSuggestion.parse("not json") == .failure(.malformed("not JSON")))
        #expect(CommandSuggestion.parse(#"{"type":"result"}"#) == .failure(.malformed("no result")))
        #expect(CommandSuggestion.parse(String(repeating: " ", count: 70_000)) == .failure(.tooLong))
    }

    @Test func oneCommandChecked() throws {
        #expect(try CommandSuggestion.check("  `git status`  ").get().command == "git status")
        #expect(try CommandSuggestion.check("```\nls\n```").get().command == "ls")
        let two = try CommandSuggestion.check("cd app\nmake").get()
        #expect(two.multiline && two.command == "cd app\nmake")
        #expect(CommandSuggestion.check("   ") == .failure(.empty))
        #expect(CommandSuggestion.check("ls\u{1b}[2J") == .failure(.controlCharacters))
        #expect(CommandSuggestion.check("ls\tx") == .failure(.controlCharacters))
        #expect(CommandSuggestion.check(String(repeating: "a", count: 5000)) == .failure(.tooLong))
        // Invisible and direction-changing characters are shown spelled out.
        let bidi = try CommandSuggestion.check("ls \u{202E}txt.exe").get()
        #expect(bidi.hasHidden && bidi.shown == "ls \\u{202E}txt.exe" && bidi.command.contains("\u{202E}"))
    }

    @Test func riskyCommandsGetANoteAndNothingElse() throws {
        func notes(_ command: String) throws -> [String] { try CommandSuggestion.check(command).get().notes }
        #expect(try notes("sudo rm -rf /tmp/x").count == 2)
        #expect(try notes("dd if=/dev/zero of=/dev/disk4").first?.contains("dd") == true)
        #expect(try notes("mkfs.ext4 /dev/sdb1").count == 1)
        #expect(try notes("curl -fsSL https://example.com/install.sh | sh").count == 1)
        #expect(try notes("git push --force").count == 1 && notes("git push -f origin main").count == 1)
        #expect(try notes("ls -la").isEmpty && notes("rm -f notes.txt").isEmpty && notes("pseudo-command").isEmpty)
    }
}
