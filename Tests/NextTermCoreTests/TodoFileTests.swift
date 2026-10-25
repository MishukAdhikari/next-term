import Foundation
import Testing
@testable import NextTermCore

/// A todo file's name and text: the slug in any script, the numbers a taken name gets, YAML's quotes, and the bytes of
/// the format's own example.
@Suite struct TodoFileTests {
    static let dhaka = TimeZone(identifier: "Asia/Dhaka")!
    /// 2026-10-15 18:42:07 in Dhaka (+06:00).
    static let created = Date(timeIntervalSince1970: 1_792_068_127)

    /// The example in docs/todo-files.md, as a draft.
    static var example: TaskDraft {
        let context = TaskContext(branch: "fix/login", tab: "api", agent: .claude, resume: "claude --resume 7f3c2a",
                                  addedBy: "Claude Code in tab “api”")
        let steps = [TaskDraft.Step(text: "Write the test for expired tokens"), TaskDraft.Step(text: "Ask Sam about the refresh endpoint")]
        return TaskDraft(title: "Finish the login fix", steps: steps, notes: "Branch is fix/login, see PR 512.",
                         scheduled: .day(TaskDay("2026-10-16")!), context: context)
    }

    static let exampleText = """
        ---
        created: 2026-10-15T18:42:07+06:00
        scheduled: 2026-10-16
        branch: "fix/login"
        tab: "api"
        agent: claude
        resume: "claude --resume 7f3c2a"
        added_by: "Claude Code in tab “api”"
        ---
        - [ ] Finish the login fix
          - [ ] Write the test for expired tokens
          - [ ] Ask Sam about the refresh endpoint

        Branch is fix/login, see PR 512.

        """

    @Test func theExampleRendersByteForByte() {
        #expect(TodoFile.timestamp(Self.created, timeZone: Self.dhaka) == "2026-10-15T18:42:07+06:00")
        let text = TodoFile.render(Self.example, created: Self.created, timeZone: Self.dhaka)
        #expect(text == Self.exampleText)
        #expect(Data(text.utf8) == Data(Self.exampleText.utf8) && !text.contains("\r") && text.hasSuffix(".\n"))
    }

    @Test func emptyKeysAreLeftOutAndTheProjectIsNamedOnlyOutsideIt() {
        var draft = TaskDraft(title: "Tidy up", steps: [])
        let plain = TodoFile.render(draft, created: Self.created, timeZone: Self.dhaka)
        #expect(plain == "---\ncreated: 2026-10-15T18:42:07+06:00\n---\n- [ ] Tidy up\n")
        // No day: no scheduled.
        #expect(!plain.contains("scheduled:"))
        draft.context = TaskContext(branch: "", tab: nil, addedBy: TaskContext.you)
        draft.steps = [TaskDraft.Step(text: "done already", done: true), TaskDraft.Step(text: "under it", depth: 1)]
        let outside = TodoFile.render(draft, created: Self.created, timeZone: TimeZone(secondsFromGMT: -12_600)!,
                                      outsideProject: (name: "next-term", path: "/Users/me/Code/next-term"))
        #expect(outside == """
            ---
            created: 2026-10-15T09:12:07-03:30
            project: "next-term"
            path: "/Users/me/Code/next-term"
            added_by: you
            ---
            - [ ] Tidy up
              - [x] done already
                - [ ] under it

            """)
        // UTC has its offset too, never Z.
        #expect(TodoFile.timestamp(Self.created, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-10-15T12:42:07+00:00")
    }

    @Test func aStoredKeyRendersAsTheMaskAndNeverAsItsValue() throws {
        let key = "ghp_Q2xPq8rT5vW9yZ1aB3cD"
        let mask: (String) -> String = { $0.replacingOccurrences(of: key, with: "•••") }
        var draft = try #require(TaskDraft.drafts(prompt: "Rotate \(key)\n- revoke it\n\ntoken was \(key)", mask: mask).first)
        draft.context = TaskContext(tab: "gh \(key)", resume: "claude --resume \(key)").masked(by: mask)
        let text = TodoFile.render(draft, created: Self.created, timeZone: Self.dhaka)
        #expect(!text.contains(key))
        #expect(text.contains("- [ ] Rotate •••\n") && text.contains("tab: \"gh •••\"") && text.hasSuffix("token was •••\n"))
    }

    @Test func valuesAreQuotedAsYAMLReadsThem() {
        #expect(TodoFile.quote("fix/login") == "\"fix/login\"")
        #expect(TodoFile.quote("say \"hi\"") == #""say \"hi\"""#)
        #expect(TodoFile.quote(#"C:\path"#) == #""C:\\path""#)
        #expect(TodoFile.quote("one\ntwo\tthree") == #""one\u000Atwo\u0009three""#)
        #expect(TodoFile.quote("a\u{2028}b\u{7F}") == #""a\u2028b\u007F""#)
        #expect(TodoFile.quote("“api” ✓") == "\"“api” ✓\"")
    }

    @Test func theSlugKeepsLettersOfAnyScript() {
        #expect(TodoFile.slug("Finish the login fix") == "finish-the-login-fix")
        #expect(TodoFile.slug("লগইন ঠিক করো") == "লগইন-ঠিক-করো")
        #expect(TodoFile.slug("修复 登录") == "修复-登录")
        #expect(TodoFile.slug("a/b:c?") == "abc")
        #expect(TodoFile.slug("  Fix  /  it \t now\n") == "fix-it-now")
        #expect(TodoFile.slug(#"Say "no" <to> *that* | \this"#) == "say-no-to-that-this")
        #expect(TodoFile.slug("Ask Sam about v2.1, then ship!") == "ask-sam-about-v2.1,-then-ship!")
        #expect(TodoFile.slug("") == "task" && TodoFile.slug("/:?*") == "task" && TodoFile.slug("\u{07}\u{1B}") == "task")
        // Precomposed, whatever the title's form: é is one character either way.
        #expect(TodoFile.slug("Cafe\u{301}") == "café" && TodoFile.slug("Cafe\u{301}").unicodeScalars.count == 4)
    }

    @Test func aLongTitleIsCutAtAWord() {
        let title = "Write the migration that moves every saved layout into the new format and checks it"
        #expect(title.count > 80)
        let slug = TodoFile.slug(title)
        #expect(slug == "write-the-migration-that-moves-every-saved-layout")
        #expect(slug.count <= TodoFile.slugLength)
        // One word longer than the whole is cut where it must be.
        let long = String(repeating: "a", count: 80)
        #expect(TodoFile.slug(long) == String(repeating: "a", count: 50))
        // In a script of many bytes a character, the name stays within its bytes too.
        let bangla = String(repeating: "ক্ষ ", count: 40)
        #expect(TodoFile.slug(bangla).utf8.count <= 200 && !TodoFile.slug(bangla).hasSuffix("-"))
    }

    @Test func aTakenNameGetsTheNextNumberUpTo99() {
        var taken: Set<String> = []
        let first = TodoFile.fileName(created: Self.created, title: "Finish the login fix", timeZone: Self.dhaka, taken: taken.contains)
        #expect(first == "2026-10-15-finish-the-login-fix.md")
        taken.insert(first ?? "")
        let second = TodoFile.fileName(created: Self.created, title: "Finish the login fix", timeZone: Self.dhaka, taken: taken.contains)
        #expect(second == "2026-10-15-finish-the-login-fix-2.md")
        for number in 2...99 { taken.insert("2026-10-15-finish-the-login-fix-\(number).md") }
        #expect(TodoFile.fileName(created: Self.created, title: "Finish the login fix", timeZone: Self.dhaka, taken: taken.contains) == nil)
        // The day is the user's own: late at night in Dhaka is the next morning in Kiritimati.
        let late = Date(timeIntervalSince1970: 1_792_086_400) // 2026-10-15 23:46:40 in Dhaka, 17:46 UTC
        #expect(TodoFile.fileName(created: late, title: "x", timeZone: Self.dhaka) { _ in false } == "2026-10-15-x.md")
        let zone = TimeZone(identifier: "Pacific/Kiritimati")!
        #expect(TodoFile.fileName(created: late, title: "x", timeZone: zone) { _ in false } == "2026-10-16-x.md")
    }
}
