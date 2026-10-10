import Foundation
import Testing
@testable import NextTermCore

@Suite struct SearchWordsTests {
    func session(_ title: String, agent: AgentKind = .claude, branch: String? = nil, model: String? = nil,
                 id: String = "s1", cwd: String = "/p") -> AgentSession {
        AgentSession(agent: agent, id: id, cwd: cwd, title: title, named: false, createdAt: nil, updatedAt: Date(),
                     gitBranch: branch, model: model, isRunning: false)
    }

    @Test func noWordsMatchEverything() {
        #expect(SearchWords("").isEmpty)
        #expect(SearchWords("  \t ").isEmpty)
        #expect(SearchWords("").matches("anything"))
        #expect(SearchWords(" ").matches(""))
    }

    @Test func everyWordInAnyOrder() {
        let title = "Fix the login redirect loop"
        #expect(SearchWords("loop fix").matches(title))
        #expect(SearchWords("redir  LOG").matches(title))
        #expect(!SearchWords("fix billing").matches(title))
        #expect(SearchWords("fix billing").words == ["fix", "billing"])
    }

    @Test func caseAndAccentsAreIgnored() {
        #expect(SearchWords("RESUME").matches("Résumé the café menu"))
        #expect(SearchWords("café").matches("CAFE"))
        #expect(SearchWords("e\u{301}t\u{E9}").matches("Été"))
        #expect(!SearchWords("cafes").matches("café"))
    }

    @Test func sessionsMatchWhatTheirRowShows() {
        let s = session("Tidy the tests", agent: .commandCode, branch: "feature/payments", model: "claude-opus-5-5")
        #expect(s.matches(SearchWords("tidy")))
        #expect(s.matches(SearchWords("command")))
        #expect(s.matches(SearchWords("payments tidy")))
        #expect(s.matches(SearchWords("opus code")))
        #expect(!s.matches(SearchWords("codex")))
    }

    @Test func notTheFolderOrTheID() {
        let s = session("Rate limits", id: "0f3a9c", cwd: "/Users/me/billing")
        #expect(!s.matches(SearchWords("0f3a9c")))
        #expect(!s.matches(SearchWords("billing")))
        // A session without a branch or a model has nothing there to match.
        #expect(!s.matches(SearchWords("main")))
    }

    @Test func matchingKeepsTheOrder() {
        let sessions = [session("Fix the login redirect loop", id: "a", cwd: "/a"),
                        session("Rate limits", branch: "main", id: "b", cwd: "/b"),
                        session("Login page copy", agent: .codex, id: "c", cwd: "/c")]
        #expect(AgentSessions.matching(sessions, "login").map(\.id) == ["a", "c"])
        #expect(AgentSessions.matching(sessions, "").map(\.id) == ["a", "b", "c"])
        #expect(AgentSessions.matching(sessions, "codex LOGIN").map(\.id) == ["c"])
        #expect(AgentSessions.matching(sessions, "nothing").isEmpty)
    }
}
