import Foundation
import Testing

/// Every colour the app draws is a theme token (ThemePalette, through Theme), so a new theme is one more palette and
/// nothing else. This counts the colour literals left in the app's views, file by file: a count may only go down. A
/// new colour belongs in ThemePalette (a key every palette fills) or Theme (a mark, a wash, a pair), never in a view.
@Suite struct ThemeTokenTests {
    /// The literals there are today, each a reviewed exception (white text on an accent fill, a shadow, a scrim over any
    /// theme, a dark value beside a token). Lower a count when you take one out; never raise one.
    static let allowed: [String: Int] = [
        "ApprovalLayout.swift": 1, "BranchPopup.swift": 1, "CommandPaneAutoClose.swift": 1, "CompletionPopup.swift": 1,
        "EditorArea.swift": 1, "EditorEnvValues.swift": 3, "FindInFilesController.swift": 1, "GhostTextView.swift": 2,
        "GitLogCells.swift": 2, "GoToFile.swift": 2, "GoToHeading.swift": 1, "LayoutPickerSheet.swift": 8,
        "MarkdownStyler.swift": 1, "NotebookView.swift": 4, "Panes.swift": 1, "PlaceMarks.swift": 1,
        "TabBarView.swift": 1, "TerminalTab.swift": 2, "UpdateWindow.swift": 1, "WelcomeSwitcherList.swift": 1,
        "WindowColumnHost.swift": 1, "WindowColumnView.swift": 2,
    ]

    static let literal = try! NSRegularExpression(
        pattern: #"NSColor\(hex: 0x|NSColor\((calibratedWhite|white|srgbRed|calibratedRed|deviceWhite|red): *[0-9.]|NSColor\.(white|black)\b"#)

    @Test func viewsDrawOnlyThemeColours() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NextTerm")
        let files = try FileManager.default.contentsOfDirectory(atPath: views.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("SelfTest") && $0 != "Theme.swift" }
        #expect(files.count > 100, "the app's views were found")
        var over: [String] = []
        for file in files.sorted() {
            let text = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            let count = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                Self.literal.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) != nil
            }.count
            if count > Self.allowed[file, default: 0] { over.append("\(file): \(count) (allowed \(Self.allowed[file, default: 0]))") }
        }
        #expect(over.isEmpty, "colour literals in views; use a ThemePalette key or Theme: \(over.joined(separator: ", "))")
    }
}
