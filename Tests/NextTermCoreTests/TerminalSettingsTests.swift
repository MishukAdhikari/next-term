import Foundation
import Testing
@testable import NextTermCore

@Suite struct TerminalSettingsTests {
    @Test func startFolderAsStored() {
        let cases: [(String?, StartFolder)] = [
            (nil, .project), ("project", .project), ("current", .current), ("home", .home), ("/Users/me/Code", .folder("/Users/me/Code")),
            ("relative", .project), ("", .project),
        ]
        for (stored, folder) in cases { #expect(StartFolder(stored: stored) == folder, "\(stored ?? "nil")") }
        for folder in [StartFolder.project, .current, .home, .folder("/tmp")] { #expect(StartFolder(stored: folder.stored) == folder) }
    }

    @Test func whereANewTabOpens() {
        let home = "/Users/me"
        func open(_ folder: StartFolder, project: String?, current: String?, exists: Bool = true) -> String? {
            folder.directory(project: project, current: current, home: home) { _ in exists }
        }
        // The default: the project's folder, else (a window without one) the tab in front's.
        #expect(open(.project, project: "/p", current: "/p/sub") == "/p")
        #expect(open(.project, project: nil, current: "/x") == "/x")
        #expect(open(.project, project: nil, current: nil) == nil)
        // The current tab's folder, in a project window too; else the project's.
        #expect(open(.current, project: "/p", current: "/p/sub") == "/p/sub")
        #expect(open(.current, project: "/p", current: nil) == "/p")
        #expect(open(.home, project: "/p", current: "/p/sub") == home)
        // A chosen folder, while it exists; once gone, the default rule.
        #expect(open(.folder("/Users/me/Code"), project: "/p", current: nil) == "/Users/me/Code")
        #expect(open(.folder("/gone"), project: "/p", current: "/q", exists: false) == "/p")
    }

    @Test func scrollbackRange() {
        #expect(Scrollback.clamped(5) == 1_000 && Scrollback.clamped(25_000) == 25_000 && Scrollback.clamped(10_000_000) == 100_000)
        #expect(ImportedSetting.scrollback(clamping: 0) == .terminalScrollback(1_000))
        #expect(CursorShape.allCases.map(\.rawValue) == ["block", "bar", "underline"])
    }

    /// Every key an import writes is one Undo can put back: booleans are told apart from numbers by name.
    @Test func importedSettingKeys() {
        let settings: [ImportedSetting] = [.terminalScrollback(5000), .terminalStartFolder("home"), .terminalCursorShape("bar"),
                                           .terminalCursorBlink(true), .trimTrailingWhitespace(true), .insertFinalNewline(false),
                                           .hiddenFiles(["a"])]
        #expect(Set(settings.map(\.key)).count == settings.count)
        #expect(ImportedSetting.boolKeys.isSuperset(of: ["terminalCursorBlink", "trimTrailingWhitespace", "insertFinalNewline"]))
        #expect(!ImportedSetting.boolKeys.contains("terminalScrollback"))
    }
}
