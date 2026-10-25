import AppKit
import NextTermCore

#if DEBUG
/// Tasks › Connect a Tracker to Your Agents…: Linear first; with a made-up PATH missing `claude`, Claude Code's row says
/// it isn't on this Mac and has no Open button, while Copy still copies; a held pair has neither and its link is
/// recorded, not opened; and Open in a New Tab types Linear's Claude Code line into a new home-folder tab with no Return,
/// a tab agents can't type in, press keys in, answer in or close until it closes. The made-up `claude` is an empty file
/// that is never run.
extension SelfTest {
    static func connectTrackerChecks(_ c: TerminalWindowController) async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("nt-tracker-\(UUID().uuidString)")
        let bin = empty.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let pasteboard: String? = NSPasteboard.general.string(forType: .string)
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        defer {
            ConnectTrackerSheet.current?.done()
            ConnectTrackerSheet.fakePath = nil
            TaskOpen.recordsOnly = false
            TaskOpen.opened = []
            NSPasteboard.general.clearContents()
            if let pasteboard { NSPasteboard.general.setString(pasteboard, forType: .string) }
            try? FileManager.default.removeItem(at: empty)
        }
        let item = NSApp.mainMenu?.items.first { $0.title == "Tasks" }?.submenu?.items.first {
            $0.action == #selector(TasksMenu.connectTracker(_:))
        }
        check(item?.title == "Connect a Tracker to Your Agents…" && item?.keyEquivalent.isEmpty == true,
              "connect a tracker: the Tasks menu has its row, with no key", item?.title ?? "missing")
        ConnectTrackerSheet.fakePath = [bin.path]
        guard let sheet = await connectTrackerSheet(c) else { return }
        check(sheet.trackerPopup.titleOfSelectedItem == "Linear", "connect a tracker: Linear is first",
              sheet.trackerPopup.titleOfSelectedItem ?? "")
        let claude: ConnectTrackerSheet.RowViews? = sheet.rowViews[.claude]
        let expected: String = "claude mcp add --transport http --scope user linear-server https://mcp.linear.app/mcp"
        let missing: Bool = claude?.open?.isHidden == true && claude?.notFound?.isHidden == false
        check(claude?.line.stringValue == expected && missing && claude?.notFound?.stringValue == ConnectTrackerSheet.notFound,
              "connect a tracker: with claude not on PATH its row says so and has no Open button",
              claude?.line.stringValue ?? "no row")
        let claudeNotes: [String] = claude?.notes.map(\.stringValue) ?? []
        check(claudeNotes == ["Then, in Claude Code: /mcp"], "connect a tracker: Claude Code's row says signing in is next",
              claudeNotes.joined(separator: " / "))
        let held: [String] = sheet.heldLabels.map(\.stringValue)
        check(held == TrackerLines.heldSummary && held.count == 3,
              "connect a tracker: Not listed yet names each tracker with why", held.joined(separator: " / "))
        claude?.copy?.performClick(nil)
        check(NSPasteboard.general.string(forType: .string) == expected, "connect a tracker: Copy still copies the line")
        sheet.choose("GitHub")
        let heldRow: ConnectTrackerSheet.RowViews? = sheet.rowViews[.claude]
        check(heldRow?.copy == nil && heldRow?.open == nil && heldRow?.link != nil,
              "connect a tracker: a held pair has no Copy or Open button, only its page", heldRow?.line.stringValue ?? "")
        let codexNotes: [String] = sheet.rowViews[.codex]?.notes.map(\.stringValue) ?? []
        let tokenNote: Bool = codexNotes.count == 1 && codexNotes[0].contains("GITHUB_PAT_TOKEN")
        check(tokenNote, "connect a tracker: GitHub's Codex row says where the token comes from, with no sign-in step",
              codexNotes.joined(separator: " / "))
        heldRow?.link?.performClick(nil)
        let page: URL = TrackerLines.catalog.first { $0.name == "GitHub" }!.cell(for: .claude).page
        check(TaskOpen.opened == [page], "connect a tracker: a held pair's page is recorded, and nothing opens",
              TaskOpen.opened.map(\.absoluteString).joined(separator: " "))
        sheet.done()
        await connectTrackerTabChecks(c, bin: bin, expected: expected)
    }

    /// The sheet over `c`, once it has looked for the agents.
    private static func connectTrackerSheet(_ c: TerminalWindowController) async -> ConnectTrackerSheet? {
        ConnectTrackerSheet.present(over: c.window)
        guard let sheet = ConnectTrackerSheet.current, await wait(5, { sheet.found != nil }) else {
            check(false, "connect a tracker: its sheet opens and looks for the agents")
            return nil
        }
        return sheet
    }
}
#endif
