import Foundation
import Testing
@testable import NextTermCore

/// A session's token budget: what the agent recorded for the whole session, against what the user asked for.
@Suite struct TokenBudgetTests {
    @Test func budgetsAreReadAsPeopleWriteThem() {
        #expect(TokenBudget.parse("2M") == 2_000_000)
        #expect(TokenBudget.parse("500k") == 500_000)
        #expect(TokenBudget.parse("1.5m") == 1_500_000)
        #expect(TokenBudget.parse("2,000,000") == 2_000_000)
        #expect(TokenBudget.parse(750_000) == 750_000)
        #expect(TokenBudget.parse(0) == 0)
        #expect(TokenBudget.parse("lots") == nil && TokenBudget.parse(-5) == nil && TokenBudget.parse(true) == nil && TokenBudget.parse(1.5) == nil)
    }

    @Test func theWordsAndHowFarAlong() {
        let shown = TokenBudget.words(spent: 1_200_000, budget: 2_000_000)
        #expect(shown.text == "1.2M of 2M budget" && shown.fraction == 0.6)
        #expect(TokenBudget.words(spent: 2_500_000, budget: 2_000_000).fraction > 1)
    }

    @Test func claudeCountsEachMessageOnceAndLeavesCacheReadsOut() {
        var spend = TokenSpend(kind: .claude)
        let a1 = #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":5}}}"#
        let a2 = #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":90}}}"#
        let b = #"{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":4,"cache_read_input_tokens":51000,"output_tokens":20}}}"#
        let user = #"{"type":"user","message":{"content":"hi"}}"#
        spend.feed(Data((a1 + "\n" + user + "\n").utf8))
        #expect(spend.total == 1_015)
        spend.feed(Data((a2 + "\n" + String(b.prefix(30))).utf8)) // m1 again, then half a line
        #expect(spend.total == 1_100)
        spend.feed(Data((String(b.dropFirst(30)) + "\n").utf8))
        #expect(spend.total == 1_124)
    }

    @Test func codexTakesItsOwnRunningTotal() {
        var spend = TokenSpend(kind: .codex)
        let first = #"{"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000,"cached_input_tokens":6000,"output_tokens":300}}}}"#
        let later = #"{"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20000,"cached_input_tokens":15000,"output_tokens":800}}}}"#
        spend.feed(Data((first + "\n").utf8))
        #expect(spend.total == 3_300)
        spend.feed(Data((later + "\n").utf8))
        #expect(spend.total == 5_800)
    }
}
