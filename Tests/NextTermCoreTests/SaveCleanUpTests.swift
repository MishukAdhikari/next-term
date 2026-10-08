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
        #expect(cleaned("a\n   \nb \r\nc  \nd") == "a\n\nb\r\nc\nd\n")
    }

    @Test func oldMacAndMixedLineEndingsStay() {
        // A file with "\r" line endings (the editor holds it as it is): every line trimmed, and nothing to add when
        // it already ends with a line break.
        #expect(cleaned("a  \rb  \r") == "a\rb\r")
        // The newline added is the line break the line before ends with.
        #expect(cleaned("a  \rb  ") == "a\rb\r")
        #expect(cleaned("a\nb \r\nc") == "a\nb\r\nc\r\n")
        #expect(cleaned("one line ") == "one line\n")
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

    @Test func manyReplacementsBecomeOne() {
        let text = (1...300).map { "line \($0)  " }.joined(separator: "\n") as NSString
        let replacements = SaveCleanUp.replacements(in: text, trimTrailingWhitespace: true, insertFinalNewline: true)
        #expect(replacements.count == 300)
        let one = SaveCleanUp.collapsed(replacements, in: text)
        #expect(one.count == 1 && one.first?.range.location == 6)
        #expect(SaveCleanUp.applying(one, to: text) == SaveCleanUp.applying(replacements, to: text))
        #expect(SaveCleanUp.applying(one, to: text).hasSuffix("line 300\n"))
        // A few stay as they are.
        let few = SaveCleanUp.replacements(in: "a \nb ", trimTrailingWhitespace: true, insertFinalNewline: false)
        #expect(SaveCleanUp.collapsed(few, in: "a \nb ") == few)
    }

    @Test func aLongFileIsCleanedInOnePass() {
        // 100,000 lines with spaces at the end: built one replacement after another, not by moving the rest of the
        // file along for each line, which took seconds.
        let lines = (1...100_000).map { "line \($0)" }
        let text = lines.map { $0 + "  " }.joined(separator: "\n") as NSString
        let started = Date()
        let replacements = SaveCleanUp.replacements(in: text, trimTrailingWhitespace: true, insertFinalNewline: true)
        let one = SaveCleanUp.collapsed(replacements, in: text)
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(one.count == 1)
        #expect(SaveCleanUp.applying(one, to: text) == lines.joined(separator: "\n") + "\n")
    }

    @Test func markdownAndPatchesKeepTheirSpaces() {
        for name in ["README.md", "notes.markdown", "page.MDX", "fix.diff", "0001-fix.patch"] { #expect(!SaveCleanUp.trims(fileNamed: name)) }
        for name in ["main.swift", "Makefile", ".env", "md"] { #expect(SaveCleanUp.trims(fileNamed: name)) }
    }
}
