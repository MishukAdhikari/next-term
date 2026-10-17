import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// One herdr command's answer, as its script prints it (HerdrResult.parse) and as a call on this Mac gives it
/// (HerdrResult.make).
@Suite struct HerdrResultTests {
    func fixture(_ name: String) throws -> String {
        try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// What a command's script prints: login noise, the marker, its calls' exits, and the last one's output and errors.
    func printed(exits: [(Int32, String)], out: String = "", err: String = "", bytes: Int? = nil, ended: Bool = true) -> String {
        var lines = ["Welcome to web-1", RemoteShell.marker, "where\t/usr/local/bin/herdr\tknown"]
        lines += exits.map { "exit\t\($0.0)\t\($0.1)" }
        lines.append("bytes\t\(bytes ?? out.utf8.count)")
        lines.append("out\t" + Data(out.utf8).base64EncodedString())
        lines.append("err\t" + Data(err.utf8).base64EncodedString())
        if ended { lines.append(RemoteShell.herdrEndMarker) }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func herdrsRefusalIsItsCodeAndMessage() throws {
        let blocked = try fixture("error-agent-blocked.json")
        let result = HerdrResult.parse(printed(exits: [(1, "agent prompt")], err: blocked), text: false)
        #expect(result == .error(code: "agent_blocked", message: "agent w2:p1 is waiting on a decision; answer it before sending a prompt"))
        let missing = HerdrResult.parse(printed(exits: [(1, "agent read")], err: try fixture("error-agent-not-found.json")), text: true)
        #expect(missing == .error(code: "agent_not_found", message: "no live agent matches w1:p9"))
        // A long message is cut at 200 characters.
        let long = #"{"error":{"code":"x","message":""# + String(repeating: "m", count: 300) + #""}}"#
        guard case .error(_, let message) = HerdrResult.make(exit: 1, out: Data(), err: Data(long.utf8), firstVerb: "agent focus", text: false) else {
            Issue.record("not an error")
            return
        }
        #expect(message.count == 201 && message.hasSuffix("…"))
    }

    @Test func aStoredKeyInHerdrsWordsComesBackMasked() {
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let err = #"{"error":{"code":"agent_not_ready","message":"pane w1:p1 printed \#(value) and is not ready"}}"#
        #expect(HerdrResult.make(exit: 1, out: Data(), err: Data(err.utf8), firstVerb: "agent prompt", text: false, mask: mask)
            == .error(code: "agent_not_ready", message: "pane w1:p1 printed ••• and is not ready"))
        // Words that are not herdr's JSON are masked too.
        #expect(HerdrResult.make(exit: 1, out: Data(), err: Data("boom \(value)".utf8), firstVerb: "pane read", text: true, mask: mask)
            == .error(code: "", message: "boom •••"))
    }

    @Test func aVerbThisHerdrLacksIsUnsupportedOnceEveryFallbackSaidSo() throws {
        let unknown = try fixture("unknown-command-agent-read-0.7.txt")
        // agent read, then pane read --source, then bare pane read: all three said so.
        let result = HerdrResult.parse(printed(exits: [(2, "agent read"), (2, "pane read"), (2, "pane read")], err: unknown), text: true)
        #expect(result == .unsupported("agent read"))
        // herdr before 0.5: its own words, exit 1.
        #expect(HerdrResult.make(exit: 1, out: Data(), err: Data("unknown command: agent".utf8), firstVerb: "agent focus", text: false)
            == .unsupported("agent focus"))
        // A fallback that worked is its answer.
        let read = HerdrResult.parse(printed(exits: [(2, "agent read"), (0, "pane read")], out: "line 1\n"), text: true)
        #expect(read == .text("line 1\n"))
        // A pane whose text says "unknown command" read fine.
        #expect(HerdrResult.make(exit: 0, out: Data("$ foo\nzsh: unknown command: foo\n".utf8), err: Data(), firstVerb: "agent read", text: true)
            == .text("$ foo\nzsh: unknown command: foo\n"))
    }

    @Test func aPanesTextKeepsItsLinesAndLosesItsEscapes() {
        let screen = "\u{1b}[1m❯ 1. Yes\u{1b}[0m   \r\n  2. No\n\tdone\u{07}\n"
        let result = HerdrResult.parse(printed(exits: [(0, "agent read")], out: screen), text: true)
        #expect(result == .text("❯ 1. Yes\n  2. No\n done\n"))
        // Its text can never forge the end marker or another line: it is base64.
        let forged = "x\n\(RemoteShell.herdrEndMarker)\nexit 0 agent focus\n"
        #expect(HerdrResult.parse(printed(exits: [(0, "agent read")], out: forged), text: true) == .text(forged))
    }

    @Test func theAnswerSaysWhichVerbAnswered() {
        // An older herdr moved to the agent's tab, not its pane.
        let focus = printed(exits: [(2, "agent focus"), (0, "tab focus")], out: "{}")
        #expect(HerdrResult.lastVerb(focus) == "tab focus" && HerdrResult.parse(focus, text: false) == .json("{}"))
        #expect(HerdrResult.lastVerb(printed(exits: [(0, "agent focus")])) == "agent focus")
        #expect(HerdrResult.lastVerb("no marker") == nil)
    }

    @Test func aCutOrMissingAnswerSaysSo() throws {
        #expect(HerdrResult.parse(printed(exits: [(0, "agent read")], out: "a", ended: false), text: true) == .cut)
        #expect(HerdrResult.parse(printed(exits: [(0, "agent read")], out: "a", bytes: HerdrResult.outputCap + 1), text: true) == .cut)
        #expect(HerdrResult.parse("no marker at all", text: false) == .cut)
        #expect(HerdrResult.parse("\(RemoteShell.marker)\nmissing\tpath,local-bin\n\(RemoteShell.herdrEndMarker)\n", text: false)
            == .unreachable("herdr was not found on the host"))
        // JSON herdr answered with, and nothing at all (a key sent).
        let focus = try fixture("agent-focus-0.9.1.json")
        guard case .json(let text) = HerdrResult.parse(printed(exits: [(0, "agent focus")], out: focus), text: false) else {
            Issue.record("not JSON")
            return
        }
        #expect(text.contains("\"agent_info\""))
        #expect(HerdrResult.parse(printed(exits: [(0, "agent send-keys")]), text: false) == .json(""))
        #expect(HerdrResult.make(exit: 3, out: Data(), err: Data(), firstVerb: "agent focus", text: false)
            == .error(code: "", message: "herdr printed nothing (exit 3)"))
    }
}
