import Foundation
import Testing
@testable import NextTermCore

@Suite struct SidebarClickTests {
    /// A plain click on row 3, the only selected row, a file.
    static func click(_ change: (inout SidebarClick.Click) -> Void = { _ in }) -> SidebarClick.Outcome {
        var click = SidebarClick.Click(row: 3, mouseDownRow: 3, selection: IndexSet(integer: 3), kind: .file)
        change(&click)
        return SidebarClick.outcome(of: click)
    }

    /// `line` over and over, past the bytes a text check reads.
    static func lines(_ line: String) -> Data {
        Data(String(repeating: line, count: TextFile.sniffLength / line.utf8.count + 1).utf8)
    }

    /// A file of `size` bytes that starts with `head`; the rest is a hole, so it takes no room on disk.
    static func file(_ project: FixtureProject, _ name: String, head: Data, size: Int) -> String {
        project.write(name, data: head)
        let path = (project.root as NSString).appendingPathComponent(name)
        if let handle = FileHandle(forWritingAtPath: path) {
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        return path
    }

    @Test func aPlainClickOnOneFileOpensIt() {
        #expect(Self.click() == .open)
    }

    @Test func theSecondClickOfADoubleClickAndModifiedClicksOnlySelect() {
        #expect(Self.click { $0.clickCount = 2 } == .selectOnly)
        #expect(Self.click { $0.command = true } == .selectOnly)
        #expect(Self.click { $0.shift = true } == .selectOnly)
        #expect(Self.click { $0.option = true } == .selectOnly)
        #expect(Self.click { $0.control = true } == .selectOnly)
        #expect(Self.click { $0.isMouseUp = false } == .selectOnly)
    }

    @Test func emptySpaceDragsRenamesAndSeveralRowsOnlySelect() {
        #expect(Self.click { $0.row = -1; $0.mouseDownRow = -1; $0.selection = [] } == .selectOnly)
        #expect(Self.click { $0.mouseDownRow = 2 } == .selectOnly) // down on one row, up on another
        #expect(Self.click { $0.dragBegan = true } == .selectOnly)
        #expect(Self.click { $0.wasRenaming = true } == .selectOnly)
        #expect(Self.click { $0.selection = IndexSet([2, 3]) } == .selectOnly)
        #expect(Self.click { $0.selection = IndexSet(integer: 2) } == .selectOnly)
    }

    @Test func foldersDeletedEntriesDatabasesAndTheRootOnlySelect() {
        for kind in [SidebarClick.Row.folder, .root, .deleted, .database, .other] {
            #expect(Self.click { $0.kind = kind } == .selectOnly, "\(kind)")
        }
    }

    @Test func onlyWhatTheEditorOrAViewerShowsCheaplyOpensOnAClick() {
        let project = FixtureProject()
        let max = SidebarClick.singleClickMaxSize
        let text = Self.lines("let x = 1\n")
        let png = Self.file(project, "logo.png", head: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]), size: 4096)
        let binary = Self.file(project, "tool.bin", head: Data("ELF".utf8) + Data([0, 1, 2]), size: 4096)
        let utf16 = Self.file(project, "export.txt", head: Data([0xFF, 0xFE, 0x61, 0x00]), size: 64)
        let tooBig = Self.file(project, "big.log", head: text, size: max + 1)
        let atLimit = Self.file(project, "limit.log", head: text, size: max)
        let csv = Self.file(project, "rows.csv", head: Data("id,name\n".utf8) + Self.lines("1,a\n"), size: 3 << 20)
        let jsonl = Self.file(project, "events.jsonl", head: Self.lines("{\"id\":1}\n"), size: 50 << 20)
        let sqlite = Self.file(project, "app.sqlite", head: Data("SQLite format 3\0".utf8), size: 4096)
        let emptyDB = Self.file(project, "database.db", head: Data(), size: 0)
        project.write("a.ipynb", "{\"cells\": []}\n")
        project.write("src/app.ts", "export {}\n")

        for path in [png, binary, utf16, tooBig] {
            #expect(!SidebarClick.opensOnSingleClick(path), "\((path as NSString).lastPathComponent)")
        }
        for path in [atLimit, csv, jsonl, sqlite, emptyDB, project.root + "/a.ipynb", project.root + "/src/app.ts"] {
            #expect(SidebarClick.opensOnSingleClick(path), "\((path as NSString).lastPathComponent)")
        }
        #expect(!SidebarClick.opensOnSingleClick(project.root + "/src"), "a folder")
        #expect(!SidebarClick.opensOnSingleClick(project.root + "/gone.txt"), "a file that is not there")
        let pipe = project.root + "/events-pipe"
        mkfifo(pipe, 0o600)
        #expect(!SidebarClick.opensOnSingleClick(pipe), "a named pipe, which would block a read")
    }

    /// The tree lists a link to a file as a file, and the editor opens what it points to.
    @Test func aLinkIsJudgedByTheFileItPointsTo() throws {
        let project = FixtureProject()
        let text = Self.lines("let x = 1\n")
        let big = Self.file(project, "big.log", head: text, size: 5 << 20)
        let small = Self.file(project, "small.log", head: text, size: 4096)
        let csv = Self.file(project, "rows.csv", head: Data("id,name\n".utf8) + Self.lines("1,a\n"), size: 10 << 20)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: project.root + "/big-link.log", withDestinationPath: big)
        try fm.createSymbolicLink(atPath: project.root + "/small-link.log", withDestinationPath: small)
        try fm.createSymbolicLink(atPath: project.root + "/rows-link.csv", withDestinationPath: csv)

        #expect(!SidebarClick.opensOnSingleClick(project.root + "/big-link.log"), "a link to a 5 MB text file")
        #expect(SidebarClick.opensOnSingleClick(project.root + "/small-link.log"), "a link to a small text file")
        #expect(SidebarClick.opensOnSingleClick(project.root + "/rows-link.csv"), "a link to a data file for the head view")
    }
}
