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
                     "https://console.example.com/keys?project=rag-api&tab=keys",
                     "https://console.example.com/keys;view=list?country_code=bd&design=dark", "http://127.4.5.6/",
                     "https://app.test/keys", "https://keys.localhost/settings"]
        for link in links { #expect(Self.accepted(link) == link, "\(link)") }
    }

    @Test func whatIsStoredIsTheLinkTidied() {
        #expect(Self.accepted("  https://dashboard.example.com/apikeys \n") == "https://dashboard.example.com/apikeys")
        #expect(Self.accepted("HTTPS://Dashboard.Example.COM/ApiKeys") == "https://dashboard.example.com/ApiKeys")
        // A bare host with a dot is given https, and this Mac's loopback http, as a self-hosted server there serves;
        // a single word names no page.
        #expect(Self.accepted("dashboard.example.com/apikeys") == "https://dashboard.example.com/apikeys")
        #expect(Self.accepted("localhost:3000/settings") == "http://localhost:3000/settings")
        #expect(Self.accepted("127.0.0.1:8080/keys") == "http://127.0.0.1:8080/keys")
        #expect(Self.accepted("[::1]:8000/") == "http://[::1]:8000/")
        #expect(Self.accepted("keys.localhost/") == "https://keys.localhost/")
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
            ("https://x.example.com/a;token=abc", .secretParameter), ("https://x.example.com/a;v=1;api_key=abc/b", .secretParameter),
            ("https://x.example.com/f?X-Amz-Signature=abc", .secretParameter), ("https://x.example.com/?pw=abc", .secretParameter),
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

    /// A stored link that holds a key, such as one whose key was stored after the link was saved, stays out of Edit's
    /// field: its text would show a write-only key. It is hidden whatever rule refuses it first.
    @Test func aStoredLinkHoldingAKeyIsKeptOutOfTheField() {
        let stored = "made-up-stored-value-0123"
        let mask: (String) -> Bool = { (text: String) -> Bool in text.contains(stored) }
        let escaped: String = "%6D" + stored.dropFirst()
        #expect(SecretLink.hides("https://dashboard.example.com/keys/" + stored, mask: mask))
        #expect(SecretLink.hides("https://dashboard.example.com/keys/" + escaped, mask: mask))
        #expect(SecretLink.hides("https://x.example.com/" + Self.tokenShaped, mask: Self.noMask))
        // Refused first for its scheme, its user and password, or an escape that doesn't decode.
        #expect(SecretLink.hides("http://dashboard.example.com/keys/" + stored, mask: mask))
        #expect(SecretLink.hides("http://dashboard.example.com/keys/" + escaped, mask: mask))
        #expect(SecretLink.hides("https://u:p@dashboard.example.com/" + stored, mask: mask))
        #expect(SecretLink.hides("https://dashboard.example.com/%E9/" + stored, mask: mask))
        #expect(SecretLink.hides("https://dashboard.example.com/%E9/" + escaped, mask: mask))
        #expect(SecretLink.decodedLeniently("a%2Fb%E9%zz%4") == "a/b\u{FFFD}%zz%4")
        // A link with no key in it shows, kept or refused.
        #expect(!SecretLink.hides("https://dashboard.example.com/keys", mask: mask))
        #expect(!SecretLink.hides("https://u:p@dashboard.example.com/keys", mask: mask))
        #expect(!SecretLink.hides("http://dashboard.example.com/keys", mask: mask))
        #expect(!SecretLink.hides("https://x.example.com/cb?token=other", mask: mask))
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

    /// One escape that doesn't decode would leave the text undecoded, and a key with one character escaped would pass
    /// every key check; Foundation re-encodes every `%` of a part with a bad escape or a second `#`, with the same end.
    /// So such a link is refused whole.
    @Test func aLinkWithAnEscapeThatDoesntDecodeIsRefused() {
        let token = Self.tokenShaped.replacingOccurrences(of: "_", with: "%5F")
        let sheet = "made-up-sheet-value%2D0123"
        let value = SecretBytes(utf8: "made-up-sheet-value-0123")
        let stored = "made-up-stored-value-0123"
        let mask: (String) -> Bool = { (text: String) -> Bool in text.contains(stored) }
        let storedEscaped = "made-up-stored-value%2D0123"
        for bad in ["%FF", "%e9", "%zz", "%", "%2", "1%"] {
            #expect(Self.refusal("https://x.example.com/cb?state=" + token + "&x=" + bad) == .notALink, "\(bad)")
            #expect(Self.refusal("https://x.example.com/?s=" + sheet + "&z=" + bad, value: value) == .notALink, "\(bad)")
            #expect(Self.refusal("https://x.example.com/?s=" + storedEscaped + "&z=" + bad, mask: mask) == .notALink)
            #expect(Self.refusal("https://x.example.com/a" + bad + "/b") == .notALink, "\(bad)")
            #expect(Self.refusal("https://x.example.com/#s=" + bad) == .notALink, "\(bad)")
        }
        #expect(Self.refusal("https://x.example.com/cb#a#b&s=" + token) == .notALink)
        #expect(Self.refusal("https://x.example.com/cb#a#b") == .notALink)
        // Without the bad escape, each is refused for the key it holds.
        #expect(Self.refusal("https://x.example.com/cb?state=" + token) == .holdsAKey)
        #expect(Self.refusal("https://x.example.com/?s=" + sheet, value: value) == .holdsAKey)
        #expect(Self.refusal("https://x.example.com/?s=" + storedEscaped, mask: mask) == .holdsAKey)
        // An escape that decodes is kept as typed.
        #expect(Self.accepted("https://docs.example.com/cl%C3%A9s?q=a%20b") == "https://docs.example.com/cl%C3%A9s?q=a%20b")
    }

    /// Plain http goes only to this Mac's loopback: a `.test` or `.localhost` name is looked up through DNS, and a
    /// network's DNS can answer for it.
    @Test func plainHttpGoesOnlyToLoopback() {
        for link in ["http://evil.test/keys", "http://keys.localhost/", "http://app.localhost:3000/settings",
                     "http://127.0.0.1.example.com/", "http://host.docker.internal:3000/"] {
            #expect(Self.refusal(link) == .scheme, "\(link)")
        }
        for link in ["http://localhost/", "http://127.0.0.1:3000/a", "http://127.255.0.9/", "http://[::1]/"] {
            #expect(Self.accepted(link) == link, "\(link)")
        }
    }

    /// What is stored checks back to itself, so a link the app shows or opens is the one the user saved.
    @Test func aStoredLinkChecksBackToItself() {
        let typed = ["  https://dashboard.example.com/apikeys \n", "HTTPS://Dashboard.Example.COM/ApiKeys",
                     "dashboard.example.com/apikeys", "localhost:3000/settings", "[::1]:8000", "127.0.0.1:8080/keys?x=1",
                     "https://docs.example.com/cl\u{E9}s", "https://docs.example.com/cl%C3%A9s?q=a%20b#top",
                     "https://x.example.com", "https://x.example.com/?", "https://x.example.com/#", "https://x.example.com:443/",
                     "https://console.example.com/#/settings/api-keys?tab=1", "https://x.example.com/a;view=list/b",
                     "https://x.example.com/a%2Fb/c!$&'()*+,:@~", "http://LOCALHOST:3000/A?B=C#D"]
        for text in typed {
            guard let stored = Self.accepted(text) else {
                Issue.record("refused: \(text)")
                continue
            }
            #expect(Self.accepted(stored) == stored, "\(text)")
        }
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
