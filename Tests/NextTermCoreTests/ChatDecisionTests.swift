import Foundation
import Testing
@testable import NextTermCore

/// The chat tab's card, header and input box as values (plan 037 U1): what each shows and allows, built from the
/// session and the host's facts, with no AppKit.
@Suite struct ChatDecisionTests {
    private func json(_ text: String) -> ACPWire.Value {
        let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        return parsed.flatMap { ACPWire.Value(serialized: $0) } ?? .null
    }

    private let threeOptions = #"[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"allow_always","name":"Allow always","kind":"allow_always"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]"#

    private func asking(question: Bool = false, options: String? = nil, title: String = "Bash(rm -rf build)") -> ACPSession {
        var session = ACPSession()
        session.prompted("clean")
        let params = json(#"{"toolCall":{"toolCallId":"b1","title":"\#(title)"},"options":"# + (options ?? threeOptions) + "}")
        session.requested(permission: .number(1), params: params, question: question)
        return session
    }

    // MARK: the card

    @Test func aPermissionGivesItsActionWholeAndOneChoicePerOption() throws {
        let session = asking()
        let permission = try #require(session.pending)
        let decision = ChatDecision.from(permission, agent: "Claude Code")
        #expect(decision.title == "Bash(rm -rf build)")
        #expect(decision.lead == "Claude Code asks to:")
        #expect(decision.choices.map(\.name) == ["Allow once", "Allow always", "Reject"])
        #expect(decision.choices.map(\.needsMac) == [false, true, false])
        #expect(decision.choices.map(\.number) == [1, 2, 3])
        #expect(decision.highlighted == 0)
        #expect(decision.rejectIndex == 2)
        #expect(decision.defaultIndex == 0)
        #expect(!decision.isQuestion)
        #expect(decision.question == ACPTranscript.question(permission))
    }

    @Test func aQuestionHasNoLeadAndItsAnswersAsChoices() throws {
        let options = #"[{"optionId":"Postgres","name":"Postgres","kind":"allow_once"},{"optionId":"SQLite","name":"SQLite","kind":"allow_once"}]"#
        let session = asking(question: true, options: options, title: "Which database")
        let decision = ChatDecision.from(try #require(session.pending), agent: "Claude Code")
        #expect(decision.lead == nil)
        #expect(decision.isQuestion)
        #expect(decision.title == "Which database")
        #expect(decision.rejectIndex == nil)
        #expect(decision.choices.allSatisfy { !$0.needsMac })
    }

    @Test func theMenuIsAListWithTheSameNamesAndHighlight() throws {
        var session = asking()
        session.moveHighlight(1)
        let decision = ChatDecision.from(try #require(session.pending), agent: "Codex")
        #expect(decision.highlighted == 1)
        let menu = decision.menu(question: "Do you want to allow: Bash(rm -rf build)?")
        #expect(menu.style == .list)
        #expect(menu.choices == ["Allow once", "Allow always", "Reject"])
        #expect(menu.highlighted == 1)
        #expect(menu.question == "Do you want to allow: Bash(rm -rf build)?")
        #expect(menu.escape == 2)
    }

    @Test func aLongActionStaysWhole() throws {
        let long = "Bash(" + String(repeating: "y", count: 500) + ")"
        let decision = ChatDecision.from(try #require(asking(title: long).pending), agent: "Claude Code")
        #expect(decision.title == long)
    }

    // MARK: the header

    @Test func theHeaderAbbreviatesTheFolderAndSkipsWhatIsMissing() {
        let full = ChatHeader.make(agent: "Claude Code", model: "stand-in-model", version: "9.9.9", folder: "/Users/me/proj",
                                   home: "/Users/me", usage: "Context 1.2k of 200k", state: .ready)
        #expect(full.line == "Claude Code \u{00B7} stand-in-model \u{00B7} 9.9.9 \u{00B7} ~/proj")
        #expect(full.folder == "~/proj")
        #expect(full.usage == "Context 1.2k of 200k")
        let bare = ChatHeader.make(agent: "Codex", model: nil, version: "", folder: "/srv/app", home: "/Users/me", usage: nil, state: .starting)
        #expect(bare.line == "Codex \u{00B7} /srv/app")
        #expect(!bare.line.contains("\u{00B7} \u{00B7}"))
        let none = ChatHeader.make(agent: "Codex", model: " ", version: nil, folder: nil, home: "/Users/me", usage: nil, state: .idle)
        #expect(none.line == "Codex")
    }

    @Test func theHeaderSaysTheStateAndOffersStopOnlyInATurn() {
        let words = ChatHostState.allCases.map { ChatHeader.make(agent: "Codex", model: nil, version: nil, folder: nil, home: "/h",
                                                                 usage: nil, state: $0).stateWords }
        #expect(Set(words).count == ChatHostState.allCases.count)
        #expect(ChatHostState.allCases.filter(\.showsStop) == [.working, .asking])
    }

    // MARK: the input box

    @Test func idleTheBoxSends() {
        var session = ACPSession()
        session.prompted("x")
        session.turnEnded("end_turn")
        let state = ChatInputState.make(session: session, waitingLine: nil, ended: false, agentName: "Claude Code")
        #expect(state.canSend)
        #expect(state.placeholder == "Message Claude Code")
        #expect(!state.showsStop)
    }

    @Test func workingTheBoxSaysHowToStop() {
        var session = ACPSession()
        session.prompted("x")
        let state = ChatInputState.make(session: session, waitingLine: nil, ended: false, agentName: "Claude Code")
        #expect(!state.canSend)
        #expect(state.placeholder == "Claude Code is working. \u{2318}. stops it.")
        #expect(state.showsStop)
    }

    @Test func aCardOpenTheBoxDoesNotSend() {
        let state = ChatInputState.make(session: asking(), waitingLine: nil, ended: false, agentName: "Codex")
        #expect(!state.canSend)
        #expect(state.placeholder == "Codex is asking you something. Answer it above.")
        #expect(state.showsStop)
    }

    @Test func aWaitingLineWinsOverEverythingAndAnEndedSessionSendsNothing() {
        let waiting = ChatInputState.make(session: asking(), waitingLine: "Waiting for your OK on the Mac to trust this folder\u{2026}",
                                          ended: true, agentName: "Claude Code")
        #expect(!waiting.canSend)
        #expect(waiting.placeholder == "Waiting for your OK on the Mac to trust this folder\u{2026}")
        let ended = ChatInputState.make(session: ACPSession(), waitingLine: nil, ended: true, agentName: "Claude Code")
        #expect(!ended.canSend)
        #expect(ended.placeholder == "This session ended.")
        #expect(!ended.showsStop)
    }

    @Test func slashListsTheAgentsCommandsAsTyped() {
        let commands = ["init", "/compact", "review", "Init-Repo"]
        #expect(ChatInputState.slashMatches("/", commands: commands) == ["/init", "/compact", "/review", "/Init-Repo"])
        #expect(ChatInputState.slashMatches("/in", commands: commands) == ["/init", "/Init-Repo"])
        #expect(ChatInputState.slashMatches("/compact now", commands: commands).isEmpty)
        #expect(ChatInputState.slashMatches("hello", commands: commands).isEmpty)
        #expect(ChatInputState.slashMatches("", commands: commands).isEmpty)
        #expect(ChatInputState.slashMatches("/", commands: ["", "/"]).isEmpty)
    }

    // MARK: text sizes

    @Test func theTextFollowsTheEditorsSize() {
        let standard = ChatTextSizes(base: 13)
        #expect(standard.body == 13)
        #expect(standard.secondary == 11)
        #expect(standard.monospaced == 12)
        #expect(standard.heading == 15)
        let bigger = ChatTextSizes(base: 20)
        #expect(bigger.body == 20)
        #expect(bigger.secondary > standard.secondary && bigger.secondary < bigger.body)
        #expect(bigger.heading > bigger.body)
        // Out-of-range sizes are kept to the editor's own range; secondary text goes below 9 points only with the body.
        #expect(ChatTextSizes(base: 2).body == 8)
        #expect(ChatTextSizes(base: 2).secondary == 8)
        #expect(ChatTextSizes(base: 10).secondary == 9)
        #expect(ChatTextSizes(base: 400).body == 32)
        #expect(ChatTextSizes(base: .nan).body == 13)
    }
}
