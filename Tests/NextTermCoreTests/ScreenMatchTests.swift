import Testing
@testable import NextTermCore

/// wait_for_tab's match on a tab of this Mac: herdr's wait-output rule, a substring or a regular expression.
@Suite struct ScreenMatchTests {
    @Test func aSubstringOrARegularExpression() {
        #expect(ScreenMatch.matches("ok\ntest result: 4 passed\n$ ", pattern: "test result", regex: false))
        #expect(!ScreenMatch.matches("test resu", pattern: "test result", regex: false))
        #expect(ScreenMatch.matches("4 passed, 0 failed", pattern: #"\d+ passed"#, regex: true))
        #expect(!ScreenMatch.matches("passed", pattern: #"\d+ passed"#, regex: true))
        // As text, a pattern's own characters are only themselves.
        #expect(!ScreenMatch.matches("4 passed", pattern: #"\d+ passed"#, regex: false))
    }

    @Test func whatCannotBeWaitedForIsRefused() {
        #expect(ScreenMatch.refusal("", regex: false) != nil)
        #expect(ScreenMatch.refusal(String(repeating: "a", count: 1001), regex: false) != nil)
        #expect(ScreenMatch.refusal("(unclosed", regex: true) != nil)
        #expect(ScreenMatch.refusal("(unclosed", regex: false) == nil)
    }
}
