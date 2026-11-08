import Foundation
import Testing
@testable import NextTermCore

/// Continue in Chat and Open in Terminal (plan 037 U2): which tabs offer a handoff, the refusals in their order, and the
/// target a handoff opens, which must name only the conversation the source holds. Ported from plan 036's switch rules,
/// with the typed line in the same tab replaced by a new tab of the other kind.
@Suite struct ConversationHandoffTests {
    private let claudeID = "8f3a1c2e-1b2c-4d5e-8f90-0a1b2c3d4e5f"
    private let codexID = "019a2b3c-4d5e-7f60-8a1b-2c3d4e5f6a7b"

    private typealias Handoff = ConversationHandoff

    private func terminal(_ agent: Handoff.Agent) -> Handoff.Offer { Handoff.Offer(agent: agent, from: .terminal) }
    private func chat(_ agent: Handoff.Agent) -> Handoff.Offer { Handoff.Offer(agent: agent, from: .chat) }

    /// A terminal tab of `agent` with an exact id, its transcript there, in the session's folder.
    private func terminalFacts(_ agent: Handoff.Agent = .claude, id: String? = nil, source: SessionSnapshot.IDSource? = nil,
                               options: [SessionSnapshot.LaunchOption] = []) -> Handoff.Facts {
        let restore: RestoreAgent = agent == .claude ? .claude : .codex
        let exact: SessionSnapshot.IDSource = agent == .claude ? .sessionFile : .openRollout
        let evidence = SessionSnapshot.Evidence(agent: restore, sessionID: id ?? (agent == .claude ? claudeID : codexID),
                                                source: source ?? exact, sessionFolder: "/Users/x/app", options: options)
        return Handoff.Facts(offer: terminal(agent), evidence: evidence, transcriptExists: true, sourceFolder: "/Users/x/app")
    }

    /// A chat tab of `agent` whose session reported an id and a turn.
    private func chatFacts(_ agent: Handoff.Agent = .claude, id: String? = nil, turns: Int = 1,
                           remembered: SessionSnapshot.Evidence? = nil) -> Handoff.Facts {
        let report = Handoff.ChatReport(sessionID: id ?? (agent == .claude ? claudeID : codexID), turns: turns, state: .idle,
                                        folder: "/Users/x/app")
        return Handoff.Facts(offer: chat(agent), report: report, remembered: remembered, sourceFolder: "/Users/x/app")
    }

    private func planned(_ facts: Handoff.Facts) -> Handoff.Target? {
        if case .success(let target) = Handoff.plan(facts) { return target }
        return nil
    }

    private func refusal(_ facts: Handoff.Facts) -> Handoff.Refusal? {
        if case .failure(let refusal) = Handoff.plan(facts) { return refusal }
        return nil
    }

    // MARK: offer

    @Test func aLocalClaudeOrCodexTerminalOffersChatAndTheirChatTabsOfferTerminal() {
        #expect(Handoff.offer(chatAgentID: nil, program: "claude", kind: .agent, running: true, remote: false, herdr: false)
                == terminal(.claude))
        #expect(Handoff.offer(chatAgentID: nil, program: "codex", kind: .agent, running: true, remote: false, herdr: false)
                == terminal(.codex))
        #expect(Handoff.offer(chatAgentID: "codex", program: CommandClassifier.agentSessionProgram, kind: .agent, running: true,
                              remote: false, herdr: false) == chat(.codex))
        // A chat tab whose agent ended still offers Open in Terminal: its end card does.
        #expect(Handoff.offer(chatAgentID: "claude", program: CommandClassifier.agentSessionProgram, kind: .agent, running: false,
                              remote: false, herdr: false) == chat(.claude))
        #expect(Handoff.offer(chatAgentID: nil, program: "claude", kind: .agent, running: true, remote: false, herdr: false)?.to == .chat)
        #expect(chat(.codex).to == .terminal)
    }

    @Test func everythingElseOffersNothing() {
        // An ACP agent's chat tab, a remote or herdr tab, a stopped agent, another agent, a shell, `nxtrm agent` in a terminal.
        #expect(Handoff.offer(chatAgentID: "gemini", program: CommandClassifier.agentSessionProgram, kind: .agent, running: true,
                              remote: false, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "claude", kind: .agent, running: true, remote: true, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "claude", kind: .agent, running: true, remote: false, herdr: true) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "claude", kind: .agent, running: false, remote: false, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "claude", kind: .command, running: true, remote: false, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "gemini", kind: .agent, running: true, remote: false, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "", kind: .command, running: false, remote: false, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: CommandClassifier.agentSessionProgram, kind: .agent, running: true,
                              remote: false, herdr: false) == nil)
    }

    @Test func aLauncherAliasOffersByItsExpandedLine() {
        #expect(Handoff.offer(chatAgentID: nil, program: "cw", expandedCommand: "claude --model opus --resume x", kind: .agent,
                              running: true, remote: false, herdr: false) == terminal(.claude))
        #expect(Handoff.offer(chatAgentID: nil, program: "cx", expandedCommand: "codex resume x", kind: .agent, running: true,
                              remote: false, herdr: false) == terminal(.codex))
        #expect(Handoff.offer(chatAgentID: nil, program: "gw", expandedCommand: "gemini", kind: .agent, running: true,
                              remote: false, herdr: false) == nil)
        #expect(Handoff.offer(chatAgentID: nil, program: "cw", expandedCommand: "claude", kind: .command, running: true,
                              remote: false, herdr: false) == nil)
    }

    @Test func theMenuItemIsTitledByTheKindItOpens() {
        #expect(terminal(.claude).title == "Continue in Chat")
        #expect(chat(.codex).title == "Open in Terminal")
    }

    // MARK: refusals

    @Test func eachRefusalPlansNothingAndSaysWhy() {
        var working = terminalFacts()
        working.state = .working
        #expect(refusal(working) == .working)
        #expect(Handoff.Refusal.working.text(agent: .claude) == "Claude Code is working. Try again when its turn ends.")

        var asking = terminalFacts()
        asking.state = .attention
        asking.question = "Do you want to make this edit to x?"
        #expect(refusal(asking) == .asking)
        #expect(Handoff.Refusal.asking.text(agent: .codex) == "Codex is asking you something. Answer it first.")

        for source in [SessionSnapshot.IDSource.guess, .shownTitle, .childEnvironment, .unknown] {
            #expect(refusal(terminalFacts(source: source)) == .noExactID)
        }
        // The typed line and argv name the conversation the agent started with, not the one it may have moved to since.
        for agent in Handoff.Agent.allCases {
            for source in [SessionSnapshot.IDSource.typedAndArgv, .runtimeFile] {
                #expect(refusal(terminalFacts(agent, source: source)) == .noExactID, "\(agent) \(source)")
            }
        }
        var noID = terminalFacts()
        noID.evidence = nil
        #expect(refusal(noID) == .noExactID)
        #expect(Handoff.Refusal.noExactID.text(agent: .claude) == "Next Term can\u{2019}t tell which Claude Code conversation this is.")

        var noTranscript = terminalFacts()
        noTranscript.transcriptExists = false
        #expect(refusal(noTranscript) == .noTurnYet)
        #expect(Handoff.Refusal.noTurnYet.text(agent: .claude) == "No conversation to carry over yet: send a prompt first.")

        #expect(refusal(chatFacts(turns: 0)) == .noTurnYet)
        var noReport = chatFacts()
        noReport.report = nil
        #expect(refusal(noReport) == .noExactID)
        var noReportedID = chatFacts()
        noReportedID.report?.sessionID = nil
        #expect(refusal(noReportedID) == .noExactID)

        var plain = terminalFacts()
        plain.integrated = false
        #expect(refusal(plain) == .noIntegration)
        #expect(Handoff.Refusal.noIntegration.text(agent: .claude) == "Continuing needs Next Term\u{2019}s shell integration in this tab.")

        var again = terminalFacts()
        again.handingOff = true
        #expect(refusal(again) == .alreadyHandingOff)
        #expect(Handoff.Refusal.alreadyHandingOff.text(agent: .claude) == "This tab is handing its conversation over already.")

        var elsewhere = terminalFacts()
        elsewhere.liveElsewhere = "api tests"
        #expect(refusal(elsewhere) == .openElsewhere("api tests"))
        #expect(Handoff.Refusal.openElsewhere("api tests").text(agent: .claude) == "This conversation is open in \u{201C}api tests\u{201D}.")

        var none = terminalFacts()
        none.offer = nil
        #expect(refusal(none) == .notOffered)
        #expect(Handoff.Refusal.notOffered.text(agent: nil) == "That tab doesn\u{2019}t run Claude Code or Codex on this Mac.")
    }

    @Test func aChatSourceNeedsNoShellIntegration() {
        var facts = chatFacts()
        facts.integrated = false
        #expect(planned(facts) != nil)
    }

    @Test func aCodexRolloutCountsAsItsConversationWithNoTranscriptCheck() {
        var codex = terminalFacts(.codex)
        codex.transcriptExists = false
        #expect(planned(codex) != nil)
    }

    @Test func aResumedChatCarriesItsConversationBeforeItsFirstTurn() {
        var resumed = chatFacts(turns: 0)
        resumed.report?.resumed = true
        #expect(planned(resumed) != nil)
    }

    @Test func aChatWorkingOrAskingIsRefusedByItsReport() {
        var working = chatFacts()
        working.report?.state = .working
        #expect(refusal(working) == .working)
        var asking = chatFacts()
        asking.report?.state = .attention
        #expect(refusal(asking) == .asking)
    }

    @Test func twoReasonsAtOnceGiveTheEarlierOne() {
        var facts = terminalFacts(source: .guess)
        facts.state = .working
        facts.integrated = false
        facts.liveElsewhere = "other"
        #expect(refusal(facts) == .working)
        facts.state = .attention
        facts.question = "Allow?"
        #expect(refusal(facts) == .asking)
        facts.state = .idle
        facts.question = nil
        #expect(refusal(facts) == .noExactID)
        facts.evidence?.source = .sessionFile
        facts.transcriptExists = false
        #expect(refusal(facts) == .noTurnYet)
        facts.transcriptExists = true
        #expect(refusal(facts) == .noIntegration)
        facts.integrated = true
        #expect(refusal(facts) == .openElsewhere("other"))
        // A handoff already running is said before anything read from the agent it is ending.
        facts.handingOff = true
        facts.state = .working
        #expect(refusal(facts) == .alreadyHandingOff)
    }

    @Test func askingForTheKindATabIsAlreadyIsAnAnswerNotAFailure() {
        var facts = chatFacts()
        facts.wanted = .chat
        #expect(refusal(facts) == .isAlready(.chat))
        #expect(Handoff.Refusal.isAlready(.chat).text(agent: .claude) == "It is a chat tab already.")
        #expect(Handoff.Refusal.isAlready(.terminal).text(agent: .claude) == "It is a terminal tab already.")
        #expect(Handoff.Refusal.isAlready(.chat).isAnswer)
        #expect(!Handoff.Refusal.working.isAnswer)
        facts.wanted = .terminal
        #expect(planned(facts)?.kind == .terminal)
    }

    // MARK: targets

    @Test func claudeToChatQuitsWithItsOwnKeysAndResumesOnly() throws {
        let target = try #require(planned(terminalFacts()))
        #expect(target.kind == .chat)
        #expect(target.agent == .claude)
        #expect(target.sessionID == claudeID)
        #expect(target.folder == "/Users/x/app")
        #expect(target.quit == [.keys("\u{3}"), .pause(150), .keysIfRunning("/exit"), .pause(150), .keysIfRunning("\r")])
        #expect(target.fallback == [.keys("\u{3}"), .pause(300), .keysIfRunning("\u{3}")])
        #expect(target.chat == ChatStart(agentID: "claude", folder: "/Users/x/app", resumeID: claudeID, resumeOnly: true))
        #expect(target.terminalLine == nil)
    }

    @Test func codexToChatQuitsWithQuit() throws {
        let target = try #require(planned(terminalFacts(.codex)))
        #expect(target.quit == [.keys("\u{3}"), .pause(150), .keysIfRunning("/quit"), .pause(150), .keysIfRunning("\r")])
        #expect(target.chat?.agentID == "codex")
        #expect(target.chat?.resumeID == codexID)
    }

    @Test func aChatSourceEndsItsOwnProcessAndOpensATerminalLine() throws {
        let target = try #require(planned(chatFacts()))
        #expect(target.kind == .terminal)
        #expect(target.quit.isEmpty && target.fallback.isEmpty)
        #expect(target.chat == nil)
        #expect(target.terminalLine == "claude --resume " + claudeID)
        let codex = try #require(planned(chatFacts(.codex)))
        #expect(codex.terminalLine == "codex resume " + codexID + " -C /Users/x/app")
    }

    @Test func noTargetEverSendsControlD() throws {
        let targets = [terminalFacts(), terminalFacts(.codex), chatFacts(), chatFacts(.codex)].compactMap(planned)
        #expect(targets.count == 4)
        for target in targets {
            for step in target.quit + target.fallback {
                switch step {
                case .keys(let keys), .keysIfRunning(let keys): #expect(!keys.contains("\u{4}"))
                case .pause: break
                }
            }
            #expect(target.terminalLine?.contains("\u{4}") != true)
        }
    }

    // MARK: lines

    @Test func aRoundTripPutsBackTheUsersOwnLaunch() throws {
        let remembered = SessionSnapshot.Evidence(agent: .claude, sessionID: claudeID, source: .sessionFile, options: [],
                                                  launcher: SessionSnapshot.Launcher(word: "cw", typed: 0))
        #expect(try #require(planned(chatFacts(remembered: remembered))).terminalLine == "cw --resume " + claudeID)
        let model = SessionSnapshot.Evidence(agent: .claude, sessionID: claudeID, source: .sessionFile,
                                             options: [SessionSnapshot.LaunchOption(["--model", "opus"])])
        #expect(try #require(planned(chatFacts(remembered: model))).terminalLine == "claude --model opus --resume " + claudeID)
        // Remembered for another conversation: the plain resume line.
        let other = SessionSnapshot.Evidence(agent: .claude, sessionID: "11111111-2222-4333-8444-555555555555", source: .sessionFile,
                                             options: [], launcher: SessionSnapshot.Launcher(word: "cw", typed: 0))
        #expect(try #require(planned(chatFacts(remembered: other))).terminalLine == "claude --resume " + claudeID)
    }

    @Test func theNewTabOpensInTheConversationsFolder() throws {
        var toTerminal = chatFacts()
        toTerminal.report?.folder = "/x y"
        let target = try #require(planned(toTerminal))
        #expect(target.folder == "/x y")
        #expect(target.terminalLine == "claude --resume " + claudeID)
        // Opened anywhere else, the line goes to the conversation's folder first: both agents find it by its folder.
        #expect(target.terminalLine(openedIn: "/Users/x/app") == "cd -- '/x y' && claude --resume " + claudeID)
        #expect(target.terminalLine(openedIn: "/x y/") == "claude --resume " + claudeID)
        // A conversation with no folder known opens in the source tab's.
        var noFolder = chatFacts()
        noFolder.report?.folder = nil
        #expect(try #require(planned(noFolder)).folder == "/Users/x/app")
        var toChat = terminalFacts()
        toChat.evidence?.sessionFolder = nil
        #expect(try #require(planned(toChat)).chat?.folder == "/Users/x/app")
    }

    @Test func anIdThatIsNotOneWordIsNeverPlanned() {
        for id in ["8f3a1c2e' && rm -rf ~", "8f3a1c2e 1b2c", "8f3a1c2e\n1b2c", "not-a-uuid"] {
            #expect(refusal(terminalFacts(id: id)) == .noExactID)
            #expect(refusal(chatFacts(id: id)) == .noExactID)
        }
    }

    // MARK: notes

    @Test func theNoteNamesTheConversationAndWhatTheChatDrops() throws {
        let plain = try #require(planned(terminalFacts()))
        #expect(plain.note == "Continued in Chat: Claude Code conversation 8f3a1c2e")
        let options = [SessionSnapshot.LaunchOption(["--model", "opus"]), SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
        let dropped = try #require(planned(terminalFacts(options: options)))
        #expect(dropped.note == "Continued in Chat: Claude Code conversation 8f3a1c2e. Not carried: --model, --dangerously-skip-permissions")
        #expect(!dropped.note.contains("opus"))
        let back = try #require(planned(chatFacts(.codex)))
        #expect(back.note == "Continued in Terminal: Codex conversation 019a2b3c")
    }

    @Test func claudeTranscriptIsUnderItsProjectFolder() {
        #expect(Handoff.claudeTranscript(store: "/Users/x/.claude", folder: "/Users/x/my app", sessionID: claudeID)
                == "/Users/x/.claude/projects/-Users-x-my-app/" + claudeID + ".jsonl")
    }

    // MARK: an ended chat

    /// A chat tab whose agent has ended (its end card offers Open in Terminal).
    private func endedFacts(_ agent: Handoff.Agent = .claude, id: String? = nil, turns: Int = 0,
                            resumeFailed: Bool = false) -> Handoff.Facts {
        let report = Handoff.ChatReport(sessionID: id, turns: turns, state: .working, folder: "/Users/x/app",
                                        resumeFailed: resumeFailed)
        return Handoff.Facts(offer: chat(agent), report: report, sourceFolder: "/Users/x/app", chatEnded: true)
    }

    @Test func anEndedChatWithoutAConversationStartsTheAgentPlain() throws {
        let target = try #require(planned(endedFacts()))
        #expect(target.kind == .terminal)
        #expect(target.terminalLine == "claude")
        #expect(target.sessionID.isEmpty)
        #expect(target.note == "Continued in Terminal: Claude Code")
        #expect(try #require(planned(endedFacts(.codex, id: codexID))).terminalLine == "codex")
    }

    @Test func anEndedChatCarriesItsConversationAndAFailedResumeItsOwnID() throws {
        #expect(try #require(planned(endedFacts(id: claudeID, turns: 2))).terminalLine == "claude --resume " + claudeID)
        #expect(try #require(planned(endedFacts(id: claudeID, resumeFailed: true))).terminalLine == "claude --resume " + claudeID)
        // Its last reported state is no reason to refuse: nothing runs.
        #expect(planned(endedFacts(id: claudeID, turns: 2)) != nil)
        // An id that isn't one word is never put in a line.
        #expect(try #require(planned(endedFacts(id: "x; rm -rf /", resumeFailed: true))).terminalLine == "claude")
    }

    // MARK: words

    @Test func theConfirmationNamesWhatEnds() {
        let toChat = Handoff.confirmation(for: terminal(.claude))
        #expect(toChat.title == "Continue this conversation in Chat?")
        #expect(toChat.detail == "Claude Code quits in this tab.")
        #expect(toChat.button == "Continue")
        #expect(toChat.suppression == "Don\u{2019}t ask again")
        let toTerminal = Handoff.confirmation(for: chat(.codex))
        #expect(toTerminal.title == "Open this conversation in Terminal?")
        #expect(toTerminal.detail == "This chat ends, and Codex goes on in a terminal tab beside it.")
    }

    @Test func theConfirmationIsAskedUntilTheUserSaysNotTo() throws {
        let (defaults, name) = try TestDefaults.make("handoff-confirm")
        defer { TestDefaults.remove(defaults, name) }
        #expect(Handoff.asksFirst(defaults: defaults))
        Handoff.setAsksFirst(false, defaults: defaults)
        #expect(defaults.bool(forKey: "handoff.skipConfirm"))
        #expect(!Handoff.asksFirst(defaults: defaults))
    }

    @Test func aTerminalOnlyCommandPointsAtTheTerminal() {
        #expect(Handoff.terminalOnlyLine("/login", shortcut: "\u{21E7}\u{2318}J") == "/login works in the terminal: Open in Terminal (\u{21E7}\u{2318}J)")
        #expect(Handoff.terminalOnlyLine("/mcp", shortcut: nil) == "/mcp works in the terminal: Open in Terminal")
    }
}
