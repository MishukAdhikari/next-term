import AppKit
import NextTermCore

extension SelfTest {
    /// The Git Diff tab, in a repository of its own (a branch with two commits since main, and uncommitted
    /// work on top), then from the menu and the sidebar header's counts in the project's: the file column,
    /// the scopes, the side-by-side and unified views of a file, the All files page with its folds, the
    /// tab reused, the list following the repository.
    static func gitDiffChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let git = GitRunner.locateGit() else { return }
        c.editorArea.closeAll() // the tabs counted below are the Git Diff tab's alone
        let layout = DiffLayout.current
        DiffLayout.current = .sideBySide
        let columnHidden = GitDiffPane.columnHidden
        GitDiffPane.columnHidden = false
        let repo = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-gitdiff-\(getpid())")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        @discardableResult func run(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ name: String, _ text: String) {
            let url = repo.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let original = (1...40).map { "line \($0)" }
        write("src/app.txt", original.joined(separator: "\n") + "\n")
        write("docs/readme.md", "# Readme\n")
        run("init", "-q")
        run("add", "-A")
        run("commit", "-qm", "Base")
        run("switch", "-qc", "feat")
        write("src/feature.txt", "feature\n")
        run("add", "-A")
        run("commit", "-qm", "Add the feature file")
        let featureCommit = run("rev-parse", "HEAD")
        write("docs/readme.md", "# Readme\n\nMore.\n")
        run("commit", "-qam", "Say more in the readme")
        // Uncommitted: two changes far apart (an unchanged run between them to fold), and a new file.
        var edited = original
        edited[1] = "line two"
        edited[34] = "line thirty-five"
        write("src/app.txt", edited.joined(separator: "\n") + "\n")
        write("notes/todo.txt", "one\ntwo\n")
        let app = repo.appendingPathComponent("src/app.txt")

        // ⌥⌘G on a file: the Git Diff tab, that file's changes side by side, the file selected in the list.
        c.showChanges(of: app)
        guard let tab = c.editorArea.activeGitDiff else { return check(false, "⌥⌘G opens the Git Diff tab") }
        let list = tab.list
        let uncommittedRows = ["All files +4 −2", "notes/", "A notes/todo.txt +2 −0", "src/", "src/app.txt +2 −2"]
        check(await wait(10) { list.rowTitles == uncommittedRows && list.selectedTitle == "src/app.txt +2 −2" },
              "⌥⌘G opens the Git Diff tab with the file selected among the uncommitted changes, with their counts",
              list.rowTitles.joined(separator: " | ") + " — selected: " + (list.selectedTitle ?? "none"))
        guard let diff = c.editorArea.activeDiff, diff.matches(root: canonicalPath(repo.path), path: "src/app.txt") else {
            return check(false, "the file's diff is beside the list", c.editorArea.activeDiff?.title ?? "no diff")
        }
        check(await wait(5) { diff.hunkCount == 2 && diff.sideTexts.1.contains("line thirty-five") && !diff.showsUnified },
              "the file's changes show side by side, as a diff tab shows them", "\(diff.hunkCount) hunks")
        check(c.editorArea.panes.count == 1 && c.editorArea.activePath == app.path, "in one tab, with the file in front", "\(c.editorArea.panes.count) tabs")

        // Side by Side | Unified: the same changes in one column, the run between them folded.
        diff.unified.control.selectedSegment = 1
        _ = diff.unified.control.sendAction(diff.unified.control.action, to: diff.unified.control.target)
        let column = diff.unified.column
        let rows = { diff.unifiedRows }
        let wholeFold = { rows().contains { $0.fold?.count == 26 } && !rows().contains { $0.fold != nil && $0.fold?.count == nil } }
        check(await wait(6) { DiffLayout.current == .unified && diff.showsUnified && wholeFold() },
              "Unified shows the file in one column, the 26 unchanged lines between the changes folded",
              rows().compactMap { $0.fold?.title }.joined(separator: " | "))
        let removed = rows().filter { $0.kind == .removed }.compactMap { $0.line?.text }
        let added = rows().filter { $0.kind == .added }.compactMap { $0.line?.text }
        check(removed == ["line 2", "line 35"] && added == ["line two", "line thirty-five"] && diff.hunkCount == 2,
              "with the same changes as side by side: removed lines, then the lines that replace them", "\(removed) \(added)")
        check(rows().first(where: { $0.kind == .removed })?.changes.isEmpty == false, "the changed words are marked, as side by side")
        if let fold = rows().firstIndex(where: { $0.fold?.count == 26 }) {
            clickRow(column, fold)
            check(await wait(4) { !rows().contains { $0.kind == .fold } && rows().count > 26 }, "a click on a fold shows its lines",
                  "\(rows().count) rows, folds: " + rows().compactMap { $0.fold?.title }.joined(separator: " | "))
            check(rows().compactMap { $0.kind == .removed ? nil : $0.number } == Array(1...40), "numbered as the new file is, line 1 to 40")
        }
        // Send to Agent from the Unified view: the new file's lines in the selection.
        if let row = rows().firstIndex(where: { $0.line?.text == "line two" }) {
            column.select(row: row)
            check(diff.contextItem() == ContextItem(path: app.path, lines: 2...2), "Send to Agent from Unified sends the selected lines",
                  String(describing: diff.contextItem()))
            column.textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        // A hunk action in Unified: the change the selected lines are in is staged, and nothing else.
        diff.base = .unstaged
        _ = await wait(5) { diff.hunkCount == 2 && rows().contains { $0.line?.text == "line thirty-five" } }
        if let row = rows().firstIndex(where: { $0.line?.text == "line thirty-five" }) {
            column.select(row: row)
            diff.perform(.stage)
            diff.base = .staged
            check(await wait(5) { diff.hunkCount == 1 && rows().contains { $0.kind == .added && $0.line?.text == "line thirty-five" } },
                  "Stage Hunk in Unified stages the change under the selection", rows().filter { $0.kind == .added }.compactMap { $0.line?.text }.joined(separator: ", "))
            column.textView.setSelectedRange(NSRange(location: 0, length: 0))
            diff.perform(.unstage)
            check(await wait(5) { diff.hunkCount == 0 }, "and Unstage Hunk takes it back out", "\(diff.hunkCount) staged")
        } else {
            check(false, "Unified shows the second change to stage")
        }
        // Lines of both changes selected, a right-click on a row of the second: its Stage Hunk stages that one.
        func stagedAfter(_ act: () -> Void) async -> [String] {
            diff.base = .unstaged
            _ = await wait(5) { diff.hunkCount == 2 && rows().contains { $0.line?.text == "line two" } && rows().contains { $0.line?.text == "line thirty-five" } }
            act()
            diff.base = .staged
            _ = await wait(5) { diff.hunkCount == 1 }
            let staged = rows().filter { $0.kind == .added }.compactMap { $0.line?.text }
            diff.perform(.unstage)
            _ = await wait(5) { diff.hunkCount == 0 }
            return staged
        }
        let rightClicked = await stagedAfter {
            guard let first = rows().firstIndex(where: { $0.line?.text == "line two" }),
                  let second = rows().firstIndex(where: { $0.line?.text == "line thirty-five" }), column.starts.indices.contains(second + 1) else { return }
            column.textView.setSelectedRange(NSRange(location: column.starts[first], length: column.starts[second + 1] - column.starts[first]))
            let menu = rightClick(column, second)
            if let menu, let item = menu.items.firstIndex(where: { $0.title == "Stage Hunk" }) { menu.performActionForItem(at: item) }
        }
        check(rightClicked == ["line thirty-five"], "with lines of both changes selected, Stage Hunk on a row of the second stages the second",
              rightClicked.joined(separator: ", "))
        // Lines of the first change still selected, the arrow to the second: the button acts on the second, as “2 of 2” says.
        var said = ""
        let stepped = await stagedAfter {
            guard let first = rows().firstIndex(where: { $0.line?.text == "line two" }) else { return }
            column.select(row: first)
            NSApp.sendAction(Selector(("nextHunk")), to: diff, from: nil)
            said = "current \(diff.currentHunk + 1)"
            NSApp.sendAction(Selector(("stageHunk")), to: diff, from: nil)
        }
        check(stepped == ["line thirty-five"] && said == "current 2", "the hunk buttons act on the change the arrows went to, not the lines still selected",
              "\(said), staged: " + stepped.joined(separator: ", "))
        column.textView.setSelectedRange(NSRange(location: 0, length: 0))
        diff.base = .head
        // Remembered, for every diff, and in the View menu.
        let menuItem = KeyboardShortcuts.shared.commands.first { $0.id == "toggleUnifiedDiffs:" }?.item
        if let menuItem { _ = DiffLayoutMenu.shared.validateMenuItem(menuItem) }
        check(UserDefaults.standard.string(forKey: "diffLayout") == "unified" && menuItem?.state == .on,
              "the choice is remembered, and View › Unified Diffs is checked", "\(UserDefaults.standard.string(forKey: "diffLayout") ?? "nil"), menu \(menuItem?.title ?? "missing")")
        tab.select(path: "notes/todo.txt")
        check(await wait(5) { c.editorArea.activeDiff?.showsUnified == true && c.editorArea.activeDiff?.unifiedRows.count == 2 },
              "another file opens unified too", c.editorArea.activeDiff?.title ?? "no diff")
        DiffLayoutMenu.shared.toggleUnifiedDiffs(nil)
        check(await wait(5) { DiffLayout.current == .sideBySide && c.editorArea.activeDiff?.showsUnified == false && c.editorArea.activeDiff?.sideTexts.1.contains("two") == true },
              "View › Unified Diffs again: side by side", c.editorArea.activeDiff?.title ?? "no diff")

        // ↑ and ↓ in the list go from file to file, past the folders.
        list.select(path: "notes/todo.txt")
        pressKey(list.outline, code: 125)
        check(await wait(3) { tab.selectedPath == "src/app.txt" && c.editorArea.activeDiff?.path == "src/app.txt" }, "↓ in the list shows the next file",
              tab.selectedPath ?? "All files")
        pressKey(list.outline, code: 126)
        check(await wait(3) { tab.selectedPath == "notes/todo.txt" }, "↑ the one before", tab.selectedPath ?? "All files")
        // The diff's next change past its last: the next file, and the list follows.
        if let todo = c.editorArea.activeDiff {
            _ = await wait(5) { todo.hunkCount == 1 }
            NSApp.sendAction(Selector(("nextHunk")), to: todo, from: nil)
            check(await wait(3) { tab.selectedPath == "src/app.txt" && list.selectedTitle == "src/app.txt +2 −2" },
                  "the diff's next change, past the file's last, moves to the next file and the list follows", tab.selectedPath ?? "All files")
        }

        // All changes: everything since the branch left main, committed or not.
        tab.select(scope: .all)
        let allRows = ["All files +7 −2", "docs/", "docs/readme.md +2 −0", "notes/", "A notes/todo.txt +2 −0", "src/", "src/app.txt +2 −2",
                       "A src/feature.txt +1 −0"]
        check(await wait(10) { list.rowTitles == allRows }, "All changes lists the branch's files since main, committed or not, as a tree with counts",
              list.rowTitles.joined(separator: " | "))
        check(tab.context?.baseName == "main" && tab.context?.branchName == "feat", "counted from main, named at the top",
              "\(tab.context?.baseName ?? "nil") → \(tab.context?.branchName ?? "nil")")
        check(await wait(6) { list.scopeTitles == ["All changes", "Uncommitted", "Say more in the readme", "Add the feature file"] },
              "the scopes: All changes, Uncommitted, then the branch's commits", list.scopeTitles.joined(separator: " | "))
        list.select(path: "docs/readme.md")
        tab.select(path: "docs/readme.md")
        check(await wait(6) { c.editorArea.activeDiff?.sideTexts.1.contains("More.") == true && c.editorArea.activeDiff?.title == "readme.md ↔ main" },
              "selecting a file shows its side-by-side diff since main", c.editorArea.activeDiff?.title ?? "no diff")

        // A commit: its files only, and a file's diff as the commit made it.
        if let row = list.scopeRows.firstIndex(where: { if case let .commit(commit) = $0 { return commit.sha == featureCommit }; return false }) {
            list.scopesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            check(await wait(8) { list.rowTitles == ["All files +1 −0", "src/", "A src/feature.txt +1 −0"] }, "a commit lists the files it changed",
                  list.rowTitles.joined(separator: " | "))
            tab.select(path: "src/feature.txt")
            check(await wait(6) { c.editorArea.activeDiff?.commit?.sha == featureCommit && c.editorArea.activeDiff?.sideTexts.1.contains("feature") == true },
                  "and its file's diff as that commit made it", c.editorArea.activeDiff?.title ?? "no diff")
        } else {
            check(false, "the branch's commit is listed", list.scopeTitles.joined(separator: " | "))
        }

        // All files: every file's diff on one page, folded, the folds opening on a click.
        tab.select(scope: .all)
        _ = await wait(8) { list.rowTitles == allRows }
        tab.select(path: nil)
        check(await wait(8) { tab.allFiles?.paths == ["docs/readme.md", "notes/todo.txt", "src/app.txt", "src/feature.txt"] },
              "All files shows every changed file's diff on one page", tab.allFiles?.blockTitles.joined(separator: " | ") ?? "no page")
        if let page = tab.allFiles {
            page.reveal("src/app.txt")
            let entry = page.entry(at: "src/app.txt")
            let foldRow = entry?.rows.firstIndex { $0.fold?.count == 26 }
            if let foldRow, let blockColumn = entry?.block?.column {
                clickRow(blockColumn, foldRow)
                check(await wait(5) { entry?.rows.contains { $0.fold?.count == 26 } == false && (entry?.rows.count ?? 0) > 26 },
                      "a fold on the page opens on a click", page.blockTitles.joined(separator: " | "))
            } else {
                check(false, "the page folds the unchanged run between two changes", page.blockTitles.joined(separator: " | "))
            }
        }

        // The tab is reused, and follows the repository: a change made on disk shows by itself.
        c.showChanges(of: app)
        check(c.editorArea.gitDiffs.count == 1 && c.editorArea.panes.count == 1, "opening it again reuses the tab", "\(c.editorArea.panes.count) tabs")
        _ = await wait(6) { list.rowTitles == uncommittedRows }
        var fewer = original
        fewer[1] = "line two"
        write("src/app.txt", fewer.joined(separator: "\n") + "\n")
        check(await wait(10) { list.rowTitles.contains("src/app.txt +1 −1") }, "an edit on disk updates the list by itself", list.rowTitles.joined(separator: " | "))
        write("src/app.txt", original.joined(separator: "\n") + "\n")
        check(await wait(10) { !list.rowTitles.contains { $0.hasPrefix("src/app.txt") } && tab.selectedPath == "notes/todo.txt" },
              "a file no longer changed leaves the list, and the selection moves to its neighbour",
              list.rowTitles.joined(separator: " | ") + " — selected: " + (tab.selectedPath ?? "All files"))

        // The column hides and comes back, remembered.
        tab.toggleColumn(nil)
        check(tab.isColumnHidden && GitDiffPane.columnHidden, "the file list hides, remembered")
        tab.toggleColumn(nil)
        check(!tab.isColumnHidden && !GitDiffPane.columnHidden, "and shows again")

        // The branch popup's Git Diff row.
        c.showBranches(at: repo.path, query: "")
        check(await wait(5) { c.branchPopup.isVisible && c.branchPopup.rowTitles.contains("Git Diff") }, "the branch popup has a Git Diff row",
              c.branchPopup.rowTitles.prefix(9).joined(separator: " | "))
        c.branchPopup.close()
        c.editorArea.close(tab)

        // From the menu, and from the sidebar header's counts, in the project's repository.
        let noteFile = proj.appendingPathComponent("git-diff-note.txt")
        // Long enough that the header has room to show its count (it hides one too short to read).
        try? ((1...120).map { "note \($0)" }.joined(separator: "\n") + "\n").write(to: noteFile, atomically: true, encoding: .utf8)
        _ = await wait(8) {
            c.sidebar.git.snapshot?.files["git-diff-note.txt"] == .untracked && c.sidebar.root?.children?.contains { $0.name == "git-diff-note.txt" } == true
        }
        let command = KeyboardShortcuts.shared.commands.first { $0.id == "showGitDiff:" }
        check(command?.path == "Git" && command?.defaultChord == KeyChord(key: "g", command: true, control: true),
              "Git › Git Diff is in the menu bar, ⌃⌘G by default", "\(command?.path ?? "missing") \(command?.defaultChord?.display ?? "no key")")
        func sidebarRows() -> [String] { (0..<c.sidebar.outline.numberOfRows).map { (c.sidebar.outline.item(atRow: $0) as? FileNode)?.path ?? "other row" } }
        let before = sidebarRows()
        c.showGitDiff(nil)
        let fromMenu = c.editorArea.activeGitDiff
        check(fromMenu.map { canonicalPath($0.root) == canonicalPath(proj.path) && $0.isShowingAllFiles } == true,
              "Git › Git Diff opens the project's changes, all files on one page", fromMenu?.root ?? "no tab")
        check(await wait(8) { fromMenu?.list.rowTitles.contains { $0.contains("git-diff-note.txt") } == true }, "listing the project's changed files",
              fromMenu?.list.rowTitles.joined(separator: " | ") ?? "")
        let after = sidebarRows()
        check(after == before && !c.sidebar.isHidden, "the project sidebar is unchanged", "\(before.count) rows, then \(after.count)")
        if let fromMenu { c.editorArea.close(fromMenu) }
        let header = c.sidebar.header
        header.layoutSubtreeIfNeeded()
        if header.summaryIsShown {
            let frame = header.summaryFrame
            let hit = header.hitTest(header.convert(NSPoint(x: frame.midX, y: frame.midY), to: header.superview))
            check(hit is HeaderCountsLabel && hit?.toolTip == "Show Git Diff" && (hit?.accessibilityLabel() ?? "").hasPrefix("Show Git Diff"),
                  "the header's +N −M is a button: “Show Git Diff”, for the pointer and VoiceOver", hit.map { String(describing: type(of: $0)) } ?? "nothing")
            if let label = hit as? HeaderCountsLabel, let event = mouseEvent(label) {
                label.mouseDown(with: event)
                check(c.editorArea.activeGitDiff.map { canonicalPath($0.root) == canonicalPath(proj.path) } == true, "a click on it opens the Git Diff tab")
            }
        } else {
            note("the sidebar header hides its counts at this width: the click on them is not checked")
        }
        c.editorArea.closeAll()
        try? FileManager.default.removeItem(at: noteFile)
        try? FileManager.default.removeItem(at: repo)
        GitDiffPane.columnHidden = columnHidden
        DiffLayout.current = layout
    }

    /// A click on `row` of a unified column (a fold opens; nothing tracks the mouse after).
    private static func clickRow(_ column: UnifiedColumn, _ row: Int) {
        let text = column.textView
        let point = NSPoint(x: 30, y: text.textContainerInset.height + (CGFloat(row) + 0.5) * column.rowHeight)
        guard let window = text.window,
              let event = NSEvent.mouseEvent(with: .leftMouseDown, location: text.convert(point, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        text.mouseDown(with: event)
    }

    /// The menu a right-click on `row` of a unified column opens.
    private static func rightClick(_ column: UnifiedColumn, _ row: Int) -> NSMenu? {
        let text = column.textView
        let point = NSPoint(x: 30, y: text.textContainerInset.height + (CGFloat(row) + 0.5) * column.rowHeight)
        guard let window = text.window,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: text.convert(point, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return text.menu(for: event)
    }

    private static func mouseEvent(_ view: NSView) -> NSEvent? {
        guard let window = view.window else { return nil }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private static func pressKey(_ view: NSView, code: UInt16) {
        let key = String(Character(UnicodeScalar(code == 125 ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!))
        guard let window = view.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: code) else { return }
        view.keyDown(with: event)
    }
}
