import Testing
@testable import NextTermCore

/// herdr itself from Next Term (plan 040 U10–U14): sessions stopped and deleted, saved machines edited, integrations,
/// channel and config, each herdr's own command and none of them sent with a session, as herdr manages them itself.
@Suite struct HerdrAdminTests {
    func argv(_ command: HerdrCommand, session: String? = "review") -> [String]? {
        command.argv(executable: "/x/herdr", session: command.takesNoSession ? nil : session, text: nil)?.first?.first.map { Array($0.dropFirst()) }
    }

    @Test func sessionsMachinesIntegrationsAndHerdrsOwnAreItsVerbs() {
        #expect(argv(.stopSession(name: "review")) == ["session", "stop", "review", "--json"])
        #expect(argv(.deleteSession(name: "review")) == ["session", "delete", "review", "--json"])
        #expect(argv(.renameMachine(id: "0123abcd", label: "Build box")) == ["machine", "rename", "0123abcd", "--label", "Build box"])
        #expect(argv(.enableMachine(id: "0123abcd", enabled: false)) == ["machine", "disable", "0123abcd"])
        #expect(argv(.removeMachine(id: "0123abcd")) == ["machine", "remove", "0123abcd"])
        #expect(argv(.integration(kind: "antigravity-cli", install: true)) == ["integration", "install", "antigravity-cli"])
        #expect(argv(.setChannel(preview: false)) == ["channel", "set", "stable"])
        #expect(argv(.configCheck) == ["config", "check"])
        // The running server's config is a session's: reload goes with it.
        #expect(argv(.reloadConfig) == ["--session", "review", "server", "reload-config"])
    }

    @Test func noneOfThemTakesASessionOrGoesToAMachine() throws {
        for command: HerdrCommand in [.stopSession(name: "a"), .deleteSession(name: "a"), .renameMachine(id: "0123abcd", label: "x"),
                                      .enableMachine(id: "0123abcd", enabled: true), .removeMachine(id: "0123abcd"), .integrations,
                                      .integration(kind: "claude", install: false), .channel, .setChannel(preview: true), .configCheck] {
            #expect(command.takesNoSession, "\(command)")
            #expect(!command.goesToMachines, "\(command)")
            let script = try #require(command.script(session: "review"))
            #expect(!script.contains("S='review'"), "\(command)")
        }
        #expect(HerdrCommand.stopSession(name: "a b").refusal(session: nil) != nil)
        #expect(HerdrCommand.renameMachine(id: "0123abcd", label: "--x").refusal(session: nil) != nil)
        #expect(HerdrCommand.integration(kind: "Claude", install: true).refusal(session: nil) != nil)
    }

    @Test func integrationStatusIsReadLineByLine() {
        let said = """
            pi: not installed (/home/u/.pi/agent/extensions/herdr-agent-state.ts)
            claude: installed (/home/u/.claude/hooks/herdr-agent-state.sh)
            codex: outdated (/home/u/.codex/herdr-agent-state.sh)
            a note without a kind
            Not A Kind: installed
            """
        let read = HerdrIntegration.parse(said)
        #expect(read.map(\.kind) == ["pi", "claude", "codex"])
        #expect(read.map(\.state) == [.notInstalled, .installed, .outdated])
    }

    @Test func aSessionHasAnIdTheTabToolsTake() {
        #expect(HerdrTarget.container(tabID: "ABC", session: "review") == "abc/session:review")
        #expect(HerdrTarget.parse("abc/session:review")?.containerKind?.kind == .session)
        #expect(HerdrTarget.parse("abc/session:review")?.containerKind?.id == "review")
    }

    @Test func theTabsSkillPointsInsideHerdrAndStaysWithinListSkills() {
        #expect(BuiltInSkill.tabs.text.contains("## Inside herdr") && BuiltInSkill.tabs.text.contains("herdr --skill"))
        #expect(BuiltInSkill.tabs.description.count <= 300)
    }
}
