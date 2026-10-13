import Foundation
import Testing
@testable import NextTermCore

@Suite struct SecretAuditTests {
    @Test func aLineRoundTripsWithNoFieldForAValue() throws {
        let line = SecretAudit.Line(time: Date(timeIntervalSince1970: 1_791_547_200), event: .replace, names: ["DEPLOY_TOKEN"],
                                    who: "Codex, tab 2 of api", command: "npm test", folder: "/Users/me/api",
                                    approval: .fifteenMinutes, outcome: "allowed", earlierOrigin: "settings")
        let data = SecretAudit.encode(line)
        #expect(data.last == UInt8(ascii: "\n") && data.filter { $0 == UInt8(ascii: "\n") }.count == 1)
        #expect(SecretAudit.lines(in: data) == [line])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["time", "event", "names", "who", "command", "folder", "approval", "outcome", "earlier_origin"])
        #expect(object["approval"] as? String == "15 minutes" && object["event"] as? String == "replace")
        #expect(!object.keys.contains { $0.contains("value") || $0.contains("secret") })
    }

    @Test func textIsMaskedAndTheCommandCut() throws {
        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let line = SecretAudit.Line(event: .use, names: ["GITHUB_TOKEN"], who: "a tab titled \(token)",
                                    command: "echo \(token) " + String(repeating: "x", count: 400), folder: "/tmp", outcome: "allowed")
        let data = SecretAudit.encode(line) { $0.replacingOccurrences(of: token, with: "•••") }
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(token) && text.contains("•••"))
        let decoded = try #require(SecretAudit.lines(in: data).first)
        #expect(decoded.command?.count == SecretAudit.maxCommand && decoded.command?.hasSuffix("…") == true)
        #expect(decoded.names == ["GITHUB_TOKEN"])
    }

    @Test func lastUsePicksTheNewestUsePerName() {
        func line(_ seconds: TimeInterval, _ event: SecretAudit.Event, _ names: [String], who: String) -> Data {
            SecretAudit.encode(SecretAudit.Line(time: Date(timeIntervalSince1970: seconds), event: event, names: names, who: who))
        }
        var log = line(100, .use, ["A", "B"], who: "first")
        log += line(300, .use, ["A"], who: "newest A")
        log += line(400, .reveal, ["A"], who: "a reveal is not a use")
        log += line(200, .use, ["B"], who: "newest B")
        log += Data("not json\n".utf8)
        log += line(500, .add, ["C"], who: "added, never used")
        let last = SecretAudit.lastUse(in: log)
        #expect(last["A"]?.who == "newest A")
        #expect(last["B"]?.who == "newest B")
        #expect(last["C"] == nil)
    }

    @Test func rotationAtOneMegabyte() {
        #expect(!SecretAudit.needsRotation(size: 0, adding: 2_000_000)) // an empty log takes even a long line
        #expect(!SecretAudit.needsRotation(size: SecretAudit.maxSize - 100, adding: 100))
        #expect(SecretAudit.needsRotation(size: SecretAudit.maxSize - 100, adding: 101))
    }
}
