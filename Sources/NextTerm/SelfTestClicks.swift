import AppKit
import NextTermCore
import SQLite3

/// "Open files with a single click" (Settings › Editor). Off, a click in the project tree selects and a
/// double-click opens. On, a click opens the file in a preview tab that the next click reuses, and what a
/// click must never open (folders, images, binaries, big files, deleted rows, Databases rows, modified
/// clicks, drags, the click that ends a rename) still only selects. The clicks are real mouse events.
extension SelfTest {
    static func singleClickChecks(_ c: TerminalWindowController, proj: URL, tab: TerminalTab) async {
        guard let window = c.window, let app = AppDelegate.shared else { return }
        guard await frontmost(window, "every check") else { return }
        let fm = FileManager.default
        let key = "sidebarSingleClickOpens"
        let savedSetting = UserDefaults.standard.object(forKey: key)
        c.show(tab)
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        guard await wait(5, { c.sidebar.root?.path == canonicalPath(proj.path) }) else {
            return check(false, "single click: the sidebar shows the test project", c.sidebar.root?.path ?? "nil")
        }

        // The files: five small ones (and three more), a folder, an image, a binary, one at the size limit
        // and one past it, and a committed file to delete.
        let folder = proj.appendingPathComponent("clicks")
        try? fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let files = ["a", "b", "c", "d", "e", "f", "g", "h"].map { folder.appendingPathComponent("\($0).txt") }
        for file in files { try? "\(file.deletingPathExtension().lastPathComponent)\n".write(to: file, atomically: true, encoding: .utf8) }
        try? "inner\n".write(to: folder.appendingPathComponent("sub/inner.txt"), atomically: true, encoding: .utf8)
        let png = folder.appendingPathComponent("pic.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]).write(to: png)
        let binary = folder.appendingPathComponent("tool.bin")
        try? Data([0x7F, 0x45, 0x4C, 0x46, 0, 0, 0, 0, 1, 2, 3]).write(to: binary)
        let line = String(repeating: "x", count: 99) + "\n"
        let atLimit = folder.appendingPathComponent("limit.log")
        try? String(repeating: line, count: SidebarClick.singleClickMaxSize / 100).write(to: atLimit, atomically: false, encoding: .utf8)
        let large = folder.appendingPathComponent("large.log")
        try? String(repeating: line, count: (SidebarClick.singleClickMaxSize + (1 << 20)) / 100).write(to: large, atomically: false, encoding: .utf8)
        let gone = folder.appendingPathComponent("gone.txt")
        try? "1\n2\n".write(to: gone, atomically: true, encoding: .utf8)
        let gitPath = GitRunner.locateGit()
        func git(_ args: String...) {
            guard let gitPath else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gitPath)
            p.arguments = ["-C", proj.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        git("add", "clicks/gone.txt")
        git("commit", "-qm", "single click", "--", "clicks/gone.txt")

        let outline = c.sidebar.outline
        let area = c.editorArea
        guard await wait(5, { c.sidebar.root?.children?.contains { $0.name == "clicks" } == true }) else {
            return check(false, "single click: the test folder appears in the tree")
        }
        // Only the project and the test folder open, so the rows fit with room below them.
        for node in c.sidebar.root?.children ?? [] where node.isDirectory && node.name != "clicks" { outline.collapseItem(node) }
        c.sidebar.reveal(files[0].path)
        guard await wait(5, { sidebarRow(c, files[7]) >= 0 && sidebarRow(c, large) >= 0 && sidebarRow(c, gone) >= 0 }) else {
            return check(false, "single click: the test folder's files are listed")
        }
        area.closeAll()
        let path = { (url: URL) in canonicalPath(url.path) }
        // After every step: a preview never has unsaved changes, and there is one at most.
        var broken: [String] = []
        func invariant(_ step: String) {
            let marked = area.tabBar.items.filter(\.preview).count
            let dirty = (area.previewPane as? CodeEditorView)?.document.isDirty == true
            if marked > 1 || dirty || (marked == 1) != (area.previewPane != nil) { broken.append(step) }
        }

        // Off, as it is by default: a click selects, a double-click opens.
        UserDefaults.standard.removeObject(forKey: key)
        let box = checkbox(in: EditorSettingsView(frame: .zero), titled: "Open files with a single click")
        let menuItem = LayoutMenu.sidebar().items.first { $0.title == "Open Files with a Single Click" }
        check(!app.sidebarSingleClickOpens && box?.state == .off && menuItem?.state == .off,
              "single click: off by default, in Settings › Editor and in the sidebar's ⋯ menu",
              "setting \(app.sidebarSingleClickOpens), box \(String(describing: box?.state)), menu \(String(describing: menuItem?.state))")
        check(box?.toolTip?.hasPrefix("A click opens the file in a preview tab") == true, "the checkbox says what it does", box?.toolTip ?? "no tooltip")
        if await frontmost(window, "the clicks with the setting off") {
            // Nothing selected first (showing a.txt above selected it): the click is what must select it.
            window.makeFirstResponder(outline)
            outline.deselectAll(nil)
            let tracked = clickRow(c, files[0])
            let selected = isSelection(c, files[0])
            check(tracked && selected && area.panes.isEmpty && window.firstResponder === outline,
                  "single click off: a click on a file only selects it", "tracked \(tracked), selected \(selected), \(area.panes.count) tabs")
            doubleClickRow(c, files[0])
            check(area.panes.count == 1 && area.activePath == path(files[0]) && area.previewPane == nil && c.isEditorFocused,
                  "single click off: a double-click opens it in an ordinary tab, with the keyboard", "\(area.panes.count) tabs")
            area.closeAll()
        }

        // On, from the ⋯ menu.
        let menu = LayoutMenu.sidebar()
        if let index = menu.items.firstIndex(where: { $0.title == "Open Files with a Single Click" }) { menu.performActionForItem(at: index) }
        let boxOn = checkbox(in: EditorSettingsView(frame: .zero), titled: "Open files with a single click")?.state == .on
        let itemOn = LayoutMenu.sidebar().items.first { $0.title == "Open Files with a Single Click" }?.state == .on
        check(app.sidebarSingleClickOpens && boxOn && itemOn, "the ⋯ menu item turns single clicks on, and both places show it")

        // Each group again: the app can lose the front during a long run.
        if await frontmost(window, "previews") {
            await previewChecks(c, files: files, atLimit: atLimit, invariant: invariant)
        }
        if await frontmost(window, "keeping a preview") {
            await keepChecks(c, files: files, invariant: invariant)
        }
        if await frontmost(window, "the clicks that only select") {
            await selectOnlyChecks(c, folder: folder, files: files, png: png, binary: binary, large: large, invariant: invariant)
        }
        if await frontmost(window, "keys, Locate and proposals") {
            await keyboardAndLoopChecks(c, files: files, invariant: invariant)
        }
        if await frontmost(window, "deleted files and databases") {
            await deletedAndDatabaseChecks(c, proj: proj, folder: folder, files: files, gone: gone, hasGit: gitPath != nil, invariant: invariant)
        }
        if await frontmost(window, "renames and turning it off") {
            await renameAndOffChecks(c, files: files, invariant: invariant)
        }
        check(broken.isEmpty, "a preview never has unsaved changes, and a window has one at most (after every step)", broken.joined(separator: ", "))

        area.closeAll()
        if let savedSetting { UserDefaults.standard.set(savedSetting, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        if gitPath != nil { // deleted by the checks, or still there when they were skipped
            git("rm", "-q", "--", "clicks/gone.txt")
            git("commit", "-qm", "single click done")
        }
        try? fm.removeItem(at: folder)
    }

    /// A click opens a preview, the next takes its place, an open file comes forward.
    private static func previewChecks(_ c: TerminalWindowController, files: [URL], atLimit: URL, invariant: (String) -> Void) async {
        guard let window = c.window else { return }
        let area = c.editorArea
        let outline = c.sidebar.outline
        window.makeFirstResponder(outline)
        clickRow(c, files[0])
        let first = area.previewPane
        let italic = area.tabBar.titleFont(at: 0).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
        let spoken = area.tabBar.tabView(at: 0)?.accessibilityLabel() ?? ""
        let tip = area.tabBar.items.first?.tooltip ?? ""
        check(area.panes.count == 1 && first != nil && area.activePath == canonicalPath(files[0].path) && area.tabBar.items.first?.preview == true,
              "single click: a click opens the file in a preview tab", "\(area.panes.count) tabs, front \(area.activeName ?? "none")")
        check(italic && spoken.hasSuffix("preview") && tip.contains("\nPreview: the next file you click takes this tab"),
              "the preview's title is in italics, and VoiceOver and its tooltip say it is a preview", "\(italic) \(spoken.debugDescription)")
        check(window.firstResponder === outline, "and the keyboard stays in the tree")
        invariant("first preview")

        // The only tab is replaced in place: the editor never closes on the way (that would hand the
        // keyboard to the terminal).
        clickRow(c, files[1])
        let paths = area.editors.map(\.document.path)
        check(area.panes.count == 1 && paths == [canonicalPath(files[1].path)] && area.previewPane === area.activePane && area.previewPane !== first,
              "the next click takes the preview's place", paths.joined(separator: ", "))
        check(!area.isHidden && window.firstResponder === outline, "without the editor closing on the way, the keyboard still in the tree")
        invariant("replaced")

        // A file at the size limit: how long a click takes to answer (the limit is tuned by it).
        let started = Date()
        clickRow(c, atLimit)
        let took = Date().timeIntervalSince(started)
        note(String(format: "a single click opens a %d MB file's preview in %.0f ms", SidebarClick.singleClickMaxSize >> 20, took * 1000))
        check(area.panes.count == 1 && area.activePath == canonicalPath(atLimit.path) && area.previewPane === area.activePane,
              "a text file at the 4 MB limit opens on a click too", area.activeName ?? "none")
        invariant("at the limit")

        // A file open in an ordinary tab comes forward; the preview stays as it is.
        clickRow(c, files[1])
        c.openFile(files[2])
        window.makeFirstResponder(outline)
        let preview = area.previewPane
        let count = area.panes.count
        clickRow(c, files[2])
        check(area.panes.count == count && area.previewPane === preview && area.activePath == canonicalPath(files[2].path) && window.firstResponder === outline,
              "a click on a file open in an ordinary tab brings it forward and changes nothing else", "\(area.panes.count) tabs")
        invariant("ordinary tab")

        // Typing in the preview keeps it: the next click opens a new preview beside it.
        clickRow(c, files[1])
        if let editor = area.previewPane as? CodeEditorView {
            editor.textView.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
            let kept = area.previewPane == nil && editor.document.isDirty && !area.tabBar.items.contains { $0.preview }
            let before = area.panes.count
            invariant("edited")
            clickRow(c, files[3])
            check(kept && area.panes.count == before + 1 && area.previewPane != nil && area.panes.contains { $0 === editor },
                  "typing in the preview keeps it, and the next click opens a new preview beside it", "\(before) → \(area.panes.count) tabs")
            editor.document.undoManager.undo()
            invariant("next after edit")
        } else {
            check(false, "typing in the preview keeps it", "no preview of b.txt")
        }
    }

    /// Everything that turns a preview into an ordinary tab, in place.
    private static func keepChecks(_ c: TerminalWindowController, files: [URL], invariant: (String) -> Void) async {
        guard let window = c.window else { return }
        let area = c.editorArea
        let outline = c.sidebar.outline
        area.closeAll()
        var failed: [String] = []
        func previewIndex() -> Int? { area.panes.firstIndex { $0 === area.previewPane } }
        func kept(_ how: String, count: Int, file: URL) {
            let ok = area.previewPane == nil && area.panes.count == count && area.editors.contains { $0.document.path == canonicalPath(file.path) }
            if !ok { failed.append(how) }
            invariant(how)
        }

        window.makeFirstResponder(outline)
        clickRow(c, files[0])
        area.tabBar.layoutSubtreeIfNeeded()
        if let index = previewIndex(), let view = area.tabBar.tabView(at: index) {
            click(view, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), count: 2)
            kept("double-clicking its tab", count: 1, file: files[0])
        } else {
            failed.append("double-clicking its tab (no tab)")
        }

        window.makeFirstResponder(outline)
        clickRow(c, files[1])
        if let index = previewIndex() {
            area.tabBar(area.tabBar, didMove: index, to: index == 0 ? 1 : index - 1) // where a tab drag ends
            kept("dragging its tab", count: 2, file: files[1])
        } else {
            failed.append("dragging its tab (no preview)")
        }

        window.makeFirstResponder(outline)
        clickRow(c, files[2])
        doubleClickRow(c, files[2])
        kept("double-clicking its row", count: 3, file: files[2])
        if !c.isEditorFocused { failed.append("double-clicking its row gives the editor the keyboard") }

        window.makeFirstResponder(outline)
        clickRow(c, files[3])
        press(outline, key: "\u{F701}", code: 125, flags: .command)
        kept("⌘↓ on its row", count: 4, file: files[3])
        if !c.isEditorFocused { failed.append("⌘↓ gives the editor the keyboard") }

        window.makeFirstResponder(outline)
        clickRow(c, files[4])
        c.fileFinder.onOpen?(files[4].path, nil, 1)
        kept("opening it with Go to File", count: 5, file: files[4])

        check(failed.isEmpty, "a preview becomes an ordinary tab in place: double-clicking its tab or its row, dragging its tab, ⌘↓, Go to File",
              failed.joined(separator: ", "))
        area.closeAll()
    }

    /// Clicks that only select, as they do with the setting off.
    private static func selectOnlyChecks(_ c: TerminalWindowController, folder: URL, files: [URL], png: URL, binary: URL, large: URL,
                                         invariant: (String) -> Void) async {
        guard let window = c.window, let root = c.sidebar.root else { return }
        let area = c.editorArea
        let outline = c.sidebar.outline
        window.makeFirstResponder(outline)
        clickRow(c, files[0])
        let preview = area.previewPane
        let count = area.panes.count
        func unchanged() -> Bool { area.previewPane === preview && area.panes.count == count && area.activePath == canonicalPath(files[0].path) }

        clickRow(c, files[2], flags: .command)
        clickRow(c, files[4], flags: .shift)
        let selected = outline.selectedRowIndexes.count
        check(selected >= 3 && unchanged(), "⌘-click and ⇧-click select several files and open none", "\(selected) selected, \(area.panes.count) tabs")

        // ⌃-click is the right-click: with no menu to show, AppKit would pass it on as a click. That
        // selects the row, which shows the click arrived (one row selected first: on a row of several
        // selected, AppKit sends nothing).
        outline.selectRowIndexes(IndexSet(integer: sidebarRow(c, files[0])), byExtendingSelection: false)
        let rowMenu = outline.menu
        outline.menu = nil
        let controlTracked = clickRow(c, files[1], flags: .control)
        outline.menu = rowMenu
        let controlSelected = isSelection(c, files[1])
        check(controlTracked && controlSelected && unchanged(), "⌃-click selects the file and opens nothing",
              "tracked \(controlTracked), selected \(controlSelected), front \(area.activeName ?? "none")")

        let last = outline.rect(ofRow: outline.numberOfRows - 1)
        let below = NSPoint(x: 60, y: last.maxY + 12)
        if below.y < outline.bounds.maxY {
            let tracked = click(outline, at: below) // it changes no selection: the outline taking the mouse-up shows it arrived
            check(tracked && unchanged(), "a click in the empty space below the rows opens nothing", "tracked \(tracked)")
        } else {
            note("no empty space below the sidebar's rows: that click is not checked")
        }

        let sub = folder.appendingPathComponent("sub")
        if let subNode = root.node(at: canonicalPath(sub.path)) {
            let wasOpen = outline.isItemExpanded(subNode)
            let folderTracked = clickRow(c, sub)
            let folderSelected = isSelection(c, sub)
            await pause(0.3)
            check(folderTracked && folderSelected && outline.isItemExpanded(subNode) == wasOpen && unchanged(),
                  "a click on a folder's name selects it and neither opens nor closes it", "tracked \(folderTracked), selected \(folderSelected)")
            let rootRow = outline.row(forItem: root)
            outline.scrollRowToVisible(rootRow)
            let rootTracked = click(outline, at: namePoint(outline, rootRow))
            let rootSelected = rootRow >= 0 && outline.selectedRowIndexes == IndexSet(integer: rootRow)
            await pause(0.3)
            check(rootTracked && rootSelected && outline.isItemExpanded(root) && unchanged(), "nor does a click on the project's own row",
                  "tracked \(rootTracked), selected \(rootSelected)")
            if !outline.isItemExpanded(subNode) {
                let row = outline.row(forItem: subNode)
                let rowView = outline.rowView(atRow: row, makeIfNecessary: true)
                let disclosure = rowView?.subviews.first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }
                if let disclosure {
                    click(disclosure, at: NSPoint(x: disclosure.bounds.midX, y: disclosure.bounds.midY))
                    check(await wait(3) { outline.isItemExpanded(subNode) } && unchanged(), "a click on a folder's arrow opens the folder, and no file")
                } else {
                    note("no disclosure button on the folder's row: the arrow click is not checked")
                }
            }
        }

        // Nothing a click opens may reach another app. A double-click still hands an image to its app.
        SafeOpen.launches = false
        let handOffs = SafeOpen.handOffs
        let image = clickRow(c, png) && isSelection(c, png)
        let program = clickRow(c, binary) && isSelection(c, binary)
        check(image && program && area.panes.count == count && SafeOpen.handOffs == handOffs,
              "a click on an image or a binary selects it, opens nothing and hands nothing to another app",
              "image clicked \(image), binary clicked \(program), \(SafeOpen.handOffs - handOffs) hand-offs")
        doubleClickRow(c, png)
        check(SafeOpen.handOffs == handOffs + 1, "a double-click still hands the image to its app", "\(SafeOpen.handOffs - handOffs) hand-offs")
        SafeOpen.launches = true

        window.makeFirstResponder(outline)
        let bigClicked = clickRow(c, large) && isSelection(c, large)
        check(bigClicked && area.panes.count == count && area.activePath != canonicalPath(large.path), "a click on a text file over 4 MB selects it and opens nothing",
              "clicked \(bigClicked)")
        doubleClickRow(c, large)
        check(area.activePath == canonicalPath(large.path) && area.activePane !== area.previewPane, "a double-click opens it", area.activeName ?? "none")
        if let editor = area.activeEditor, editor.document.path == canonicalPath(large.path) { area.close(editor) }
        invariant("select only")

        // Pressing on one file and letting go on another selects both (a drag-select): it opens neither.
        area.closeAll()
        window.makeFirstResponder(outline)
        let from = sidebarRow(c, files[0]), to = sidebarRow(c, files[1])
        outline.deselectAll(nil) // the row let go on is selected after: that shows the click arrived
        let canDrag = outline.verticalMotionCanBeginDrag
        outline.verticalMotionCanBeginDrag = false // up and down selects rows instead of dragging the file
        let dragTracked = click(outline, at: namePoint(outline, from), dragTo: namePoint(outline, to))
        outline.verticalMotionCanBeginDrag = canDrag
        let reached = outline.selectedRowIndexes.contains(to)
        check(dragTracked && reached && area.panes.isEmpty, "pressing on one file and letting go on another opens nothing",
              "tracked \(dragTracked), rows \(Array(outline.selectedRowIndexes)) selected, \(area.panes.count) tabs")

        // A drag that begins while the click is down: the dragging-session delegate sets the flag. Here the
        // hook sets it, as a real drag cannot be started from code; that the delegate method is the one
        // AppKit calls (outlineView(_:draggingSession:willBeginAt:forItems:)) is checked only by reading it.
        outline.whilePressed = { outline.dragBegan = true }
        let dragClicked = clickRow(c, files[2]) && isSelection(c, files[2])
        outline.whilePressed = nil
        check(dragClicked && area.panes.isEmpty, "a click that starts a file drag opens nothing", "clicked \(dragClicked)")
        clickRow(c, files[2])
        check(area.panes.count == 1 && area.previewPane != nil, "and the next plain click opens again")
        invariant("drags")
    }

    /// Keys move the selection and never open; showing the file in the tree never loops; proposals are
    /// never replaced; agents see the preview as one open file.
    private static func keyboardAndLoopChecks(_ c: TerminalWindowController, files: [URL], invariant: (String) -> Void) async {
        guard let window = c.window else { return }
        let area = c.editorArea
        let outline = c.sidebar.outline
        area.closeAll()
        let first = sidebarRow(c, files[0])
        outline.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        window.makeFirstResponder(outline)
        for _ in 0..<4 { press(outline, key: "\u{F701}", code: 125) }
        let down = outline.selectedRow
        for _ in 0..<4 { press(outline, key: "\u{F700}", code: 126) }
        check(area.panes.isEmpty && down == first + 4 && outline.selectedRow == first, "↓ and ↑ move through five files and open none",
              "rows \(first) → \(down) → \(outline.selectedRow)")
        press(outline, key: "b", code: 11)
        check(area.panes.isEmpty, "typing a file's name in the tree opens nothing")
        if outline.selectedRow != sidebarRow(c, files[1]) { note("typing “b” in the tree did not select b.txt (row \(outline.selectedRow))") }

        // Showing the file in the tree selects rows in code: that must not open anything or loop.
        clickRow(c, files[0])
        c.openFile(files[1])
        window.makeFirstResponder(outline)
        let count = area.panes.count
        let preview = area.previewPane
        c.revealInSidebar(nil)
        area.select(0, focus: false)
        await pause(0.5)
        check(area.panes.count == count && area.previewPane === preview, "Locate and a tab switch show the file in the tree and open nothing more",
              "\(count) → \(area.panes.count) tabs")
        invariant("reveal")

        // An agent's proposal is never a preview, and a click never replaces it.
        area.closeAll()
        let proposal = area.openProposal(for: canonicalPath(files[2].path),
                                         proposal: DiffPane.Proposal(original: "c\n", proposed: "c2\n", author: "Self-test", tag: "single-click", client: nil)) { _, _ in }
        window.makeFirstResponder(outline)
        clickRow(c, files[3])
        clickRow(c, files[4])
        let proposalOpen = area.proposals.contains { $0 === proposal } && !proposal.isDecided
        check(proposalOpen && area.panes.count == 2 && area.previewPane !== proposal && area.activePath == canonicalPath(files[4].path),
              "with an agent's proposal open, clicks open their own preview; the proposal stays open, undecided", "\(area.panes.count) tabs")
        area.close(proposal)
        invariant("proposal")

        // Five clicks on five files: one open file, which get_open_files marks as the preview.
        area.closeAll()
        window.makeFirstResponder(outline)
        for file in files.prefix(5) { clickRow(c, file) }
        var reply = ""
        MCPControl.call("get_open_files", [:], caller: nil) { reply = $0.text }
        let json = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
        let windows = json?["windows"] as? [[String: Any]] ?? []
        let open = windows.flatMap { ($0["files"] as? [[String: Any]]) ?? [] }
        let previews = open.filter { $0["preview"] as? Bool == true }
        check(area.panes.count == 1 && previews.count == 1 && previews.first?["path"] as? String == canonicalPath(files[4].path),
              "five clicks on five files leave one open file, which get_open_files marks as the preview", String(reply.prefix(300)))
        invariant("five clicks")
        area.closeAll()
    }

    /// A deleted file and the Databases rows only select; a SQLite file in the tree opens in its viewer;
    /// ⌘↓ on all three kinds at once opens every one.
    private static func deletedAndDatabaseChecks(_ c: TerminalWindowController, proj: URL, folder: URL, files: [URL], gone: URL, hasGit: Bool,
                                                 invariant: (String) -> Void) async {
        guard let window = c.window else { return }
        let fm = FileManager.default
        let area = c.editorArea
        let outline = c.sidebar.outline
        area.closeAll()
        window.makeFirstResponder(outline)
        func deletedRow() -> Int? {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? DeletedEntry)?.url.lastPathComponent == "gone.txt" }
        }
        var goneRow: Int?
        if hasGit {
            try? fm.removeItem(at: gone)
            if await wait(8, { deletedRow() != nil }), let row = deletedRow() {
                let tracked = click(outline, at: namePoint(outline, row))
                let selected = outline.selectedRowIndexes == IndexSet(integer: row)
                check(tracked && selected && area.panes.isEmpty, "a click on a deleted file selects it and shows nothing",
                      "tracked \(tracked), selected \(selected), \(area.panes.count) tabs")
                click(outline, at: namePoint(outline, row))
                click(outline, at: namePoint(outline, row), count: 2)
                let diff = area.activeDiff?.matches(root: canonicalPath(proj.path), path: "clicks/gone.txt") == true
                check(diff, "a double-click shows what was removed", area.activeName ?? "none")
                goneRow = deletedRow()
            } else {
                check(false, "the deleted test file keeps its row")
            }
        }

        // A SQLite file in the tree, and a MySQL connection in .env: both listed under Databases.
        let sqlite = folder.appendingPathComponent("data.sqlite")
        var handle: OpaquePointer?
        sqlite3_open(sqlite.path, &handle)
        sqlite3_exec(handle, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);", nil, nil, nil)
        sqlite3_close(handle)
        let env = proj.appendingPathComponent(".env")
        let savedEnv = try? Data(contentsOf: env)
        try? "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_DATABASE=shop\nDB_USERNAME=root\n".write(to: env, atomically: true, encoding: .utf8)
        let group = c.sidebar.databasesGroup
        let listed = await wait(10) {
            group.items.contains { $0.database.engine == .mysql } && group.items.contains { $0.database.engine == .sqlite } && sidebarRow(c, sqlite) >= 0
        }
        area.closeAll()
        window.makeFirstResponder(outline)
        let mysql = group.items.first { $0.database.engine == .mysql }?.database
        func sqliteRow() -> Int? { group.items.first { $0.database.engine == .sqlite }.flatMap { c.sidebar.databaseRow($0.database.id) } }
        if listed, let mysql, let row = c.sidebar.databaseRow(mysql.id) {
            let tracked = click(outline, at: namePoint(outline, row)) // a double-click would pop its menu
            let selected = outline.selectedRowIndexes == IndexSet(integer: row)
            check(tracked && selected && area.panes.isEmpty, "a click on a Databases row selects it and opens nothing",
                  "tracked \(tracked), selected \(selected), \(area.panes.count) tabs")
        } else {
            note("the Databases group did not list the test databases: that click is not checked")
        }
        clickRow(c, sqlite)
        check(area.activeDatabase != nil && area.previewPane === area.activeDatabase, "a click on a SQLite file opens it in the read-only viewer, as the preview",
              area.activeName ?? "none")
        invariant("database")

        // ⌘↓ on a file, a deleted file and a database row opens all three.
        if let goneRow = deletedRow() ?? goneRow, let sqliteRow = sqliteRow() {
            area.closeAll()
            let rows = IndexSet([sidebarRow(c, files[0]), goneRow, sqliteRow])
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            window.makeFirstResponder(outline)
            press(outline, key: "\u{F701}", code: 125, flags: .command)
            let file = area.editors.contains { $0.document.path == canonicalPath(files[0].path) }
            let diff = area.diffs.contains { $0.matches(root: canonicalPath(proj.path), path: "clicks/gone.txt") }
            let database = area.databases.contains { $0.path == canonicalPath(sqlite.path) }
            check(file && diff && database, "⌘↓ on a file, a deleted file and a database opens all three", "file \(file), diff \(diff), database \(database)")
        } else if hasGit {
            note("no deleted row or SQLite row to select together: ⌘↓ on a mixed selection is not checked")
        }
        area.closeAll()
        if let savedEnv { try? savedEnv.write(to: env) } else { try? fm.removeItem(at: env) }
        try? fm.removeItem(at: sqlite)
    }

    /// The click that ends a rename only ends it; turning single clicks off keeps the preview.
    private static func renameAndOffChecks(_ c: TerminalWindowController, files: [URL], invariant: (String) -> Void) async {
        guard let window = c.window, let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let area = c.editorArea
        let outline = c.sidebar.outline
        area.closeAll()
        let renamed = files[0].deletingLastPathComponent().appendingPathComponent("a2.txt")
        if let node = c.sidebar.root?.node(at: canonicalPath(files[0].path)) {
            c.sidebar.beginRename(node)
            if let field = window.firstResponder as? NSTextView { field.insertText("a2", replacementRange: field.selectedRange()) }
            let renaming = window.firstResponder is NSTextView
            let tracked = clickRow(c, files[1])
            let selected = isSelection(c, files[1]) // the tree reloads the renamed row later, not during the click
            if window.firstResponder is NSTextView { window.makeFirstResponder(outline) } // the outline kept it going: end it as a click elsewhere would
            check(renaming && tracked && selected && area.panes.isEmpty, "a click that ends a rename selects the file it was on and opens nothing",
                  "renaming \(renaming), tracked \(tracked), selected \(selected), \(area.panes.count) tabs")
            check(await wait(3) { fm.fileExists(atPath: renamed.path) }, "and the rename is kept")
            c.sidebar.rename(renamed, to: "a.txt")
            _ = await wait(3) { sidebarRow(c, files[0]) >= 0 }
        }

        // Off, from Settings, with a preview open: it stays, as an ordinary tab, and clicks select again.
        window.makeFirstResponder(outline)
        clickRow(c, files[4])
        let hadPreview = area.previewPane != nil
        let settings = EditorSettingsView(frame: .zero) // the checkbox's target: kept until it has been clicked
        withExtendedLifetime(settings) { checkbox(in: settings, titled: "Open files with a single click")?.performClick(nil) }
        check(hadPreview && !app.sidebarSingleClickOpens && area.previewPane == nil && area.panes.count == 1 && !area.tabBar.items.contains { $0.preview },
              "turning single clicks off in Settings keeps the preview as an ordinary tab")
        window.makeFirstResponder(outline)
        clickRow(c, files[0])
        check(area.panes.count == 1 && area.activePath == canonicalPath(files[4].path) && window.firstResponder === outline, "and a click only selects again")
        invariant("off")
    }

    // MARK: real clicks

    /// Real clicks reach the tree only while Next Term is the active app and this window is key: otherwise
    /// AppKit drops them, selecting nothing and sending nothing, and every "opens nothing" check would pass
    /// without a click. Brings the window to the front, and skips `group` with a note when it cannot.
    private static func frontmost(_ window: NSWindow, _ group: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if await wait(3, { NSApp.isActive && window.isKeyWindow }) { return true }
        note("single click: \(group) skipped, the app is not frontmost (active \(NSApp.isActive), key window \(window.isKeyWindow))")
        return false
    }

    /// A click made of real events. The mouse-up (and the drags toward `end`) wait in the queue, and the
    /// mouse-down goes straight to `view`, whose tracking loop takes them from the queue as it would a
    /// hand's. That works only while the app is active with the window key (see `frontmost`): otherwise
    /// AppKit drops the click, sent to the view or through the window alike, and the mouse-up stays in the
    /// queue (all but a ⌘-click, which AppKit lets through to a window in the background). Returns whether
    /// the view took the mouse-up, that is whether the click arrived.
    @discardableResult
    private static func click(_ view: NSView, at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = [], dragTo end: NSPoint? = nil) -> Bool {
        guard let window = view.window else { return false }
        let start = view.convert(point, to: nil)
        let finish = view.convert(end ?? point, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ location: NSPoint, after delay: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: time + delay, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown, start, after: 0) else { return false }
        if end != nil {
            for step in 1...6 {
                let f = CGFloat(step) / 6
                let location = NSPoint(x: start.x + (finish.x - start.x) * f, y: start.y + (finish.y - start.y) * f)
                if let drag = event(.leftMouseDragged, location, after: 0.01 * Double(step)) { NSApp.postEvent(drag, atStart: false) }
            }
        }
        guard let up = event(.leftMouseUp, finish, after: 0.08) else { return false }
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
        // What the view did not track (a double-click it handled on the way down) must not arrive later.
        var tracked = true
        while let left = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) {
            if left.type == .leftMouseUp { tracked = false }
        }
        return tracked
    }

    @discardableResult
    private static func clickRow(_ c: TerminalWindowController, _ url: URL, count: Int = 1, flags: NSEvent.ModifierFlags = []) -> Bool {
        let outline = c.sidebar.outline
        let row = sidebarRow(c, url)
        guard row >= 0 else { return false }
        outline.scrollRowToVisible(row)
        return click(outline, at: namePoint(outline, row), count: count, flags: flags)
    }

    /// Whether the file's row is the whole selection: what a plain click on it leaves.
    private static func isSelection(_ c: TerminalWindowController, _ url: URL) -> Bool {
        let row = sidebarRow(c, url)
        return row >= 0 && c.sidebar.outline.selectedRowIndexes == IndexSet(integer: row)
    }

    private static func doubleClickRow(_ c: TerminalWindowController, _ url: URL) {
        clickRow(c, url)
        clickRow(c, url, count: 2)
    }

    private static func sidebarRow(_ c: TerminalWindowController, _ url: URL) -> Int {
        guard let node = c.sidebar.root?.node(at: canonicalPath(url.path)) else { return -1 }
        return c.sidebar.outline.row(forItem: node)
    }

    /// On a row's name: past its disclosure arrow and its icon.
    private static func namePoint(_ outline: NSOutlineView, _ row: Int) -> NSPoint {
        let cell = outline.frameOfCell(atColumn: 0, row: row)
        return NSPoint(x: cell.minX + 40, y: cell.midY)
    }

    /// A key pressed in `view`, as AppKit hands it over.
    private static func press(_ view: NSView, key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let window = view.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: code) else { return }
        view.keyDown(with: event)
    }

    private static func checkbox(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for sub in view.subviews {
            if let found = checkbox(in: sub, titled: title) { return found }
        }
        return nil
    }
}
