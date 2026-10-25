import Foundation
import Testing
@testable import NextTermCore

/// docs/wrap-up.md says what Wrap Up types and how a handoff is read: its fenced request is the one HandoffRequest
/// types, byte for byte, its example handoff parses to the Next items it lists, and it holds nothing of anyone's Mac.
@Suite struct WrapUpDocTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func doc() throws -> String {
        try String(contentsOf: root.appendingPathComponent("docs/wrap-up.md"), encoding: .utf8)
    }

    /// The bodies of the fenced blocks with `language`, in order.
    static func fenced(_ text: String, _ language: String) -> [String] {
        var blocks: [String] = []
        var current: [String]?
        for line in text.components(separatedBy: "\n") {
            if current == nil, line == "```" + language {
                current = []
            } else if current != nil, line == "```" {
                blocks.append((current ?? []).joined(separator: "\n"))
                current = nil
            } else if current != nil {
                current?.append(line)
            }
        }
        return blocks
    }

    static let path = "docs/handoffs/2026-10-18-api-tab.md"

    @Test func theDocsRequestIsTheOneTypedByteForByte() throws {
        let request = try #require(HandoffRequest.text(path: Self.path))
        let shown = Self.fenced(try Self.doc(), "text")
        #expect(shown.first == request)
        #expect(HandoffRequest.version == 1, "The words changed: change the doc's request with them.")
    }

    @Test func theExampleHandoffParsesToTheItemsTheDocLists() throws {
        let doc = try Self.doc()
        let example = try #require(Self.fenced(doc, "markdown").first)
        let handoff = Handoff.parse(example)
        let items: [String] = [
            "Add a test for a cart with only free items",
            "Show the total with tax on the checkout page",
            "Ask the payments team about refunds over 30 days",
        ]
        #expect(handoff.shape == .full)
        #expect(handoff.next.map(\.text) == items)
        #expect(handoff.next.allSatisfy { !$0.done })
        // The doc lists them under the example, as the review would show them.
        let listed = "Its three Next items become three tasks:\n\n" + items.map { "- " + $0 }.joined(separator: "\n")
        #expect(doc.contains(listed))
    }

    @Test func theDocHoldsNoKeyHomeFolderOrAddress() throws {
        let doc = try Self.doc()
        for held in ["/Users/", "@gmail", "~/"] {
            #expect(!doc.contains(held), "\(held)")
        }
        // A key's prefix, not the end of a word such as "task-destinations".
        #expect(doc.range(of: "(?<![A-Za-z])sk-", options: .regularExpression) == nil)
        // The README and the destinations doc link it.
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let destinations = try String(contentsOf: Self.root.appendingPathComponent("docs/task-destinations.md"),
                                      encoding: .utf8)
        #expect(readme.contains("(docs/wrap-up.md)") && destinations.contains("(wrap-up.md)"))
        #expect(readme.contains("Wrap Up… (⌃⌘W)") && doc.contains("(⌃⌘W)"))
    }
}
