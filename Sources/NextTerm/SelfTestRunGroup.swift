#if DEBUG
import AppKit
import NextTermCore

/// The Run group (plan 044) in a made-up project with a package.json script and a Cargo.toml, in a project window of
/// its own: the group lists the script and cargo's commands, a Mac with no cargo gets one quiet offer line, the ▶ on a
/// row opens a tab named after the command and running it, and ⌘P lists the same tasks after "run". The look along
/// PATH is the self-test's own (nothing found), so the offer shows whatever this Mac has. Run alone with
/// NEXTTERM_SELFTEST_ONLY=runGroup.
extension SelfTest {
    static func runGroupChecks(_ c: TerminalWindowController) async {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-run-\(getpid())")
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? #"{"name": "run-group", "scripts": {"hello": "echo RUN-GROUP-OK"}}"#
            .write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try? "[package]\nname = \"run-group\"\nversion = \"0.1.0\"\n"
            .write(to: folder.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        SelfTestRunLook.look = {
            ProjectTools.Look(path: [], home: "/nonexistent", isExecutable: { _ in false }, entries: { _ in [] })
        }
        defer { SelfTestRunLook.look = nil }

        let w = AppDelegate.shared.openWindow(directory: folder.path, project: folder.path)
        if !w.isSidebarVisible { w.toggleProjectSidebar(nil) }
        let sidebar = w.sidebar
        let expected = ["npm run hello", "cargo build", "cargo run", "cargo test", "cargo clippy"]
        let listed = await wait(15) { sidebar.runGroup.tasks.map(\.task.command) == expected }
        check(listed, "the Run group lists the package.json script and cargo's commands",
              "\(sidebar.runGroup.tasks.map(\.task.command))")
        let groupRow = sidebar.outline.row(forItem: sidebar.runGroup)
        check(groupRow >= 0 && sidebar.outline.isItemExpanded(sidebar.runGroup), "the Run group shows, open, in the tree",
              "row \(groupRow)")
        let names = sidebar.runGroup.tasks.compactMap { runCell(sidebar, $0)?.line.text }
        check(names == ["hello package.json", "build Cargo.toml", "run Cargo.toml", "test Cargo.toml", "clippy Cargo.toml"],
              "each row reads its task and its file", "\(names)")

        // No cargo on this look's PATH: one line, nothing more.
        let offered = await wait(5) { sidebar.runGroup.offers.map(\.offer.text) == ["cargo isn’t installed"] }
        let offerText = sidebar.runGroup.offers.first.flatMap { runCell(sidebar, $0)?.shownText }
        check(offered && offerText == "cargo isn’t installed · Install…", "a missing tool the project needs gets one quiet line",
              offerText ?? "\(sidebar.runGroup.offers.map(\.offer.text))")

        sidebar.outline.scrollRowToVisible(max(groupRow, 0))
        if let window = w.window { await screenshot(window, suffix: "-run-group") }

        // ▶ on the script's row: a new tab in the project's folder, named after the command, running it.
        let before = Set(w.tabs.map(\.id))
        if let item = sidebar.runGroup.tasks.first, let cell = runCell(sidebar, item) {
            cell.action.performClick(nil)
        } else {
            check(false, "the script's row has a cell to click")
        }
        let ran = await wait(20) {
            guard let tab = w.tabs.first(where: { !before.contains($0.id) }) else { return false }
            return tab.userTitle == "npm run hello" && tab.screenTail(12).contains { $0.contains("npm run hello") }
        }
        let opened = w.tabs.first { !before.contains($0.id) }
        check(ran && opened.map { canonicalPath($0.directory) } == folder.path, "▶ runs the task in a new tab named after it",
              "\(opened?.userTitle ?? "no tab"): " + (opened?.screenTail(4).joined(separator: " | ") ?? ""))

        // ⌘P: "run" lists the same tasks; a plain search does not.
        w.goToFile(nil)
        w.fileFinder.query = "run hello"
        let palette = await wait(5) { w.fileFinder.shownPaths.first == "Run: npm run hello" }
        check(palette, "⌘P lists a task after “run”", "\(w.fileFinder.shownPaths.prefix(3))")
        w.fileFinder.query = "hello"
        _ = await wait(3) { !w.fileFinder.shownPaths.contains { $0.hasPrefix("Run: ") } }
        check(!w.fileFinder.shownPaths.contains { $0.hasPrefix("Run: ") }, "⌘P keeps a plain search to files",
              "\(w.fileFinder.shownPaths.prefix(3))")
        w.fileFinder.close()

        func gone() -> Bool { !AppDelegate.shared.controllers.contains { $0 === w } }
        w.closeProject(nil)
        if await wait(5, gone) == false {
            w.window?.close()
            if await wait(5, gone) == false { note("run group: its window did not close") }
        }
        c.window?.makeKeyAndOrderFront(nil)
        try? fm.removeItem(at: folder)
    }

    /// A Run row's or offer's cell, scrolled into view and laid out.
    private static func runCell(_ sidebar: ProjectSidebarView, _ item: AnyObject) -> RunCellView? {
        let row = sidebar.outline.row(forItem: item)
        guard row >= 0 else { return nil }
        sidebar.outline.scrollRowToVisible(row)
        sidebar.outline.layoutSubtreeIfNeeded()
        let cell = sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? RunCellView
        cell?.layoutSubtreeIfNeeded()
        return cell
    }
}
#endif
