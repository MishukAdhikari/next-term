import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Peek's Conversation (AgentTranscript): the transcript found only by the session herdr names, its tail read as turns,
/// from hand-written stand-ins of Claude Code's and Codex's files (no real conversation).
@Suite struct AgentTranscriptTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/transcripts")

    func tail(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    @Test func claudesTailIsTurnsWithItsToolsCountedAndItsFirstLineDropped() throws {
        let turns = try #require(AgentTranscript.turns(tail: try tail("claude-tail.jsonl"), kind: .claude))
        #expect(turns == [
            AgentTranscript.Turn(role: .user, text: "Fix the login test"),
            AgentTranscript.Turn(role: .agent, text: "I'll look at the test first.", tools: 3),
            AgentTranscript.Turn(role: .agent, text: "The test passes now."),
            AgentTranscript.Turn(role: .user, text: "Now run the linter"),
        ])
        #expect(!turns.contains { $0.text.contains("cut here") || $0.text.contains("left out") })
        let shown = AgentTranscript.text(turns, agent: "claude")
        #expect(shown.contains("claude: I'll look at the test first.  (ran 3 tools)") && shown.hasPrefix("You: Fix the login test"))
    }

    @Test func codexsTailHasTheSameShape() throws {
        let turns = try #require(AgentTranscript.turns(tail: try tail("codex-tail.jsonl"), kind: .codex))
        #expect(turns == [
            AgentTranscript.Turn(role: .user, text: "Fix the login test"),
            AgentTranscript.Turn(role: .agent, text: "The test passes now.", tools: 2),
        ])
    }

    @Test func aTailWithNoWholeLineIsNoConversation() {
        #expect(AgentTranscript.turns(tail: Data("half a line".utf8), kind: .claude) == nil)
        #expect(AgentTranscript.turns(tail: Data("cut\nnot json either\n".utf8), kind: .codex) == nil)
    }

    @Test func theTranscriptIsFoundOnlyByTheSessionHerdrNames() {
        let home = "/Users/me"
        let id = AgentSessionRef(source: "herdr:claude", agent: "claude", kind: "id", value: "6f1c2a")
        #expect(AgentTranscript.locate(agent: "claude", session: id, home: home) == .success(.claude(id: "6f1c2a")))
        #expect(AgentTranscript.locate(agent: "claude", session: nil, home: home) == .failure(.noSession))
        #expect(AgentTranscript.locate(agent: "opencode", session: id, home: home) == .success(.claude(id: "6f1c2a")))
        let opencode = AgentSessionRef(source: "herdr:opencode", agent: "opencode", kind: "id", value: "x1")
        #expect(AgentTranscript.locate(agent: "opencode", session: opencode, home: home) == .failure(.notRead(agent: "opencode")))
        #expect(AgentTranscript.Unread.notRead(agent: "opencode").reason == "Next Term reads no opencode transcript yet.")
        // A path only under home; an id that could be a pattern is none.
        let outside = AgentSessionRef(source: "herdr:codex", agent: "codex", kind: "path", value: "/etc/passwd")
        #expect(AgentTranscript.locate(agent: "codex", session: outside, home: home) == .failure(.outsideHome))
        let sneaky = AgentSessionRef(source: "herdr:codex", agent: "codex", kind: "path", value: "/Users/me/../other/x.jsonl")
        #expect(AgentTranscript.locate(agent: "codex", session: sneaky, home: home) == .failure(.outsideHome))
        #expect(AgentTranscript.locate(agent: "codex", session: sneaky, home: nil) == .failure(.outsideHome))
        let inside = AgentSessionRef(source: "herdr:codex", agent: "codex", kind: "path", value: "/Users/me/.codex/sessions/r.jsonl")
        #expect(AgentTranscript.locate(agent: "codex", session: inside, home: home) == .success(.path("/Users/me/.codex/sessions/r.jsonl", kind: .codex)))
        let glob = AgentSessionRef(source: "herdr:claude", agent: "claude", kind: "id", value: "*")
        #expect(AgentTranscript.locate(agent: "claude", session: glob, home: home) == .failure(.badID))
        #expect(AgentTranscript.locate(agent: .codex, sessionID: "0199-ab") == .success(.codex(id: "0199-ab")))
        #expect(AgentTranscript.locate(agent: .gemini, sessionID: "x") == .failure(.notRead(agent: "Gemini CLI")))
    }

    @Test func twoMatchesAreAmbiguousAndTheHostsAnswerReads() throws {
        #expect(AgentTranscript.only(["/a", "/b"]) == .failure(.ambiguous) && AgentTranscript.only([]) == .failure(.none))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-transcript-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for folder in ["-Users-me-api", "-Users-me-web"] {
            try FileManager.default.createDirectory(atPath: home + "/.claude/projects/" + folder, withIntermediateDirectories: true)
        }
        try "{}\n".write(toFile: home + "/.claude/projects/-Users-me-api/6f1c2a.jsonl", atomically: true, encoding: .utf8)
        #expect(AgentTranscript.only(AgentTranscript.candidates(.claude(id: "6f1c2a"), home: home)).map { ($0 as NSString).lastPathComponent } == .success("6f1c2a.jsonl"))
        try "{}\n".write(toFile: home + "/.claude/projects/-Users-me-web/6f1c2a.jsonl", atomically: true, encoding: .utf8)
        #expect(AgentTranscript.only(AgentTranscript.candidates(.claude(id: "6f1c2a"), home: home)) == .failure(.ambiguous))
        // The host's script, run here under /bin/sh with that home: two files, so none is read.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", AgentTranscript.script(.claude(id: "6f1c2a"))]
        shell.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        #expect(AgentTranscript.answer(said).map { $0.size } == .failure(.ambiguous))
        // One file: its size and tail come back.
        try FileManager.default.removeItem(atPath: home + "/.claude/projects/-Users-me-web/6f1c2a.jsonl")
        let again = Process()
        again.executableURL = URL(fileURLWithPath: "/bin/sh")
        again.arguments = ["-c", AgentTranscript.script(.claude(id: "6f1c2a"))]
        again.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        again.standardOutput = pipe
        try again.run()
        let one = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        again.waitUntilExit()
        let read = try AgentTranscript.answer(one).get()
        #expect(read.size == 3 && read.tail == Data("{}\n".utf8))
        // Asked again with that size: no tail comes back.
        #expect(AgentTranscript.script(.claude(id: "6f1c2a"), knownSize: 3).contains("!= '3'"))
        #expect(try AgentTranscript.answer("\(RemoteShell.marker)\ncount\t1\nsize\t3\nend\n").get().tail == nil)
        // On this Mac: the tail of the file, and its size.
        let local = try #require(AgentTranscript.readTail(home + "/.claude/projects/-Users-me-api/6f1c2a.jsonl"))
        #expect(local.size == 3 && local.tail == Data("{}\n".utf8))
        // A host's path is checked there, under its home.
        #expect(AgentTranscript.script(.path("/home/me/x.jsonl", kind: .codex)).contains(#"case $nt_f in "$HOME"/*)"#))
    }

    @Test func aStoredKeyInATurnComesBackMasked() {
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let shown = AgentTranscript.text([AgentTranscript.Turn(role: .user, text: "use \(value) for the API")], agent: "claude", mask: mask)
        #expect(shown == "You: use ••• for the API")
    }
}
