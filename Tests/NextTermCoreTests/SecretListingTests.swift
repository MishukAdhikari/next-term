import Foundation
import Testing
@testable import NextTermCore

/// What agents learn of a key's page: at most the provider's name. No tool takes a link, and `list_secrets` never
/// gives one, since a full URL can carry an organization's or a project's id.
@Suite struct SecretListingTests {
    static let calendar = SecretAgeTests.calendar
    static let now = SecretAgeTests.now

    static func entry(link: String?, valueSet: Date, remindDays: Int? = nil) -> SecretVault.Entry {
        var entry = SecretAgeTests.entry(created: SecretAgeTests.date(2026, 1, 5), valueSet: valueSet, remindDays: remindDays)
        entry.link = link
        entry.linkFrom = link == nil ? nil : .user
        return entry
    }

    static func facts(_ entry: SecretVault.Entry) -> [String: Any] {
        MCPServer.secretSourceFacts(entry, now: now, calendar: calendar)
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aKnownPageGivesItsProviderAndNoLink() {
        let link = "https://dashboard.stripe.com/apikeys?account=acct_madeup123"
        let facts = Self.facts(Self.entry(link: link, valueSet: SecretAgeTests.date(2026, 10, 12)))
        #expect(facts["service"] as? String == "Stripe")
        #expect(facts["rotated"] as? String == "2026-10-12")
        #expect(facts["rotate_due"] as? Bool == false)
        #expect(Set(facts.keys) == ["service", "rotated", "rotate_due"])
        let text = Self.json(facts)
        for part in ["https", "dashboard.stripe.com", "apikeys", "acct_madeup123"] { #expect(!text.contains(part), "\(part)") }
    }

    @Test func aHostUnderAKnownPagesHostNamesItsProvider() {
        let facts = Self.facts(Self.entry(link: "https://us.cloud.langfuse.com/project/madeup", valueSet: Self.now))
        #expect(facts["service"] as? String == "Langfuse")
    }

    @Test func noLinkAnUnknownHostOrABadLinkNamesNoService() {
        let links: [String?] = [nil, "https://dashboard.example.com/keys", "http://localhost:3000/project/settings",
                                "http://platform.openai.com/settings/organization/api-keys",
                                "https://platform.openai.com/?token=made-up"]
        for link in links {
            let facts = Self.facts(Self.entry(link: link, valueSet: Self.now))
            #expect(facts["service"] is NSNull, "\(link ?? "none")")
        }
    }

    @Test func aDueReminderSaysSo() {
        let facts = Self.facts(Self.entry(link: nil, valueSet: SecretAgeTests.date(2026, 7, 13), remindDays: 90))
        #expect(facts["rotate_due"] as? Bool == true)
        #expect(facts["rotated"] as? String == "2026-07-13")
    }

    /// The schema says what a client may send, but Next Term's server doesn't check arguments against it: the
    /// guarantee is that no handler reads a link. Every argument the secret tools' handlers read is one of these.
    @Test func noSecretToolReadsALink() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = ["name", "request_id", "reason", "value", "secrets", "command", "directory", "tab_id"]
        let pattern = try NSRegularExpression(pattern: #"arguments\[\s*"([^"]*)"\s*\]"#)
        var read: Set<String> = []
        for path in ["Sources/NextTerm/SecretsMCP.swift", "Sources/NextTerm/SecretRequests.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let key = Range(match.range(at: 1), in: text) else { continue }
                read.insert(String(text[key]))
            }
        }
        #expect(read.contains("name") && read.contains("value"))
        #expect(read.isSubset(of: allowed), "\(read.subtracting(allowed).sorted())")
        for tool in MCPServer.secretTools {
            let schema = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any])
            let properties = (schema["properties"] as? [String: Any]) ?? [:]
            for name in ["link", "url", "page"] { #expect(properties[name] == nil, "\(tool.name) \(name)") }
        }
    }

    @Test func listSecretsSaysWhatItGivesOfAPage() throws {
        let tool = try #require(MCPServer.secretTools.first { $0.name == "list_secrets" })
        for member in ["service", "rotated", "rotate_due"] { #expect(tool.description.contains(member), "\(member)") }
    }
}
