import Foundation
import Testing
@testable import NextTermCore

/// The chat's usage line: what the agent records, in calm words with tabular figures.
@Suite struct ChatUsageLineTests {
    @Test func theLineGivesTokensAndThePercentOfContext() {
        let usage = AgentUsage(used: 190_000, window: 200_000)
        #expect(ChatUsageLine.text(usage) == "190k tokens  \u{00B7}  95\u{2009}% of context")
        #expect(ChatUsageLine.parts(usage).nearLimit)
        #expect(!ChatUsageLine.parts(AgentUsage(used: 84_000, window: 200_000)).nearLimit)
        #expect(ChatUsageLine.text(AgentUsage(used: 950, window: 200_000)) == "950 tokens  \u{00B7}  0\u{2009}% of context")
    }

    @Test func theTooltipBreaksTheLastRequestDown() {
        let usage = AgentUsage(used: 189_200, window: 200_000, model: "claude-opus-5-5",
                               breakdown: .init(input: 1_200, cacheRead: 180_000, cacheWritten: 8_000, output: 800))
        let tip = ChatUsageLine.tooltip(usage, locale: Locale(identifier: "en_US"))
        #expect(tip == "Context: 189,200 of 200,000 tokens (95\u{2009}%)\nLast request: input 1,200, cache read 180,000, cache written 8,000, output 800\nModel: claude-opus-5-5")
        // No breakdown, no model: the context alone.
        #expect(ChatUsageLine.tooltip(AgentUsage(used: 5_000, window: 200_000), locale: Locale(identifier: "en_US")) == "Context: 5,000 of 200,000 tokens (3\u{2009}%)")
    }

    @Test func claudeAndCodexTranscriptsGiveTheBreakdown() {
        let claude = #"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300,"output_tokens":40}}}"#
        let c = AgentUsage.read(tail: Data((claude + "\n").utf8), kind: .claude)
        #expect(c?.breakdown == .init(input: 10, cacheRead: 2000, cacheWritten: 300, output: 40))
        let codex = #"{"payload":{"type":"token_count","info":{"model_context_window":258000,"last_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":200,"total_tokens":5200}}}}"#
        let x = AgentUsage.read(tail: Data((codex + "\n").utf8), kind: .codex)
        #expect(x?.breakdown == .init(input: 1000, cacheRead: 4000, cacheWritten: 0, output: 200))
    }

    @Test func aSessionTakesTheAgentsOwnUsageOnly() {
        var session = ACPSession()
        #expect(session.contextUsage == nil)
        session.apply(update: .object(["update": .object(["sessionUpdate": .string("usage_update"), "used": .number(12_000), "size": .number(200_000)])]))
        #expect(session.contextUsage == AgentUsage(used: 12_000, window: 200_000))
    }
}
