import Foundation
import Testing
@testable import NextTermCore

/// docs/task-destinations.md says where tasks go: its Connect a Tracker lines are the ones the sheet types, byte for
/// byte, its list of trackers not listed yet is the catalog's, its table names every destination once, and it holds
/// no key or anything from a Mac.
@Suite struct TaskDestinationsDocTests {
    static func doc() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/task-destinations.md"), encoding: .utf8)
    }

    /// The text between `start` and the next `end` after it.
    static func section(_ doc: String, from start: String, to end: String) throws -> String {
        let from = try #require(doc.range(of: start))
        let to = doc.range(of: end, range: from.upperBound..<doc.endIndex)?.lowerBound ?? doc.endIndex
        return String(doc[from.upperBound..<to])
    }

    @Test func theTrackerLinesAreTheOnesTheSheetTypes() throws {
        let block = try Self.section(Self.doc(), from: "The lines, as they are typed:\n\n```sh\n", to: "\n```")
        var lines: [String] = []
        for tracker in TrackerLines.shown {
            for agent in TrackerLines.agents {
                if case .line(let text, _) = tracker.cell(for: agent) { lines.append(text) }
            }
        }
        #expect(block == lines.joined(separator: "\n"))
    }

    @Test func theTrackersNotListedAreTheCatalogsHeldOnes() throws {
        let part = try Self.section(Self.doc(), from: "### Not listed yet\n\n", to: "\n\n")
        let listed: [String] = part.split(separator: "\n").map { String($0.dropFirst(2)) }
        var held: [String] = []
        for tracker in TrackerLines.shown {
            for agent in TrackerLines.agents {
                // A pair with no line from either page says only that; one with a reason of its own is named.
                guard let why = tracker.cell(for: agent).reason, why != TrackerLines.noLine(tracker.name) else { continue }
                held.append("\(tracker.name) with \(agent.name): \(why)")
            }
        }
        held += TrackerLines.heldSummary
        #expect(listed == held)
    }

    @Test func theTableNamesEveryDestinationOnce() throws {
        let part = try Self.section(Self.doc(), from: "## What each destination gets\n", to: "\n## ")
        let rows: [String] = part.split(separator: "\n").map(String.init).filter { $0.hasPrefix("| ") }
        for kind in TaskDestination.Kind.allCases {
            let naming = rows.filter { $0.contains("| `\(kind.rawValue)` |") }
            #expect(naming.count == 1, "\(kind.rawValue)")
        }
        #expect(rows.count == TaskDestination.Kind.allCases.count + 1)
    }

    @Test func theDocHoldsNoKeyAndNothingFromAMac() throws {
        let doc = try Self.doc()
        for bad in ["ghp_", "glpat-", "/Users/", "@gmail", "xoxb-"] {
            #expect(!doc.contains(bad), "\(bad)")
        }
        #expect(doc.range(of: "(?<![A-Za-z0-9])sk-", options: .regularExpression) == nil)
        #expect(doc.contains("`token=•••`"))
    }
}
