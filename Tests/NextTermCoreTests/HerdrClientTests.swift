import Foundation
import Testing
@testable import NextTermCore

/// herdr run in a tab on this Mac: its client in front is an agent host, read as a server's herdr is; any other herdr
/// command is a plain command, and leaving herdr is no finish.
@Suite struct HerdrClientTests {
    func process(_ arguments: [String], name: String? = nil, path: String = "") -> ForegroundProcess {
        ForegroundProcess(isShell: false, name: name ?? (arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""), arguments: arguments,
                          executablePath: path)
    }

    @Test func herdrsClientIsFoundWithItsSession() throws {
        let brew = "/opt/homebrew/bin/herdr"
        let plain = try #require(HerdrClient.match(process(["herdr"], path: brew)))
        #expect(plain.executable == brew && plain.session == nil)
        #expect(HerdrClient.match(process(["herdr", "--session", "review"], path: brew))?.session == "review")
        #expect(HerdrClient.match(process(["herdr", "--session=review"], path: brew))?.session == "review")
        #expect(HerdrClient.match(process([brew, "session", "attach", "review"], path: brew))?.session == "review")
    }

    @Test func herdrsOtherCommandsAreNotItsClient() {
        let brew = "/opt/homebrew/bin/herdr"
        #expect(HerdrClient.match(process(["herdr", "agent", "list"], path: brew)) == nil)
        #expect(HerdrClient.match(process(["herdr", "--session"], path: brew)) == nil)
        #expect(HerdrClient.match(process(["herdr", "--session", "a b"], path: brew)) == nil)
        #expect(HerdrClient.match(process(["herdr", "status"], path: brew)) == nil)
        #expect(HerdrClient.match(ForegroundProcess(isShell: true, name: "zsh")) == nil)
        // Without an absolute path to run its commands with, there is nothing to ask.
        #expect(HerdrClient.match(process(["herdr"], path: "")) == nil)
    }

    @Test func aScriptNamedHerdrIsTheExecutableAndAnyOtherIsNot() throws {
        let script = try #require(HerdrClient.match(process(["/bin/sh", "/Users/x/bin/herdr"], name: "sh", path: "/bin/sh")))
        #expect(script.executable == "/Users/x/bin/herdr" && script.session == nil)
        #expect(HerdrClient.match(process(["/bin/zsh", "/Users/x/bin/herdr", "--session", "ops"], name: "zsh", path: "/bin/zsh"))?.session == "ops")
        #expect(HerdrClient.match(process(["/bin/sh", "/Users/x/bin/herdr-tool"], name: "sh", path: "/bin/sh")) == nil)
        #expect(HerdrClient.match(process(["bash", "-c", "herdr"], name: "bash", path: "/bin/bash")) == nil)
        #expect(HerdrClient.match(process(["/usr/bin/python3", "/Users/x/bin/herdr"], name: "python3", path: "/usr/bin/python3")) == nil)
    }

    @Test func theClassifierMakesHerdrsClientAnAgentHost() {
        #expect(CommandClassifier.kind(of: "herdr") == .agent && CommandClassifier.kind(of: "herdr --session review") == .agent)
        #expect(CommandClassifier.kind(of: "herdr session attach review") == .agent)
        #expect(CommandClassifier.kind(of: "herdr status") == .command && CommandClassifier.kind(of: "herdr agent list") == .command)
        #expect(CommandClassifier.hostsAgents("HERDR_SOCKET_PATH=/tmp/h.sock ~/bin/herdr") && !CommandClassifier.hostsAgents("herdr status"))
        let script = process(["/bin/sh", "/Users/x/bin/herdr"], name: "sh", path: "/bin/sh")
        #expect(CommandClassifier.kind(of: script) == .agent && CommandClassifier.programName(of: script) == "herdr")
        #expect(CommandClassifier.hostsAgents(script))
    }

    @Test func leavingHerdrIsNoFinishWhileAnAgentsIsOne() {
        var status = TabStatus()
        status.commandStarted("herdr", at: 0)
        #expect(status.kind == .agent && status.hostsAgents)
        // Its screen redrawing is not work, and quiet is not done.
        status.output(at: 1)
        status.tick(at: 10)
        #expect(status.state == .idle)
        status.commandFinished(exitCode: 0, at: 60)
        #expect(status.state == .idle && status.unseen == nil && status.takeNotice() == nil)
        // A plain agent that ends still marks done.
        var agent = TabStatus()
        agent.commandStarted("claude -p 'fix it'", at: 0)
        agent.commandFinished(exitCode: 0, at: 60)
        #expect(agent.unseen == .done && !agent.hostsAgents)
        // A server's herdr is an agent host too.
        var remote = TabStatus()
        remote.observeAgentHost("herdr", at: 0)
        #expect(remote.hostsAgents)
    }

    @Test func aTabFollowingHerdrsAgentsPostsNoNoticeOfItsOwn() {
        var status = TabStatus()
        status.observeAgentHost("herdr", at: 0)
        status.suppressesNotices = true
        status.observe(agentScreen: .asking("codex (w1:p2) needs a decision"), at: 1)
        #expect(status.state == .attention && status.takeNotice() == nil)
        status.suppressesNotices = false
        status.observe(agentScreen: .asking("claude (w1:p1) needs a decision"), at: 2)
        #expect(status.takeNotice()?.question == "claude (w1:p1) needs a decision")
    }
}
