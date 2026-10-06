import Foundation
import Testing
@testable import NextTermCore

@Suite struct AgentPromptTests {
    @Test func referencesPerDialect() {
        let item = ContextItem(path: "src/auth/login.ts", lines: 42...58)
        #expect(AgentPrompt.reference(item, dialect: .atHash) == "@src/auth/login.ts#L42-58")
        #expect(AgentPrompt.reference(item, dialect: .plain) == "src/auth/login.ts:42-58")
        #expect(AgentPrompt.reference(item, dialect: .atProse) == "@src/auth/login.ts (lines 42-58)")
        #expect(AgentPrompt.reference(ContextItem(path: "a.ts", lines: 7...7), dialect: .atHash) == "@a.ts#L7")
        #expect(AgentPrompt.reference(ContextItem(path: "src/db", isFolder: true), dialect: .atHash) == "@src/db/")
        #expect(AgentPrompt.reference(ContextItem(path: "my dir/a.ts", lines: 1...2), dialect: .atHash) == "@\"my dir/a.ts\" (lines 1-2)")
        #expect(AgentDialect.forProgram("claude") == .atHash && AgentDialect.forProgram("codex") == .plain && AgentDialect.forProgram("whatever") == .plain)
    }

    @Test func claudeSegmentsMatchTheSpec() {
        let segs = AgentPrompt.segments(instruction: "Refactor this to use async/await",
                                        items: [ContextItem(path: "src/auth/login.ts", lines: 42...58)], dialect: .atHash)
        #expect(segs == ["Refactor this to use async/await @src/auth/login.ts#L42-58 "]) // trailing space after the mention
        #expect(AgentPrompt.fitsInline(segs[0], dialect: .atHash))
    }

    @Test func genericSegments() {
        let one = AgentPrompt.segments(instruction: "Refactor this", items: [ContextItem(path: "a.go", lines: 3...9)], dialect: .plain)
        #expect(one == ["Refactor this: a.go:3-9"])
        let many = AgentPrompt.segments(instruction: "Why does login fail?", items: [
            ContextItem(path: "src/a.ts", lines: 1...2), ContextItem(path: "src/db", isFolder: true),
        ], dialect: .plain)
        #expect(many == ["Why does login fail?\n\nContext:\n- src/a.ts:1-2\n- src/db/ (folder)"])
    }

    @Test func codeGoesInASecondPaste() {
        let item = ContextItem(path: "x.swift", lines: 40...45, note: "unstaged change, +1 −1", code: "-a\n+b", language: "diff")
        let segs = AgentPrompt.segments(instruction: "Why?", items: [item], dialect: .atHash)
        #expect(segs.count == 2)
        #expect(segs[0] == "Why? @x.swift#L40-45 (unstaged change, +1 −1) ")
        #expect(segs[1] == "```diff\n-a\n+b\n```")
        // Code containing a fence gets a longer fence.
        let fenced = AgentPrompt.segments(instruction: "x", items: [ContextItem(path: "r.md", code: "```\nhi\n```")], dialect: .plain)
        #expect(fenced[1].hasPrefix("````text\n") && fenced[1].hasSuffix("\n````"))
    }

    @Test func neverStartsWithACommandMarker() {
        for marker in ["!rm -rf", "/clear", "$ ls", "& bg", "? help", "# remember"] {
            let segs = AgentPrompt.segments(instruction: marker, items: [], dialect: .atHash)
            #expect(segs[0].hasPrefix("Note: "), "\(marker)")
        }
        #expect(AgentPrompt.segments(instruction: "", items: [ContextItem(path: "/abs/path.ts")], dialect: .plain)[0] == "Note: /abs/path.ts")
    }

    @Test func sanitizeRemovesEverythingThatCouldAct() {
        let hostile = "ok\u{1b}[201~\u{15}touch SMUGGLED\r\nnext\u{202E}rev\u{200B}zw\u{E0041}tag\u{9B}c1 👨‍👩‍👧"
        let clean = AgentPrompt.sanitize(hostile)
        #expect(!clean.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x15 || $0.value == 0x0D })
        #expect(clean == "ok[201~touch SMUGGLED\nnextrevzwtagc1 👨‍👩‍👧") // ZWJ emoji kept
    }

    @Test func inlineLimits() {
        #expect(!AgentPrompt.fitsInline(String(repeating: "x", count: 801), dialect: .atHash))
        #expect(!AgentPrompt.fitsInline("a\nb\nc\nd", dialect: .atHash))
        #expect(AgentPrompt.fitsInline(String(repeating: "x", count: 5000), dialect: .plain))
        #expect(AgentPrompt.isTooLargeToInline(String(repeating: "line\n", count: 201)))
        #expect(!AgentPrompt.isTooLargeToInline("small"))
    }
}
