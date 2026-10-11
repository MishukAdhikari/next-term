import Foundation
import Testing
@testable import NextTermCore

/// Rollback Lines: which changes a caret or a selection takes, and the one edit that puts them back as the last
/// commit has them, the changes beside them left as they are.
@Suite struct LineRollbackTests {
    /// The text once the changes `lines` touch are rolled back, and what the edit selects.
    func rolledBack(_ baseline: String, _ current: String, lines: ClosedRange<Int>) throws -> (text: String, selected: String)? {
        let git = try #require(GitRunner.locateGit())
        let diff = try #require(GitRunner.diff(old: baseline, new: current, git: git, context: 0))
        guard let edit = LineRollback.edit(LineRollback.touched(diff, lines: lines), current: current, baseline: baseline) else { return nil }
        let text = (current as NSString).replacingCharacters(in: edit.range, with: edit.text)
        return (text, (text as NSString).substring(with: edit.selection))
    }

    let baseline = "a\nb\nc\nd\ne\nf\n"

    @Test func aChangedLineComesBackAlone() throws {
        // b changed, d changed: the caret on b takes b only.
        let result = try #require(try rolledBack(baseline, "a\nB\nc\nD\ne\nf\n", lines: 1...1))
        #expect(result.text == "a\nb\nc\nD\ne\nf\n")
        #expect(result.selected == "b")
    }

    @Test func aSelectionAcrossTwoChangesTakesBoth() throws {
        let result = try #require(try rolledBack(baseline, "a\nB\nc\nD\ne\nf\n", lines: 1...3))
        #expect(result.text == baseline)
        #expect(result.selected == "b\nc\nd")
    }

    @Test func addedLinesGoAndDeletedOnesComeBack() throws {
        // Two lines added after c: the caret on either takes both away.
        #expect(try rolledBack(baseline, "a\nb\nc\nnew\nnewer\nd\ne\nf\n", lines: 4...4)?.text == baseline)
        // d and e deleted: the mark sits between c and f, and the line above or below it brings them back.
        let deleted = "a\nb\nc\nf\n"
        #expect(try rolledBack(baseline, deleted, lines: 2...2)?.text == baseline)
        #expect(try rolledBack(baseline, deleted, lines: 3...3)?.text == baseline)
        #expect(try rolledBack(baseline, deleted, lines: 0...0) == nil)
        // The first line deleted: the line now at the top brings it back.
        #expect(try rolledBack(baseline, "b\nc\nd\ne\nf\n", lines: 0...0)?.text == baseline)
    }

    @Test func aChangeThatGrewOrShrank() throws {
        #expect(try rolledBack(baseline, "a\nB1\nB2\nB3\nc\nd\ne\nf\n", lines: 2...2)?.text == baseline)
        #expect(try rolledBack(baseline, "a\nBC\nd\ne\nf\n", lines: 1...1)?.text == baseline)
    }

    @Test func theLastLineAndItsNewline() throws {
        // The last line changed and its newline dropped: both come back.
        #expect(try rolledBack(baseline, "a\nb\nc\nd\ne\nF", lines: 5...5)?.text == baseline)
        // Lines added after a last line that had no newline.
        #expect(try rolledBack("a\nb", "a\nb\nc\n", lines: 2...2)?.text == "a\nb")
    }

    @Test func unchangedLinesTakeNothing() throws {
        #expect(try rolledBack(baseline, "a\nB\nc\nd\ne\nf\n", lines: 4...5) == nil)
    }

    @Test func linesKeepTheirEndingsAsGitCountsThem() {
        #expect(LineRollback.lines(of: "a\r\nb\nc") == ["a\r\n", "b\n", "c"])
        #expect(LineRollback.lines(of: "") == [])
        #expect(LineRollback.lineCount([]) == 0)
    }
}
