import Foundation
import Testing
@testable import NextTermCore

/// docs/todo-files.md is the format's own description: its example is what Next Term writes for that task, byte for
/// byte, so the document and the writer never drift apart.
@Suite struct TodoFileDocTests {
    @Test func theFormatDocumentsExampleIsWhatNextTermWrites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/todo-files.md"), encoding: .utf8)
        let start = try #require(doc.range(of: "```markdown\n"))
        let end = try #require(doc.range(of: "\n```", range: start.upperBound..<doc.endIndex))
        let example = String(doc[start.upperBound..<end.lowerBound]) + "\n"
        let written = TodoFile.render(TodoFileTests.example, created: TodoFileTests.created, timeZone: TodoFileTests.dhaka)
        #expect(example == written && example == TodoFileTests.exampleText)
        // The rules it states are the ones the writer keeps.
        #expect(doc.contains("at most \(TodoFile.slugLength) characters") && doc.contains("`<created yyyy-mm-dd>-<slug>.md`"))
        #expect(doc.contains("Next Term never edits `.gitignore`"))
    }
}
