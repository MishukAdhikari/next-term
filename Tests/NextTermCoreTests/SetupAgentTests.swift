import Foundation
import Testing
@testable import NextTermCore

@Suite struct SetupAgentTests {
    let home = "/nonexistent-\(UUID().uuidString)"

    /// Every program the agents Next Term registers in might have, as found along PATH.
    let everyProgram: [String: String] = Dictionary(uniqueKeysWithValues: [
        "claude", "codex", "command-code", "opencode", "cursor-agent", "gemini", "qwen", "copilot", "amp", "junie",
    ].map { ($0, "/usr/local/bin/" + $0) })

    @Test func claudeCodeCodexAndCommandCodeComeFirstThenTheRestByName() {
        let ids = ["claude", "codex", "commandcode", "opencode", "cursor", "gemini", "qwen", "copilot", "amp", "junie"]
        let statuses = Dictionary(uniqueKeysWithValues: ids.map { ($0, MCPRegistrar.Status.registered) })
        let agents = SetupAgent.offered(programs: everyProgram, statuses: statuses, home: home)
        #expect(agents.map(\.name) == ["Claude Code", "Codex", "Command Code", "Copilot CLI", "Cursor", "Gemini CLI", "OpenCode", "Qwen Code"])
        // Amp and Junie take no first message they keep talking after, so they are not offered.
        #expect(!agents.contains { $0.id == "amp" || $0.id == "junie" })
    }

    @Test func onlyAgentsNextTermIsInWithTheirProgramOnPathAreOffered() {
        let statuses: [String: MCPRegistrar.Status] = [
            "claude": .alreadyRegistered, "codex": .registered, "commandcode": .nameTaken, "gemini": .skipped("x"),
            "opencode": .notInstalled, "cursor": .registered, "claude-desktop": .registered,
        ]
        // Cursor is registered by its ~/.cursor folder, but its program is not on PATH.
        let programs = everyProgram.filter { $0.key != "cursor-agent" }
        let agents = SetupAgent.offered(programs: programs, statuses: statuses, home: home)
        #expect(agents.map(\.id) == ["claude", "codex"])
        #expect(SetupAgent.offered(programs: [:], statuses: statuses, home: home).isEmpty)
        #expect(SetupAgent.offered(programs: everyProgram, statuses: [:], home: home).isEmpty)
    }

    @Test func theProgramIsTheNameFoundOnPath() {
        let agents = SetupAgent.offered(programs: ["commandcode": "/opt/bin/commandcode"], statuses: ["commandcode": .registered], home: home)
        #expect(agents == [SetupAgent(id: "commandcode", name: "Command Code", program: "commandcode")])
    }

    @Test func eachAgentStartsWithTheSetupPromptAsItsFirstMessage() {
        let quoted = ShellQuote.quote(MCPServer.setupPrompt)
        // One line: the prompt's line breaks are written as \x0A, so nothing runs before the agent does.
        #expect(quoted.hasPrefix("$'") && !quoted.contains("\n"))
        #expect(SetupAgent.commandLine(id: "claude", program: "claude") == "claude " + quoted)
        #expect(SetupAgent.commandLine(id: "codex", program: "codex") == "codex " + quoted)
        #expect(SetupAgent.commandLine(id: "commandcode", program: "command-code") == "command-code " + quoted)
        #expect(SetupAgent.commandLine(id: "cursor", program: "cursor-agent") == "cursor-agent " + quoted)
        #expect(SetupAgent.commandLine(id: "opencode", program: "opencode") == "opencode --prompt=" + quoted)
        #expect(SetupAgent.commandLine(id: "gemini", program: "gemini") == "gemini -i " + quoted)
        #expect(SetupAgent.commandLine(id: "qwen", program: "qwen") == "qwen -i " + quoted)
        #expect(SetupAgent.commandLine(id: "copilot", program: "copilot") == "copilot -i " + quoted)
        #expect(SetupAgent(id: "codex", name: "Codex", program: "codex").commandLine == "codex " + quoted)
    }

    @Test func noLineAnswersTheAgentsOwnQuestions() {
        let agents = SetupAgent.offered(programs: everyProgram,
                                        statuses: Dictionary(uniqueKeysWithValues: SetupAgent.promptOption.keys.map { ($0, .registered) }),
                                        home: home)
        #expect(agents.count == SetupAgent.promptOption.count)
        let prompt = ShellQuote.quote(MCPServer.setupPrompt)
        for agent in agents {
            let options = agent.commandLine.replacingOccurrences(of: prompt, with: "")
            for word in ["--trust", "-t", "--yolo", "--dangerously", "--allow-all", "--force", "--auto", "--accept", "-y", "--approval"] {
                #expect(!options.split(separator: " ").contains { $0.hasPrefix(word) && ($0 == word || word.hasPrefix("--")) },
                        "\(agent.name): \(options)")
            }
        }
    }
}
