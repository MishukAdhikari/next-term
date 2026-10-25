import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// The handoff parser reads whatever an agent wrote: the four sections under any heading style, Next's list items as
/// tasks for tomorrow, and an odd or missing shape said plainly, with the text kept as it is.
@Suite struct HandoffTests {
    static let full = """
        # Handoff

        ## Done
        - Fixed the login redirect

        ## Next
        - Add a test for the expired token
        - Move the retry into the client
        - Ask design about the error page

        ## Open questions
        - Should the token live a day?

        ## How to resume
        Run `swift test` and open LoginFlow.swift.
        """

    func texts(_ items: [Handoff.Item]) -> [String] { items.map(\.text) }

    @Test func theFullShapeGivesTheNextItemsInOrder() {
        let handoff = Handoff.parse(Self.full)
        #expect(handoff.shape == .full)
        #expect(texts(handoff.next) == ["Add a test for the expired token", "Move the retry into the client",
                                        "Ask design about the error page"])
        #expect(handoff.next.allSatisfy { !$0.done })
        #expect(texts(handoff.items(in: .done)) == ["Fixed the login redirect"])
        #expect(texts(handoff.items(in: .openQuestions)) == ["Should the token live a day?"])
        #expect(handoff.lines(in: .howToResume) == ["Run `swift test` and open LoginFlow.swift."])
        #expect(handoff.raw == Self.full && !handoff.truncated)
        // The title above the sections is no section of its own.
        #expect(handoff.other.isEmpty)
    }

    @Test func anyHeadingStyleFindsNext() {
        for heading in ["### next steps", "**Next**", "Next:", "NEXT", "## Next:", "__To do__", "# Follow-ups"] {
            let text = heading == "NEXT" ? "# NEXT\n- a\n" : "\(heading)\n- a\n"
            let handoff = Handoff.parse(text)
            #expect(texts(handoff.next) == ["a"], "\(heading)")
            #expect(handoff.shape == .partial(missing: [.done, .openQuestions, .howToResume]), "\(heading)")
        }
        // A sentence ending in a colon is text, not a heading.
        let prose = Handoff.parse("## Done\nChanged the following:\n- the parser\n## Next\n- b\n")
        #expect(texts(prose.items(in: .done)) == ["the parser"] && texts(prose.next) == ["b"])
        // An unknown heading is kept with its text, and ends the section above it.
        let odd = Handoff.parse("## Next\n- a\n## Notes\n- not a task\n")
        #expect(texts(odd.next) == ["a"])
        #expect(odd.other == [Handoff.Other(heading: "Notes", lines: ["- not a task"])])
    }

    @Test func listMarkersAndBoxes() {
        let handoff = Handoff.parse("## Next\n- [ ] a\n- [x] b\n1. c\n* d\n+ e\n2) f\n- [X] g\n")
        #expect(texts(handoff.next) == ["a", "b", "c", "d", "e", "f", "g"])
        #expect(handoff.next.map(\.done) == [false, true, false, false, false, false, true])
    }

    @Test func wrappedAndNestedItems() {
        let text = "## Next\n- a long item\n  that wraps here\n\tand here\n  - e\n- f\n\n  after a blank line\n"
        let handoff = Handoff.parse(text)
        #expect(texts(handoff.next) == ["a long item that wraps here and here", "e", "f"])
    }

    @Test func onlyDoneIsPartialWithNoItems() {
        let text = "## Done\n- shipped it\n"
        let handoff = Handoff.parse(text)
        #expect(handoff.shape == .partial(missing: [.next, .openQuestions, .howToResume]))
        #expect(handoff.next.isEmpty && handoff.raw == text)
    }

    @Test func emptyNoHeadingAndProse() {
        let empty = Handoff.parse("")
        #expect(empty.shape == .none && empty.next.isEmpty && empty.raw.isEmpty)
        let plain = Handoff.parse("I did some things.\n- and a list\n")
        #expect(plain.shape == .none && plain.next.isEmpty)
        let prose = Handoff.parse("## Next\nWrite the migration.\n\nThen review the API.\n")
        #expect(texts(prose.next) == ["Write the migration.", "Then review the API."])
        // With one list line, the prose beside it is not an item.
        let mixed = Handoff.parse("## Next\nSome words first.\n- the task\n")
        #expect(texts(mixed.next) == ["the task"])
    }

    @Test func longItemsAreCutAtAWordAndDuplicatesKeepOne() {
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let handoff = Handoff.parse("## Next\n- \(words)\n- same\n- same\n- \n- [ ]\n")
        let first = handoff.next[0].text
        #expect(first.count <= Handoff.itemLength && first.hasSuffix("word…"))
        #expect(texts(Array(handoff.next.dropFirst())) == ["same"])
    }

    @Test func headingsInsideCodeAreText() {
        let text = "## How to resume\n```\n## Next\n- not a task\n```\n## Next\n- real\n"
        let handoff = Handoff.parse(text)
        #expect(texts(handoff.next) == ["real"])
        #expect(handoff.lines(in: .howToResume) == ["```", "## Next", "- not a task", "```"])
    }

    @Test func subheadingsUnderNextStayInIt() {
        let grouped = Handoff.parse("## Next\n### Backend\n- a\n### Frontend\n- b\n## Open questions\n- c\n")
        #expect(texts(grouped.next) == ["a", "b"])
        #expect(grouped.other.isEmpty)
        #expect(texts(grouped.items(in: .openQuestions)) == ["c"])
        #expect(grouped.lines(in: .next) == ["### Backend", "- a", "### Frontend", "- b"])
        // A bold line alone under a `#` heading is a group in it too.
        let bold = Handoff.parse("# Next\n**API**\n- a\n__UI__\n- b\n")
        #expect(texts(bold.next) == ["a", "b"] && bold.other.isEmpty)
        // A group label is never an item, even with no list lines.
        let prose = Handoff.parse("## Next\n### Backend\nWrite the migration.\n")
        #expect(texts(prose.next) == ["Write the migration."])
        // An unknown heading as high as the section's, or higher, still ends it.
        let same = Handoff.parse("### Next\n- a\n## Notes\n- n\n### Also\n- m\n")
        #expect(texts(same.next) == ["a"])
        #expect(same.other.map(\.heading) == ["Notes", "Also"])
        let boldEnds = Handoff.parse("**Next**\n- a\n**Notes**\n- n\n")
        #expect(texts(boldEnds.next) == ["a"] && boldEnds.other.map(\.heading) == ["Notes"])
        // A known heading below a section still starts its own.
        let known = Handoff.parse("## Next\n- a\n### Done\n- d\n")
        #expect(texts(known.next) == ["a"] && texts(known.items(in: .done)) == ["d"])
    }

    @Test func inlineMarkdownIsKeptAsTyped() {
        let handoff = Handoff.parse("## Next\n- Fix **the** `parser` in [Docs](x.md)\n")
        #expect(texts(handoff.next) == ["Fix **the** `parser` in [Docs](x.md)"])
    }
}

/// Reading a handoff file: the first 256 KB of a plain file, never through a link, masked before anything holds it.
@Suite struct HandoffFileTests {
    func folder() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-handoff-file-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ data: Data, _ path: String) { FileManager.default.createFile(atPath: path, contents: data) }

    @Test func aFileIsReadMaskedAndParsed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(Data("## Next\n- rotate sk-ant-EXAMPLEKEY123\n".utf8), dir + "/h.md")
        let key = SymmetricKey(size: .bits256)
        let marks = SecretMask.marks(for: SecretBytes(utf8: "sk-ant-EXAMPLEKEY123"), key: key)
        let read = HandoffFile.read(URL(fileURLWithPath: dir + "/h.md"), mask: SecretMask(key: key, marks: marks))
        guard case .text(let handoff) = read else { Issue.record("\(read)"); return }
        #expect(handoff.next.map(\.text) == ["rotate •••"])
        #expect(!handoff.raw.contains("sk-ant"))
    }

    @Test func overTheLimitIsCutAndSaysSo() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Over 300 KB of distinct items.
        let filler = String(repeating: "x", count: 90)
        let lines: [String] = (0..<3_100).map { "- é \(filler) \($0)\n" }
        let body = "## Next\n" + lines.joined()
        write(Data(body.utf8), dir + "/big.md")
        let read = HandoffFile.read(URL(fileURLWithPath: dir + "/big.md"), mask: .empty)
        guard case .text(let handoff) = read else { Issue.record("\(read)"); return }
        #expect(handoff.truncated)
        #expect(handoff.raw.utf8.count <= HandoffFile.limit && handoff.raw.utf8.count > HandoffFile.limit - 4)
        #expect(handoff.next.count > 2_000)
        let small = HandoffFile.read(URL(fileURLWithPath: dir + "/big.md"), mask: .empty, limit: 10)
        guard case .text(let cut) = small else { Issue.record("\(small)"); return }
        #expect(cut.truncated && cut.raw == "## Next\n- ")
        // A letter cut in half is left out, not read as "not text".
        let half = HandoffFile.read(URL(fileURLWithPath: dir + "/big.md"), mask: .empty, limit: 11)
        guard case .text(let halved) = half else { Issue.record("\(half)"); return }
        #expect(halved.raw == "## Next\n- ")
    }

    @Test func aStoredKeyAcrossTheCutIsLeftOutWhole() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let value = "sk-ant-Q7vRm2Lp9XwT4nBz8KcJ5hYd3GfS6aEu"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        // The key starts 10 bytes before the cut, on a Next line, and the file goes on after it.
        let head = "## Next\n"
        let lead = "- rotate "
        let fillerCount = HandoffFile.limit - 10 - head.utf8.count - lead.utf8.count - 1
        let filler = String(repeating: "x", count: fillerCount) + "\n"
        let body = head + filler + lead + value + "\n" + String(repeating: "- more\n", count: 100)
        #expect(body.utf8.count > HandoffFile.limit)
        write(Data(body.utf8), dir + "/h.md")
        let read = HandoffFile.read(URL(fileURLWithPath: dir + "/h.md"), mask: mask)
        guard case .text(let handoff) = read else { Issue.record("\(read)"); return }
        #expect(handoff.truncated)
        #expect(handoff.raw.utf8.count <= HandoffFile.limit)
        for part in ["sk-ant", "Q7vR", String(value.prefix(10))] {
            #expect(!handoff.raw.contains(part), "\(part)")
            #expect(!handoff.next.contains { $0.text.contains(part) }, "\(part)")
        }
        // Read whole, the same key is masked where it is.
        let whole = HandoffFile.read(URL(fileURLWithPath: dir + "/h.md"), mask: mask, limit: body.utf8.count)
        guard case .text(let all) = whole else { Issue.record("\(whole)"); return }
        #expect(!all.truncated && !all.raw.contains("sk-ant") && all.raw.contains("- rotate •••"))
    }

    @Test func notTextNotThereAndLinksAreSaidPlainly() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(Data([0x23, 0x00, 0xFF, 0xFE, 0x41]), dir + "/bin.md")
        write(Data([0xC3, 0x28, 0x41]), dir + "/bad.md")
        write(Data("## Next\n- a\n".utf8), dir + "/real.md")
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.md", withDestinationPath: dir + "/real.md")
        try FileManager.default.createDirectory(atPath: dir + "/folder.md", withIntermediateDirectories: false)
        func read(_ name: String) -> HandoffFile.Read {
            HandoffFile.read(URL(fileURLWithPath: dir + "/" + name), mask: .empty)
        }
        #expect(read("bin.md") == .notText)
        #expect(read("bad.md") == .notText)
        #expect(read("missing.md") == .missing)
        #expect(read("link.md") == .notPlainFile)
        #expect(read("folder.md") == .notPlainFile)
        guard case .text(let handoff) = read("real.md") else { Issue.record("real.md"); return }
        #expect(handoff.next.map(\.text) == ["a"])
    }
}

/// The handoff folder is checked again at every read: a folder an agent made into a link after the sheet opened is
/// never read through.
@Suite struct HandoffFolderReadTests {
    @Test func aFolderMadeALinkAfterTheSheetOpenedIsNotReadThrough() throws {
        let base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-handoff-dir-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let project = base + "/p"
        let elsewhere = base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: elsewhere + "/handoffs", withIntermediateDirectories: true)
        let text = Data("## Next\n- a\n".utf8)
        FileManager.default.createFile(atPath: elsewhere + "/handoffs/h.md", contents: text)
        #expect(HandoffFile.folderIsPlain("docs/handoffs", in: project))
        try FileManager.default.createSymbolicLink(atPath: project + "/docs", withDestinationPath: elsewhere)
        #expect(!HandoffFile.folderIsPlain("docs/handoffs", in: project))
        let linked = HandoffFile.read("docs/handoffs/h.md", folder: "docs/handoffs", in: project, mask: .empty)
        #expect(linked == .notPlainFile)
        try FileManager.default.removeItem(atPath: project + "/docs")
        try FileManager.default.createDirectory(atPath: project + "/docs/handoffs", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: project + "/docs/handoffs/h.md", contents: text)
        let plain = HandoffFile.read("docs/handoffs/h.md", folder: "docs/handoffs", in: project, mask: .empty)
        guard case .text(let handoff) = plain else { Issue.record("\(plain)"); return }
        #expect(handoff.next.map(\.text) == ["a"])
        // Only a name directly in the folder is read.
        let other = HandoffFile.read("docs/h.md", folder: "docs/handoffs", in: project, mask: .empty)
        #expect(other == .notPlainFile)
    }
}
