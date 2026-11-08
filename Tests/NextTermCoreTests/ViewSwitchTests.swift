import Foundation
import Testing
@testable import NextTermCore

/// The terminal and chat switch (plan 036 U1): which tabs offer it, the icon each shows, the refusals in their order,
/// and the keys and the line a switch sends, which must name only the conversation the tab holds.
@Suite struct ViewSwitchTests {
    private let claudeID = "8f3a1c2e-1b2c-4d5e-8f90-0a1b2c3d4e5f"
    private let codexID = "019a2b3c-4d5e-7f60-8a1b-2c3d4e5f6a7b"
    private let launcher = "'/Applications/Next Term.app/Contents/Resources/bin/nxtrm'"

    private func terminal(_ agent: ViewSwitch.Agent) -> ViewSwitch.Offer { ViewSwitch.Offer(agent: agent, view: .terminal) }
    private func chat(_ agent: ViewSwitch.Agent) -> ViewSwitch.Offer { ViewSwitch.Offer(agent: agent, view: .chat) }

    /// A terminal-view tab of `agent` with an exact id, its transcript there and the shell in the session's folder.
    private func terminalFacts(_ agent: ViewSwitch.Agent = .claude, id: String? = nil, source: SessionSnapshot.IDSource? = nil,
                               options: [SessionSnapshot.LaunchOption] = []) -> ViewSwitch.Facts {
        let restore: RestoreAgent = agent == .claude ? .claude : .codex
        let exact: SessionSnapshot.IDSource = agent == .claude ? .sessionFile : .openRollout
        let evidence = SessionSnapshot.Evidence(agent: restore, sessionID: id ?? (agent == .claude ? claudeID : codexID),
                                                source: source ?? exact, sessionFolder: "/Users/x/app", options: options)
        return ViewSwitch.Facts(offer: terminal(agent), launcher: launcher, evidence: evidence, transcriptExists: true,
                                shellFolder: "/Users/x/app")
    }

    /// A chat-view tab of `agent` whose session reported an id and a turn, in the shell's folder.
    private func chatFacts(_ agent: ViewSwitch.Agent = .claude, id: String? = nil, turns: Int = 1,
                           remembered: SessionSnapshot.Evidence? = nil) -> ViewSwitch.Facts {
        let report = ViewSwitch.ChatReport(sessionID: id ?? (agent == .claude ? claudeID : codexID), turns: turns, state: .idle,
                                           folder: "/Users/x/app")
        return ViewSwitch.Facts(offer: chat(agent), launcher: launcher, report: report, remembered: remembered, shellFolder: "/Users/x/app")
    }

    private func planned(_ facts: ViewSwitch.Facts) -> ViewSwitch.Plan? {
        if case .success(let plan) = ViewSwitch.plan(facts) { return plan }
        return nil
    }

    private func refusal(_ facts: ViewSwitch.Facts) -> ViewSwitch.Refusal? {
        if case .failure(let refusal) = ViewSwitch.plan(facts) { return refusal }
        return nil
    }

    // MARK: offer

    @Test func onlyALocalClaudeOrCodexInFrontOffersTheSwitch() {
        let session = CommandClassifier.agentSessionProgram
        #expect(ViewSwitch.offer(program: "claude", kind: .agent, running: true, sessionAgentID: nil, remote: false, herdr: false)
                == terminal(.claude))
        #expect(ViewSwitch.offer(program: "codex", kind: .agent, running: true, sessionAgentID: nil, remote: false, herdr: false)
                == terminal(.codex))
        #expect(ViewSwitch.offer(program: session, kind: .agent, running: true, sessionAgentID: "codex", remote: false, herdr: false)
                == chat(.codex))
        #expect(ViewSwitch.offer(program: session, kind: .agent, running: true, sessionAgentID: "claude", remote: false, herdr: false)
                == chat(.claude))
        // Another agent's session, a session that hasn't reported, a remote or herdr tab, a stopped agent, a shell: none.
        #expect(ViewSwitch.offer(program: session, kind: .agent, running: true, sessionAgentID: "gemini", remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: session, kind: .agent, running: true, sessionAgentID: nil, remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "claude", kind: .agent, running: true, sessionAgentID: nil, remote: true, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "claude", kind: .agent, running: true, sessionAgentID: nil, remote: false, herdr: true) == nil)
        #expect(ViewSwitch.offer(program: "claude", kind: .agent, running: false, sessionAgentID: nil, remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "claude", kind: .command, running: true, sessionAgentID: nil, remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "gemini", kind: .agent, running: true, sessionAgentID: nil, remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "", kind: .command, running: false, sessionAgentID: nil, remote: false, herdr: false) == nil)
    }

    @Test func aLauncherAliasOffersTheSwitchByItsExpandedLine() {
        // `cw` is an alias for `claude --model opus`: zsh's preexec gives the expanded line, which names the agent.
        #expect(ViewSwitch.offer(program: "cw", expandedCommand: "claude --model opus --resume x", kind: .agent, running: true,
                                 sessionAgentID: nil, remote: false, herdr: false) == terminal(.claude))
        #expect(ViewSwitch.offer(program: "cx", expandedCommand: "codex resume x", kind: .agent, running: true,
                                 sessionAgentID: nil, remote: false, herdr: false) == terminal(.codex))
        // An alias for another agent, or a command that isn't an agent, still offers none.
        #expect(ViewSwitch.offer(program: "gw", expandedCommand: "gemini", kind: .agent, running: true,
                                 sessionAgentID: nil, remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "cw", expandedCommand: "claude", kind: .command, running: true,
                                 sessionAgentID: nil, remote: false, herdr: false) == nil)
        #expect(ViewSwitch.offer(program: "cw", expandedCommand: "claude", kind: .agent, running: true,
                                 sessionAgentID: nil, remote: true, herdr: false) == nil)
    }

    // MARK: mark

    @Test func aTerminalViewShowsTheBubbleOnlyUnderThePointerOrSelected() {
        #expect(ViewSwitch.mark(offer: terminal(.claude), hovering: false, selected: false) == nil)
        for (hovering, selected) in [(true, false), (false, true), (true, true)] {
            let mark = ViewSwitch.mark(offer: terminal(.claude), hovering: hovering, selected: selected)
            #expect(mark == ViewSwitch.Mark(glyph: .chat, dimmed: false, enabled: true, tooltip: "Switch to Chat", spoken: "Switch to Chat"))
        }
        #expect(ViewSwitch.mark(offer: nil, hovering: true, selected: true) == nil)
    }

    @Test func aChatViewShowsADimBubbleAtRestAndTheTerminalUnderThePointer() {
        let rest = ViewSwitch.mark(offer: chat(.codex), hovering: false, selected: false)
        #expect(rest == ViewSwitch.Mark(glyph: .chat, dimmed: true, enabled: true, tooltip: "Switch to Terminal",
                                        spoken: "Chat view, Switch to Terminal"))
        let hovered = ViewSwitch.mark(offer: chat(.codex), hovering: true, selected: false)
        #expect(hovered == ViewSwitch.Mark(glyph: .terminal, dimmed: false, enabled: true, tooltip: "Switch to Terminal",
                                           spoken: "Switch to Terminal"))
        #expect(ViewSwitch.mark(offer: chat(.codex), hovering: false, selected: true)?.glyph == .terminal)
    }

    @Test func whileSwitchingTheDestinationShowsDimmedAndOff() {
        for (hovering, selected) in [(false, false), (true, false), (false, true)] {
            let toChat = ViewSwitch.mark(offer: ViewSwitch.Offer(agent: .claude, view: .terminal, switching: true),
                                         hovering: hovering, selected: selected)
            #expect(toChat?.glyph == .chat)
            #expect(toChat?.dimmed == true)
            #expect(toChat?.enabled == false)
            let toTerminal = ViewSwitch.mark(offer: ViewSwitch.Offer(agent: .claude, view: .chat, switching: true),
                                             hovering: hovering, selected: selected)
            #expect(toTerminal?.glyph == .terminal)
            #expect(toTerminal?.dimmed == true)
            #expect(toTerminal?.enabled == false)
        }
    }

    // MARK: refusals

    @Test func eachRefusalPlansNothingAndSaysWhy() {
        var working = terminalFacts()
        working.state = .working
        #expect(refusal(working) == .working)
        #expect(ViewSwitch.Refusal.working.text(agent: .claude) == "Claude Code is working. Switch when its turn ends.")

        var asking = terminalFacts()
        asking.state = .attention
        asking.question = "Do you want to make this edit to x?"
        #expect(refusal(asking) == .asking)
        #expect(ViewSwitch.Refusal.asking.text(agent: .codex) == "Codex is asking you something. Answer it first.")

        for source in [SessionSnapshot.IDSource.guess, .shownTitle, .childEnvironment, .unknown] {
            #expect(refusal(terminalFacts(source: source)) == .noExactID)
        }
        var noID = terminalFacts()
        noID.evidence = nil
        #expect(refusal(noID) == .noExactID)
        #expect(ViewSwitch.Refusal.noExactID.text(agent: .claude) == "Next Term can\u{2019}t tell which Claude Code conversation this is.")

        var noTranscript = terminalFacts()
        noTranscript.transcriptExists = false
        #expect(refusal(noTranscript) == .noTurnYet)
        #expect(ViewSwitch.Refusal.noTurnYet.text(agent: .claude) == "No conversation to carry over yet: send a prompt first.")

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
        #expect(ViewSwitch.Refusal.noIntegration.text(agent: .claude) == "Switching needs Next Term\u{2019}s shell integration in this tab.")

        var again = terminalFacts()
        again.switching = true
        #expect(refusal(again) == .alreadySwitching)
        #expect(ViewSwitch.Refusal.alreadySwitching.text(agent: .claude) == "This tab is switching views already.")

        var none = terminalFacts()
        none.offer = nil
        #expect(refusal(none) == .notOffered)
        #expect(ViewSwitch.Refusal.notOffered.text(agent: nil) == "That tab doesn\u{2019}t run Claude Code or Codex on this Mac.")
    }

    @Test func aCodexRolloutCountsAsItsConversationWithNoTranscriptCheck() {
        var codex = terminalFacts(.codex)
        codex.transcriptExists = false
        #expect(planned(codex) != nil)
    }

    @Test func aResumedSessionCarriesItsConversationBeforeItsFirstTurn() {
        var resumed = chatFacts(turns: 0)
        resumed.report?.resumed = true
        #expect(planned(resumed) != nil)
    }

    @Test func aSessionWorkingOrAskingIsRefusedByItsReport() {
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
        // A switch already running is said before anything read from the agent it is quitting.
        facts.switching = true
        facts.state = .working
        #expect(refusal(facts) == .alreadySwitching)
    }

    @Test func askingForTheViewATabShowsIsAnAnswerNotAFailure() {
        var facts = chatFacts()
        facts.wanted = .chat
        #expect(refusal(facts) == .showsAlready(.chat))
        #expect(ViewSwitch.Refusal.showsAlready(.chat).text(agent: .claude) == "It shows chat already.")
        #expect(ViewSwitch.Refusal.showsAlready(.chat).isAnswer)
        #expect(!ViewSwitch.Refusal.working.isAnswer)
        facts.wanted = .terminal
        #expect(planned(facts)?.to == .terminal)
    }

    // MARK: plans

    @Test func claudeToChatQuitsWithItsOwnKeysAndResumesOnly() throws {
        let plan = try #require(planned(terminalFacts()))
        #expect(plan.from == .terminal)
        #expect(plan.to == .chat)
        #expect(plan.agent == .claude)
        #expect(plan.sessionID == claudeID)
        #expect(plan.quit == [.keys("\u{3}"), .pause(150), .keys("/exit"), .pause(150), .keys("\r")])
        #expect(plan.fallback == [.keys("\u{3}"), .pause(300), .keysIfRunning("\u{3}")])
        #expect(plan.line == launcher + " agent claude --resume " + claudeID + " --resume-only")
    }

    @Test func codexQuitsWithQuitAndResumesOnly() throws {
        let plan = try #require(planned(terminalFacts(.codex)))
        #expect(plan.quit == [.keys("\u{3}"), .pause(150), .keys("/quit"), .pause(150), .keys("\r")])
        #expect(plan.line == launcher + " agent codex --resume " + codexID + " --resume-only")
        let back = try #require(planned(chatFacts(.codex)))
        #expect(back.line == "codex resume " + codexID + " -C /Users/x/app")
    }

    @Test func chatToTerminalEndsTheSessionWithControlC() throws {
        let plan = try #require(planned(chatFacts()))
        #expect(plan.from == .chat)
        #expect(plan.to == .terminal)
        #expect(plan.quit == [.keys("\u{3}"), .pause(300), .keysIfRunning("\u{3}")])
        #expect(plan.fallback == [.keys("\u{3}"), .pause(300), .keysIfRunning("\u{3}")])
    }

    @Test func noPlanEverSendsControlD() throws {
        let plans: [ViewSwitch.Plan] = [terminalFacts(), terminalFacts(.codex), chatFacts(), chatFacts(.codex)].compactMap(planned)
        #expect(plans.count == 4)
        for plan in plans {
            for step in plan.quit + plan.fallback {
                switch step {
                case .keys(let keys), .keysIfRunning(let keys): #expect(!keys.contains("\u{4}"))
                case .pause: break
                }
            }
            #expect(!plan.line.contains("\u{4}"))
        }
    }

    // MARK: lines

    @Test func aRoundTripPutsBackTheUsersOwnLaunch() throws {
        let remembered = SessionSnapshot.Evidence(agent: .claude, sessionID: claudeID, source: .sessionFile, options: [],
                                                  launcher: SessionSnapshot.Launcher(word: "cw", typed: 0))
        #expect(try #require(planned(chatFacts(remembered: remembered))).line == "cw --resume " + claudeID)
        // Its options come back with it, as the separator said they would.
        let model = SessionSnapshot.Evidence(agent: .claude, sessionID: claudeID, source: .sessionFile,
                                             options: [SessionSnapshot.LaunchOption(["--model", "opus"])])
        #expect(try #require(planned(chatFacts(remembered: model))).line == "claude --model opus --resume " + claudeID)
        // Remembered for another conversation or agent: the plain resume line.
        let other = SessionSnapshot.Evidence(agent: .claude, sessionID: "11111111-2222-4333-8444-555555555555", source: .sessionFile,
                                             options: [], launcher: SessionSnapshot.Launcher(word: "cw", typed: 0))
        #expect(try #require(planned(chatFacts(remembered: other))).line == "claude --resume " + claudeID)
        #expect(try #require(planned(chatFacts())).line == "claude --resume " + claudeID)
    }

    @Test func aSessionInAnotherFolderGoesThereFirst() throws {
        var toChat = terminalFacts()
        toChat.evidence?.sessionFolder = "/x y"
        #expect(try #require(planned(toChat)).line == "cd -- '/x y' && " + launcher + " agent claude --resume " + claudeID + " --resume-only")
        var toTerminal = chatFacts()
        toTerminal.report?.folder = "/x y"
        #expect(try #require(planned(toTerminal)).line == "cd -- '/x y' && claude --resume " + claudeID)
        // The same folder, written with a trailing slash, needs no cd.
        var same = chatFacts()
        same.shellFolder = "/Users/x/app/"
        #expect(try #require(planned(same)).line == "claude --resume " + claudeID)
    }

    @Test func anIdThatIsNotOneWordIsNeverPlanned() {
        for id in ["8f3a1c2e' && rm -rf ~", "8f3a1c2e 1b2c", "8f3a1c2e\n1b2c", "not-a-uuid"] {
            #expect(refusal(terminalFacts(id: id)) == .noExactID)
            #expect(refusal(chatFacts(id: id)) == .noExactID)
        }
    }

    // MARK: separator

    @Test func theSeparatorNamesTheConversationAndWhatTheChatDrops() throws {
        let plain = try #require(planned(terminalFacts()))
        #expect(plain.separator == "Switched to Chat: Claude Code conversation 8f3a1c2e")
        let options = [SessionSnapshot.LaunchOption(["--model", "opus"]), SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
        let dropped = try #require(planned(terminalFacts(options: options)))
        #expect(dropped.separator == "Switched to Chat: Claude Code conversation 8f3a1c2e. Not carried: --model, --dangerously-skip-permissions")
        #expect(!dropped.separator.contains("opus"))
        let back = try #require(planned(chatFacts(.codex)))
        #expect(back.separator == "Switched to Terminal: Codex conversation 019a2b3c")
    }

    @Test func claudeTranscriptIsUnderItsProjectFolder() {
        #expect(ViewSwitch.claudeTranscript(store: "/Users/x/.claude", folder: "/Users/x/my app", sessionID: claudeID)
                == "/Users/x/.claude/projects/-Users-x-my-app/" + claudeID + ".jsonl")
    }

    // MARK: the chat view's offers (U5)

    /// A chat-view tab whose session offered the terminal view: ended (nothing to quit) or still running.
    private func offerFacts(_ offer: ViewSwitch.TerminalOffer, _ agent: ViewSwitch.Agent = .claude, id: String? = nil, turns: Int = 0,
                            running: Bool = false) -> ViewSwitch.Facts {
        var facts = ViewSwitch.Facts(offer: chat(agent), launcher: launcher, shellFolder: "/Users/x/app", terminalOffer: offer,
                                     sessionRunning: running)
        facts.report = ViewSwitch.ChatReport(sessionID: id, turns: turns, state: .idle, folder: "/Users/x/app")
        return facts
    }

    @Test func anOfferReadsOnlyItsFourKnownValues() {
        #expect(ViewSwitch.TerminalOffer(raw: "sign_in") == .signIn)
        #expect(ViewSwitch.TerminalOffer(raw: "trust_declined") == .trustDeclined)
        #expect(ViewSwitch.TerminalOffer(raw: "resume_failed") == .resumeFailed)
        #expect(ViewSwitch.TerminalOffer(raw: "command:/login") == .command("/login"))
        #expect(ViewSwitch.TerminalOffer(raw: "command:/status") == .command("/status"))
        for raw in ["", "command:", "command:/model", "command:rm -rf", "sign-in", "SIGN_IN"] {
            #expect(ViewSwitch.TerminalOffer(raw: raw) == nil, "\(raw)")
        }
        for offer in [ViewSwitch.TerminalOffer.signIn, .trustDeclined, .resumeFailed, .command("/mcp")] {
            #expect(ViewSwitch.TerminalOffer(raw: offer.raw) == offer)
        }
        #expect(ViewSwitch.TerminalOffer.signIn.text(agent: .claude) == "Claude Code needs you to sign in, in the terminal view.")
        #expect(ViewSwitch.TerminalOffer.trustDeclined.text(agent: .claude) == "Claude Code\u{2019}s own trust question is in the terminal view.")
        #expect(ViewSwitch.TerminalOffer.resumeFailed.text(agent: .codex) == "This conversation couldn\u{2019}t go on in Chat. Open it in Terminal.")
        #expect(ViewSwitch.TerminalOffer.command("/login").text(agent: .codex) == "/login works in the terminal view.")
        #expect(ViewSwitch.terminalOnlyLine("/login", agent: .claude, hasConversation: true)
                == "/login works in the terminal view: Open in Terminal (\u{21E7}\u{2318}J) carries this conversation there.")
        #expect(ViewSwitch.terminalOnlyLine("/mcp", agent: .codex, hasConversation: false).hasSuffix("starts Codex there."))
    }

    @Test func anEndedSessionWithoutAConversationStartsTheAgentPlain() throws {
        let plan = try #require(planned(offerFacts(.signIn)))
        #expect(plan.from == .chat && plan.to == .terminal)
        #expect(plan.line == "claude")
        #expect(plan.quit.isEmpty && plan.fallback.isEmpty)
        #expect(plan.sessionID.isEmpty)
        #expect(plan.separator == "Switched to Terminal: Claude Code")
        #expect(try #require(planned(offerFacts(.trustDeclined, .codex))).line == "codex")
        // An id with no turn and no resume is no conversation yet: plain too.
        #expect(try #require(planned(offerFacts(.signIn, id: claudeID))).line == "claude")
    }

    @Test func aRunningSessionWithACommandOfferQuitsAndResumes() throws {
        let plan = try #require(planned(offerFacts(.command("/login"), id: claudeID, turns: 1, running: true)))
        #expect(plan.line == "claude --resume " + claudeID)
        #expect(plan.quit == ViewSwitch.fallback)
        #expect(plan.sessionID == claudeID)
        #expect(plan.separator == "Switched to Terminal: Claude Code conversation 8f3a1c2e")
        // Before its first turn, the agent starts plain, the session quit all the same.
        let fresh = try #require(planned(offerFacts(.command("/mcp"), .codex, id: codexID, turns: 0, running: true)))
        #expect(fresh.line == "codex")
        #expect(fresh.quit == ViewSwitch.fallback)
    }

    @Test func aResumeThatFailedOffersItsOwnConversation() throws {
        let plan = try #require(planned(offerFacts(.resumeFailed, id: claudeID)))
        #expect(plan.line == "claude --resume " + claudeID)
        #expect(plan.quit.isEmpty)
        #expect(try #require(planned(offerFacts(.resumeFailed, .codex, id: codexID))).line == "codex resume " + codexID + " -C /Users/x/app")
        // An id that isn't one word is never typed.
        #expect(try #require(planned(offerFacts(.resumeFailed, id: "x; rm -rf /"))).line == "claude")
    }

    @Test func anOfferGoesToTheSessionsFolderAndIsRefusedLikeAnySwitch() throws {
        var elsewhere = offerFacts(.resumeFailed, id: claudeID)
        elsewhere.shellFolder = "/tmp"
        #expect(try #require(planned(elsewhere)).line == "cd -- /Users/x/app && claude --resume " + claudeID)
        var working = offerFacts(.command("/login"), id: claudeID, turns: 1, running: true)
        working.state = .working
        #expect(refusal(working) == .working)
        var asking = offerFacts(.command("/login"), id: claudeID, turns: 1, running: true)
        asking.report?.state = .attention
        #expect(refusal(asking) == .asking)
        var noShell = offerFacts(.signIn)
        noShell.integrated = false
        #expect(refusal(noShell) == .noIntegration)
        var twice = offerFacts(.signIn)
        twice.switching = true
        #expect(refusal(twice) == .alreadySwitching)
        var asked = offerFacts(.signIn)
        asked.wanted = .chat
        #expect(refusal(asked) == .showsAlready(.chat))
        // An ended session's last state is no reason: nothing is working.
        var ended = offerFacts(.signIn)
        ended.report?.state = .working
        #expect(planned(ended) != nil)
    }
}
