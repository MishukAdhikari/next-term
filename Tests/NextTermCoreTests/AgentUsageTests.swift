import Foundation
import Testing
@testable import NextTermCore

@Suite struct AgentUsageTests {
    private func tail(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    private let claudeLine = #"{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":3777,"cache_read_input_tokens":80221,"output_tokens":810}}}"#

    @Test func claudeLastMainChainMessage() {
        let side = #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku","usage":{"input_tokens":5000}}}"#
        let user = #"{"type":"user","message":{"content":"hi"}}"#
        let usage = AgentUsage.read(tail: tail([claudeLine, side, user]), kind: .claude)
        #expect(usage == AgentUsage(used: 84_000, window: 200_000, model: "claude-opus-5-5"))
        #expect(usage?.percent == 42)
        #expect(usage?.short == "42%")
        #expect(usage?.lines == ["Context 84k of 200k (42%)"])
    }

    @Test func claudeWindowGrowsPast200k() {
        #expect(AgentUsage.claudeWindow(model: "claude-sonnet-5-5", used: 150_000) == 200_000)
        #expect(AgentUsage.claudeWindow(model: "claude-sonnet-5-5", used: 250_000) == 1_000_000)
        #expect(AgentUsage.claudeWindow(model: "claude-opus-5-5[1m]", used: 10) == 1_000_000)
    }

    @Test func partialLinesAndNoUsage() {
        let cut = String(claudeLine.prefix(60))
        #expect(AgentUsage.read(tail: tail([cut, claudeLine, cut]), kind: .claude)?.used == 84_000)
        #expect(AgentUsage.read(tail: tail([#"{"type":"user","message":{"usage":"x"}}"#]), kind: .claude) == nil)
        #expect(AgentUsage.read(tail: Data(), kind: .codex) == nil)
    }

    @Test func codexTokenCountWithLimits() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":178121,"output_tokens":1053,"total_tokens":179174},"model_context_window":475000},"rate_limits":{"primary":{"used_percent":31.4,"window_minutes":300,"resets_at":1763000000},"secondary":{"used_percent":7,"window_minutes":10080},"credits":null}}}"#
        let empty = #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
        let usage = AgentUsage.read(tail: tail([line, empty]), kind: .codex)
        #expect(usage?.used == 179_174)
        #expect(usage?.window == 475_000)
        #expect(usage?.percent == 38)
        #expect(usage?.lines == ["Context 179k of 475k (38%)", "5-hour limit 31%", "Weekly limit 7%"])
    }

    @Test func codexNullLimits() {
        let line = #"{"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":24},"model_context_window":272000},"rate_limits":{"primary":null,"secondary":null}}}"#
        let usage = AgentUsage.read(tail: tail([line]), kind: .codex)
        #expect(usage == AgentUsage(used: 1024, window: 272_000))
    }

    @Test func tokenFormat() {
        #expect(AgentUsage.tokens(950) == "950")
        #expect(AgentUsage.tokens(1_000_000) == "1M")
        #expect(AgentUsage.tokens(1_250_000) == "1.2M")
    }
}
