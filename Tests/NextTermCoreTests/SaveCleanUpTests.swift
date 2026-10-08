import Foundation
import Testing
@testable import NextTermCore

@Suite struct SaveCleanUpTests {
    func cleaned(_ text: String, trim: Bool = true, newline: Bool = true) -> String {
        let replacements = SaveCleanUp.replacements(in: text as NSString, trimTrailingWhitespace: trim, insertFinalNewline: newline)
        return SaveCleanUp.applying(replacements, to: text as NSString)
    }

    @Test func trimsEveryLineAndEndsWithANewline() {
        #expect(cleaned("one  \ntwo\t\n\tthree \t") == "one\ntwo\n\tthree\n")
        #expect(cleaned("one  \ntwo", newline: false) == "one\ntwo")
        #expect(cleaned("one  \ntwo", trim: false) == "one  \ntwo\n")
        // Leading indentation and spaces inside a line stay.
        #expect(cleaned("    a  b   \n") == "    a  b\n")
        // Lines of spaces only become empty; a CR kept at a line's end (mixed endings) stays, after the trim.
        #expect(cleaned("a\n   \nb \r\nc") == "a\n\nb\r\nc\n")
    }

    @Test func aFinalNewlineOnlyAfterText() {
        #expect(cleaned("", trim: false) == "")
        #expect(cleaned("\n") == "\n")
        #expect(cleaned("done\n") == "done\n")
        // The last line holds only spaces: trimmed, no newline added (as VS Code does).
        #expect(cleaned("done\n   ") == "done\n")
        #expect(cleaned("done\n   ", trim: false) == "done\n   ")
        // Spaces right at the end and the newline are one replacement.
        let replacements = SaveCleanUp.replacements(in: "end  ", trimTrailingWhitespace: true, insertFinalNewline: true)
        #expect(replacements == [SaveCleanUp.Replacement(range: NSRange(location: 3, length: 2), text: "\n")])
    }

    @Test func nothingToDoIsNoReplacement() {
        #expect(SaveCleanUp.replacements(in: "clean\nfile\n", trimTrailingWhitespace: true, insertFinalNewline: true).isEmpty)
        #expect(SaveCleanUp.replacements(in: "a  \n", trimTrailingWhitespace: false, insertFinalNewline: false).isEmpty)
        // Text outside the Basic Multilingual Plane is measured as the editor measures it (UTF-16).
        #expect(cleaned("😀 \nü\t") == "😀\nü\n")
    }

    @Test func theCaretStaysOnItsText() {
        let text: NSString = "ab  \ncd  \nef"
        let replacements = SaveCleanUp.replacements(in: text, trimTrailingWhitespace: true, insertFinalNewline: true)
        // After "cd" (offset 7) the caret moves back by the two spaces trimmed on the first line.
        #expect(SaveCleanUp.location(7, after: replacements) == 5)
        // Inside or after trimmed spaces: to where they began, after "cd".
        #expect(SaveCleanUp.location(8, after: replacements) == 5)
        #expect(SaveCleanUp.location(9, after: replacements) == 5)
        // At the very end: after "ef", before the newline added there.
        #expect(SaveCleanUp.location(text.length, after: replacements) == 8)
        #expect(SaveCleanUp.applying(replacements, to: text) == "ab\ncd\nef\n")
    }

    @Test func markdownAndPatchesKeepTheirSpaces() {
        for name in ["README.md", "notes.markdown", "page.MDX", "fix.diff", "0001-fix.patch"] { #expect(!SaveCleanUp.trims(fileNamed: name)) }
        for name in ["main.swift", "Makefile", ".env", "md"] { #expect(SaveCleanUp.trims(fileNamed: name)) }
    }
}
