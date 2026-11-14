import Foundation
import Testing
@testable import NextTermCore

@Suite struct ReviewCommentsTests {
    let file = ["a", "b", "c", "d", "e", "f"]

    func comment(_ lines: ClosedRange<Int>, _ quoted: String, inFile: Bool = true) -> ReviewComment {
        ReviewComment(path: "/repo/src/x.swift", lines: lines, quoted: quoted, note: "Rename this", language: "swift", inFile: inFile)
    }

    @Test func staysWhereItsLinesStill() {
        let moved = ReviewComments.reanchor(comment(3...4, "c\nd"), fileLines: file)
        #expect(moved.lines == 3...4)
        #expect(!moved.outdated)
    }

    @Test func followsItsLinesWhenTheyMove() {
        let moved = ReviewComments.reanchor(comment(3...4, "c\nd"), fileLines: ["new", "new"] + file)
        #expect(moved.lines == 5...6)
        #expect(!moved.outdated)
    }

    @Test func takesTheNearestCopy() {
        let lines = ["x", "y", "a", "x", "y", "b", "c", "d", "x", "y"]
        #expect(ReviewComments.reanchor(comment(8...9, "x\ny"), fileLines: lines).lines == 9...10)
        #expect(ReviewComments.reanchor(comment(4...5, "x\ny"), fileLines: lines).lines == 4...5)
    }

    @Test func outdatedWhenItsLinesAreGone() {
        let gone = ReviewComments.reanchor(comment(3...4, "c\nd"), fileLines: ["a", "b", "C", "d"])
        #expect(gone.outdated)
        #expect(gone.lines == 3...4)
        #expect(ReviewComments.reanchor(comment(3...4, "c\nd"), fileLines: nil).outdated)
        // Back again: no longer outdated.
        #expect(!ReviewComments.reanchor(gone, fileLines: file).outdated)
    }

    @Test func gapsAnchorByTheFirstShownLines() {
        let moved = ReviewComments.reanchor(comment(2...6, "b\nc\n⋯\nf"), fileLines: ["z"] + file)
        #expect(moved.lines == 3...7)
    }

    @Test func removedLinesStayAsText() {
        let removed = comment(3...4, "old", inFile: false)
        #expect(ReviewComments.reanchor(removed, fileLines: file) == removed)
    }

    @Test func linesOfText() {
        #expect(ReviewComments.lines(of: "a\r\nb\n") == ["a", "b"])
        #expect(ReviewComments.lines(of: "") == [])
    }

    @Test func prompt() {
        var outdated = comment(7...7, "g")
        outdated.outdated = true
        outdated.note = "Why?\u{1b}[201~"
        let text = ReviewComments.prompt([comment(3...4, "c\nd"), comment(2...2, "old", inFile: false), outdated], relativeTo: "/repo")
        #expect(text == """
        Review comments on your changes:

        1. src/x.swift:3-4
        ```swift
        c
        d
        ```
        Rename this

        2. src/x.swift, removed lines (were 2)
        ```swift
        old
        ```
        Rename this

        3. src/x.swift:7 (outdated: these lines have changed since)
        ```swift
        g
        ```
        Why?[201~
        """)
        #expect(ReviewComments.prompt([comment(1...1, "```")], relativeTo: "/other").contains("1. /repo/src/x.swift:1\n````swift\n```\n````"))
        #expect(ReviewComments.prompt([comment(1...1, "a")], relativeTo: "/repo").hasPrefix("Review comment on your changes:"))
    }

    @Test func emptyNoteMakesNoComment() {
        let selection = DiffSelection(side: .new, text: "a", linesText: "a", lines: 1...1, isInFile: true, changedOnly: true, start: nil, end: nil)
        let share = DiffShare(path: "/repo/a", selection: selection, holdsSecrets: false, isUncommitted: true, version: .workingTree, language: "text")
        #expect(ReviewComment(share: share, note: "  \n") == nil)
        #expect(ReviewComment(share: share, note: " fix ")?.note == "fix")
        #expect(ReviewComment(share: share, note: "fix")?.inFile == true)
    }
}
