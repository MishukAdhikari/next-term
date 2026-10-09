import Foundation
import Testing
@testable import NextTermCore

/// What a diff's selected lines become for the agents: what the editor link tells them (never a file that
/// holds secrets), what Send to Agent types (the file at its lines when they are on disk, else their text with
/// the path and what they are), and when the toolbar offers to ask an agent about them.
@Suite struct DiffShareTests {
    let file = UnifiedDiff.parse(DiffSelectionTests.text)[0]
    let path = "/repo/app.txt"

    func pick(_ side: DiffSide, _ texts: [String]) -> [DiffSelectedRow] {
        SideBySide.rows(for: file).compactMap { row in
            let line = side == .old ? row.left : row.right
            guard let line, texts.contains(line.text) else { return nil }
            return DiffSelectedRow(line: line, side: side, from: 0, to: nil)
        }
    }

    func share(_ side: DiffSide, _ texts: [String], today: DiffToday = .new, version: DiffShare.Version = .workingTree,
               secrets: Bool = false, uncommitted: Bool = true) throws -> DiffShare {
        let selection = try #require(DiffSelections.make(pick(side, texts), in: file, today: today))
        return DiffShare(path: path, selection: selection, holdsSecrets: secrets, isUncommitted: uncommitted, version: version, language: "text")
    }

    // MARK: the editor link

    @Test func theLinkIsToldTheLinesOrTheCaretWhereTheyWere() throws {
        let new = try share(.new, ["line five", "line 6"])
        #expect(new.linked == DiffShare.Linked(path: path, text: "line five\nline 6\n", start: DiffPosition(line: 4, character: 0),
                                              end: DiffPosition(line: 6, character: 0)))
        let old = try share(.old, ["line 15", "line 16"])
        #expect(old.linked == DiffShare.Linked(path: path, text: "line 15\nline 16\n", start: DiffPosition(line: 14, character: 0),
                                              end: DiffPosition(line: 14, character: 0)))
        // A commit's version: its text, no place in the file now.
        let commit = try share(.new, ["line five"], today: .neither, version: .commit("0123456789"))
        #expect(commit.linked == DiffShare.Linked(path: path, text: "line five\n", start: nil, end: nil))
    }

    @Test func aFileThatHoldsSecretsIsNoFileToTheLink() throws {
        #expect(try share(.new, ["line five"], secrets: true).linked == nil)
        #expect(try share(.old, ["line 15"], secrets: true).linked == nil)
    }

    @Test func secretsAreFoundByAnyOfTheFilesNames() throws {
        #expect(DiffShare.holdsSecrets(["/repo/.env"]))
        #expect(DiffShare.holdsSecrets(["/repo/config/prod.env", nil]))
        #expect(!DiffShare.holdsSecrets(["/repo/app.txt", nil]))
        #expect(!DiffShare.holdsSecrets(["/repo/.env.example"]))
        // Renamed from .env: the old name holds them too.
        #expect(DiffShare.holdsSecrets(["/repo/settings.txt", ".env"]))
        // A link to an .env file, by its own name.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-diffshare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = folder.appendingPathComponent(".env"), link = folder.appendingPathComponent("settings")
        try "KEY=value\n".write(to: env, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env)
        #expect(DiffShare.holdsSecrets([link.path]))
    }

    // MARK: Send to Agent

    @Test func theNewSideOnDiskIsTheFileAtItsLines() throws {
        #expect(try share(.new, ["line five", "line 6"]).contextItem(exists: true) == ContextItem(path: path, lines: 5...6))
        // Unchanged lines picked on the old side are the file's lines too.
        #expect(try share(.old, ["line 26", "line 27"]).contextItem(exists: true) == ContextItem(path: path, lines: 25...26))
    }

    @Test func theOldSideIsItsTextWithThePathAndNoLines() throws {
        let removed = try share(.old, ["line 15", "line 16"]).contextItem(exists: true)
        #expect(removed == ContextItem(path: path, note: "lines removed", code: "line 15\nline 16", language: "text"))
        let before = try share(.old, ["line 14", "line 15"]).contextItem(exists: true)
        #expect(before == ContextItem(path: path, note: "before the change", code: "line 14\nline 15", language: "text"))
        let gone = try share(.old, ["line 15"]).contextItem(exists: false)
        #expect(gone == ContextItem(path: path, note: "deleted", code: "line 15", language: "text"))
    }

    @Test func aVersionThatIsNotTheFileSaysWhichItIsAndGoesAsCode() throws {
        let sha = "0123456789abcdef"
        let commitNew = try share(.new, ["line five", "line 6"], today: .neither, version: .commit(sha)).contextItem(exists: true)
        #expect(commitNew == ContextItem(path: path, lines: 5...6, note: "as of commit 0123456", code: "line five\nline 6", language: "text"))
        let commitOld = try share(.old, ["line 15"], today: .neither, version: .commit(sha)).contextItem(exists: true)
        #expect(commitOld == ContextItem(path: path, note: "lines removed in commit 0123456", code: "line 15", language: "text"))
        let branchNew = try share(.new, ["line five"], today: .neither, version: .branch("feat/x")).contextItem(exists: true)
        #expect(branchNew == ContextItem(path: path, lines: 5...5, note: "as on feat/x", code: "line five", language: "text"))
        let branchOld = try share(.old, ["line 14", "line 15"], today: .neither, version: .branch("feat/x")).contextItem(exists: true)
        #expect(branchOld == ContextItem(path: path, note: "before feat/x changed it", code: "line 14\nline 15", language: "text"))
        let staged = try share(.new, ["line five"], today: .neither, version: .staged).contextItem(exists: true)
        #expect(staged == ContextItem(path: path, lines: 5...5, note: "as staged", code: "line five", language: "text"))
    }

    @Test func nothingGoesIntoAnAgentsPromptWhileItWaitsOnItsProposal() throws {
        #expect(try share(.old, ["line 25"], today: .old, version: .proposal).contextItem(exists: true) == nil)
    }

    @Test func oldTextTooLongToTypeIsNotTyped() {
        let long = (1...(AgentPrompt.maxInlineLines + 1)).map { "line \($0)" }.joined(separator: "\n")
        let selection = DiffSelection(side: .old, text: long + "\n", linesText: long, lines: 1...(AgentPrompt.maxInlineLines + 1), isInFile: false,
                                      changedOnly: true, start: DiffPosition(line: 0, character: 0), end: DiffPosition(line: 0, character: 0))
        let share = DiffShare(path: path, selection: selection, holdsSecrets: false, isUncommitted: true, version: .workingTree, language: "text")
        #expect(share.contextItem(exists: true) == nil)
    }

    // MARK: the Ask hint

    @Test func theHintIsOfferedForUncommittedLinesOfAFileThatMayBeShared() {
        #expect(DiffShare.offersAsk(hasLines: true, isUncommitted: true, holdsSecrets: false))
        #expect(!DiffShare.offersAsk(hasLines: false, isUncommitted: true, holdsSecrets: false))
        #expect(!DiffShare.offersAsk(hasLines: true, isUncommitted: false, holdsSecrets: false))
        // Never an invitation to type an .env file's lines into a prompt (⌥⌘K, asked for, still types them).
        #expect(!DiffShare.offersAsk(hasLines: true, isUncommitted: true, holdsSecrets: true))
    }
}
