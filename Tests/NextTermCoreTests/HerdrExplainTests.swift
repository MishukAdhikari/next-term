import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Why herdr gives an agent its state, as Peek shows `herdr agent explain --json` (HerdrExplain): herdr's own words, cut
/// to what says why.
@Suite struct HerdrExplainTests {
    func fixture(_ name: String) throws -> String {
        try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theStateTheManifestTheRuleAndTheWarningAndNothingElse() throws {
        let lines = try #require(HerdrExplain.summary(json: try fixture("agent-explain-0.9.5.json")))
        #expect(lines == [
            "agent: claude", "state: blocked", "manifest: builtin 2026.10.2",
            "rule: claude.permission_prompt (region bottom, priority 90)", "warning: the title spinner disagrees with the screen",
        ])
        // Each rule herdr tried, and its evidence, stay out.
        #expect(!lines.joined().contains("claude.working") && !lines.joined().contains("Do you want"))
    }

    @Test func noRuleAFallbackAndHerdrsEnvelope() throws {
        let fallback = #"{"result":{"explain":{"agent":"codex","state":"unknown","manifest_source":null,"matched_rule":null,"fallback_reason":"no manifest matched"}}}"#
        #expect(HerdrExplain.summary(json: fallback) == ["agent: codex", "state: unknown", "manifest: none unknown", "rule: none",
                                                          "fallback: no manifest matched"])
        // Not herdr's explanation: none.
        #expect(HerdrExplain.summary(json: "not json") == nil && HerdrExplain.summary(json: #"{"ok":true}"#) == nil)
    }

    @Test func anAnswerThatIsNotJSONIsShownCutToTwentyLinesAndEverythingIsMasked() {
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        #expect(HerdrExplain.shown(long).components(separatedBy: "\n").count == 20)
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let said = #"{"agent":"claude","state":"idle","manifest_source":"builtin","manifest_version":"1","matched_rule":null,"warning":"saw \#(value)"}"#
        #expect(HerdrExplain.shown(said, mask: mask).hasSuffix("warning: saw •••"))
    }
}
