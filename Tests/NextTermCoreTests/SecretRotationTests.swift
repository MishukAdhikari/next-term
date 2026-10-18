import Foundation
import Testing
@testable import NextTermCore

/// What Rotate… shows, told on the Mac with no network: the page its first step opens, the tip beside the paste field,
/// and whether a pasted key looks like another provider's than its page. Every value is made up: a provider's head and
/// filler, put together at run time.
@Suite struct SecretRotationTests {
    private static let utc = TimeZone(identifier: "UTC")!

    /// 13 October 2026, at noon in UTC.
    private static var thirteenthOfOctober: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
    }

    private static func value(_ head: String, length: Int = 48) -> SecretBytes {
        let room = max(0, length - head.utf8.count)
        return SecretBytes(utf8: head + String(repeating: "x", count: room))
    }

    private static func url(_ text: String) -> URL { URL(string: text)! }

    @Test func githubsTokensPageOpensItsNewTokenFormFilledIn() {
        let link = Self.url("https://github.com/settings/personal-access-tokens")
        let page = SecretRotation.pageToOpen(link, name: "GITHUB_PERSONAL_ACCESS_TOKEN", date: Self.thirteenthOfOctober,
                                             timeZone: Self.utc)
        let expected = "https://github.com/settings/personal-access-tokens/new"
            + "?name=GITHUB_PERSONAL_ACCESS_TOKEN%202026-10-13&expires_in=90"
        #expect(page.absoluteString == expected)
        let under = Self.url("https://github.com/settings/personal-access-tokens/1234567")
        let fromUnder = SecretRotation.pageToOpen(under, name: "GITHUB_TOKEN", date: Self.thirteenthOfOctober, timeZone: Self.utc)
        #expect(fromUnder.absoluteString.hasPrefix("https://github.com/settings/personal-access-tokens/new?name=GITHUB_TOKEN%20"))
    }

    @Test func otherPagesOpenAsTheyAre() {
        let pages = ["https://github.com/settings/tokens", "https://platform.openai.com/settings/organization/api-keys",
                     "http://localhost:3000/project/settings", "https://example.com/keys"]
        for text in pages {
            let link = Self.url(text)
            #expect(SecretRotation.pageToOpen(link, name: "GITHUB_TOKEN", date: Self.thirteenthOfOctober) == link, "\(text)")
        }
    }

    @Test func aProviderWhoseRotationHasATwistHasATip() {
        let aws = Self.url("https://console.aws.amazon.com/iam/home#/security_credentials")
        #expect(SecretRotation.tip(for: aws) == "Create a second access key, then deactivate the old one.")
        #expect(SecretRotation.tip(for: Self.url("https://dashboard.stripe.com/apikeys")) == "Choose when the old key expires.")
        #expect(SecretRotation.tip(for: Self.url("https://portal.azure.com/#home")) == "Regenerate the key you are not using.")
        #expect(SecretRotation.tip(for: Self.url("https://platform.openai.com/settings/organization/api-keys")) == nil)
        #expect(SecretRotation.tip(for: Self.url("http://localhost:3000/")) == nil)
        #expect(SecretRotation.tip(for: nil) == nil)
    }

    @Test func aKeyThatLooksLikeAnotherProvidersIsNamed() {
        let openAI = Self.url("https://platform.openai.com/settings/organization/api-keys")
        let warning = SecretRotation.warning(value: Self.value("sk-or-v1-"), link: openAI)
        #expect(warning == "This key looks like one from OpenRouter, but its page is OpenAI\u{2019}s.")
        #expect(SecretRotation.warning(value: Self.value("sk-proj-"), link: openAI) == nil)
    }

    @Test func noWarningWithoutTwoProvidersToCompare() {
        let classic = Self.url("https://github.com/settings/tokens")
        #expect(SecretRotation.warning(value: Self.value("github_pat_"), link: classic) == nil)
        #expect(SecretRotation.warning(value: Self.value("made-up-"), link: classic) == nil)
        #expect(SecretRotation.warning(value: Self.value("sk-proj-"), link: nil) == nil)
        #expect(SecretRotation.warning(value: Self.value("sk-proj-"), link: Self.url("https://example.com/keys")) == nil)
        #expect(SecretRotation.warning(value: Self.value("sk-proj-", length: 10), link: classic) == nil)
    }

    @Test func theOldKeyStaysMaskedForThirtyDays() {
        #expect(SecretRotation.keptMaskedLine == "Next Term keeps masking the old key for 30 days, while it may still work.")
    }
}

/// The audit's line for a key rotation.
@Suite struct SecretAuditRotateTests {
    @Test func aRotationLineRoundTrips() throws {
        let line = SecretAudit.Line(time: Date(timeIntervalSince1970: 1_791_547_200), event: .rotate, names: ["GITHUB_TOKEN"],
                                    who: "you, in Settings › Secrets", outcome: "done", earlierOrigin: "settings")
        let data = SecretAudit.encode(line)
        #expect(SecretAudit.lines(in: data) == [line])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["event"] as? String == "rotate")
    }

    /// An older build has no `rotate`: it skips that line and keeps reading, as this one skips an event a later
    /// release adds.
    @Test func aLineWithAnEventThisBuildDoesntKnowIsSkipped() {
        let use = SecretAudit.encode(SecretAudit.Line(time: Date(timeIntervalSince1970: 100), event: .use, names: ["A"]))
        let rotate = SecretAudit.encode(SecretAudit.Line(time: Date(timeIntervalSince1970: 200), event: .rotate, names: ["A"]))
        let later = Data(#"{"event":"retire","names":["A"],"time":"2026-10-13T00:00:00Z"}"#.utf8) + Data("\n".utf8)
        let lines = SecretAudit.lines(in: use + later + rotate)
        #expect(lines.map(\.event) == [.use, .rotate])
    }
}
