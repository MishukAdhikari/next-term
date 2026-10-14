import Foundation
import Testing
@testable import NextTermCore

/// The rules a key's "Where it came from" link meets when it is typed, read and opened. Every host, link and value here
/// is made up; the token-shaped one is put together at run time from an alphabet run, so no file holds one whole.
@Suite struct SecretLinkTests {
    private static let noMask: (String) -> Bool = { (_: String) -> Bool in false }

    private static func refusal(_ text: String, mask: (String) -> Bool = noMask,
                                value: SecretBytes? = nil) -> SecretLink.Refusal? {
        if case .failure(let refusal) = SecretLink.check(text, mask: mask, value: value) { return refusal }
        return nil
    }

    private static func accepted(_ text: String, value: SecretBytes? = nil) -> String? {
        let result: Result<URL, SecretLink.Refusal> = SecretLink.check(text, mask: noMask, value: value)
        return try? result.get().absoluteString
    }

    /// GitHub's classic token shape: `ghp_` and 36 letters, made here so this file never holds one.
    private static var tokenShaped: String { "ghp" + "_" + String(repeating: "abcdef", count: 6) }

    @Test func keyPagesAndThisMacsServersAreAccepted() {
        let links = ["https://platform.openai.com/settings/organization/api-keys",
                     "http://localhost:3000/project/x/settings", "http://127.0.0.1:8080/", "http://[::1]:8000/keys",
                     "https://accounts.example.com/keys?authuser=1", "https://console.example.com/#/settings/api-keys",
                     "https://console.example.com/keys?project=rag-api&tab=keys"]
        for link in links { #expect(Self.accepted(link) == link, "\(link)") }
    }

    @Test func whatIsStoredIsTheLinkTidied() {
        #expect(Self.accepted("  https://dashboard.example.com/apikeys \n") == "https://dashboard.example.com/apikeys")
        #expect(Self.accepted("HTTPS://Dashboard.Example.COM/ApiKeys") == "https://dashboard.example.com/ApiKeys")
        // A bare host with a dot, or localhost, is given https; a single word names no page.
        #expect(Self.accepted("dashboard.example.com/apikeys") == "https://dashboard.example.com/apikeys")
        #expect(Self.accepted("localhost:3000/settings") == "https://localhost:3000/settings")
        #expect(Self.refusal("apikeys") == .notALink)
        // Letters from another script in the path are percent-encoded; in the host they are refused.
        #expect(Self.accepted("https://docs.example.com/cl\u{E9}s") == "https://docs.example.com/cl%C3%A9s")
        #expect(Self.refusal("https://pl\u{0430}tform.example.com/keys") == .host)
    }

    @Test func eachRefusedLinkHasItsReason() {
        let cases: [(String, SecretLink.Refusal)] = [
            ("http://dashboard.example.com", .scheme), ("javascript:alert(1)", .scheme), ("file:///etc/hosts", .scheme),
            ("ftp://files.example.com/keys", .scheme),
            ("https://u:p@x.example.com", .userOrPassword), ("https://admin:pw@dashboard.example.com/apikeys", .userOrPassword),
            ("https://admin@x.example.com", .userOrPassword),
            ("https://xn--pltfrm-9ta.example.com/keys", .host), ("https://x_y.example.com", .host),
            ("https://0.0.0.0:3000", .host),
            ("https://x.example.com/a/../b", .path), ("https://x.example.com/a/%2e%2e/b", .path),
            ("https://x.example.com/?token=abc", .secretParameter), ("https://x.example.com/?api_key=abc", .secretParameter),
            ("https://x.example.com/?code=abc", .secretParameter), ("https://x.example.com/?a=1&sig=abc", .secretParameter),
            ("https://x.example.com/cb#access_token=abc&token_type=bearer", .secretParameter),
            ("https://app.example.com/#/keys?password=abc", .secretParameter),
            ("", .notALink), ("   ", .notALink), ("not a link", .notALink), ("https://x.example.com/a b", .notALink),
            ("https://x.example.com/a\u{7}b", .notALink), ("https://x.example.com:0/keys", .notALink), ("https://", .notALink),
        ]
        for (text, reason) in cases {
            #expect(Self.refusal(text) == reason, "\(text)")
        }
    }

    @Test func aLinkHasAtMost2048Characters() {
        let start = "https://x.example.com/"
        let longest = start + String(repeating: "a", count: SecretLink.maxLength - start.count)
        #expect(Self.accepted(longest) == longest)
        #expect(Self.refusal(longest + "a") == .tooLong)
        // Percent-encoding counts: what is stored stays within the limit.
        let encoded = start + String(repeating: "\u{E9}", count: 400)
        #expect(Self.refusal(encoded) == .tooLong)
    }

    @Test func aLinkHoldingAKeyIsRefused() {
        let token = Self.tokenShaped
        #expect(Self.refusal("https://x.example.com/cb?state=" + token) == .holdsAKey)
        #expect(Self.refusal("https://x.example.com/" + token) == .holdsAKey)
        let encoded = token.replacingOccurrences(of: "_", with: "%5F")
        #expect(Self.refusal("https://x.example.com/cb?state=" + encoded) == .holdsAKey)
    }

    @Test func aLinkHoldingAStoredValueIsRefused() {
        let stored = "made-up-stored-value-0123"
        let mask: (String) -> Bool = { (text: String) -> Bool in text.contains(stored) }
        #expect(Self.refusal("https://x.example.com/?state=" + stored, mask: mask) == .holdsAKey)
        #expect(Self.refusal("https://x.example.com/?state=other", mask: mask) == nil)
    }

    @Test func aLinkHoldingTheSheetsOwnValueIsRefused() throws {
        let value = SecretBytes(utf8: "  made-up-sheet-value-0123  ")
        #expect(Self.refusal("https://x.example.com/?state=made-up-sheet-value-0123", value: value) == .holdsAKey)
        let base64 = Data("made-up-sheet-value-0123".utf8).base64EncodedString()
        let base64Link = "https://x.example.com/?state=" + base64.replacingOccurrences(of: "=", with: "")
        #expect(Self.refusal(base64Link, value: value) == .holdsAKey)
        #expect(Self.accepted("https://x.example.com/?state=other", value: value) != nil)
        // A value under 12 characters is not looked for, as masking doesn't look for one.
        #expect(Self.accepted("https://x.example.com/short1", value: SecretBytes(utf8: "short1")) != nil)
    }

    @Test func everyReasonIsOnePlainSentence() {
        for refusal in SecretLink.Refusal.allCases {
            #expect(refusal.sentence.hasSuffix("."), "\(refusal)")
            #expect(!refusal.sentence.contains("\n"), "\(refusal)")
            #expect(refusal.errorDescription == refusal.sentence)
        }
        #expect(SecretLink.Refusal.userOrPassword.sentence == "A link can\u{2019}t hold a user name or password.")
        #expect(SecretLink.Refusal.holdsAKey.sentence == "A link can\u{2019}t hold a key.")
        #expect(SecretLink.Refusal.scheme.sentence == "Only https, or http to this Mac.")
    }

    @Test func theHostTheButtonNames() throws {
        let page = try #require(URL(string: "https://platform.openai.com/settings/organization/api-keys"))
        #expect(SecretLink.host(of: page) == "platform.openai.com")
        let local = try #require(URL(string: "http://localhost:3000/project/x"))
        #expect(SecretLink.host(of: local) == "localhost:3000")
        let loopback = try #require(URL(string: "http://[::1]:8000/"))
        #expect(SecretLink.host(of: loopback) == "[::1]:8000")
        let upper = try #require(URL(string: "https://Dashboard.Example.com/keys"))
        #expect(SecretLink.host(of: upper) == "dashboard.example.com")
    }

    /// Opening trusts only vault.json's bytes as Next Term last wrote them or MAC-checked them.
    @Test func aVouchCoversOnlyTheBytesItWasMadeFrom() {
        let written = Data(#"{"format":1,"body":"e30=","mac":"AAAA"}"#.utf8)
        let vouch = SecretLink.Vouch(file: written)
        #expect(vouch.covers(written))
        #expect(!vouch.covers(written + Data(" ".utf8)))
        #expect(!vouch.covers(Data()))
    }
}
