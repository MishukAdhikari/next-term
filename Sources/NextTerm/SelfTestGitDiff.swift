import AppKit
import NextTermCore

extension SelfTest {
    /// The Git Diff tab, in a repository of its own (a branch with two commits since main, and uncommitted
    /// work on top), then from the menu, ⌥⌘G and the sidebar header's counts in the project's: the file
    /// column, the scopes, the side-by-side and unified views of a file and the change each hunk action acts
    /// on, the All files page with its folds, the tab reused, the list following the repository; and a
    /// Latin-1 file and a name git quotes on the page, in a repository of their own.
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
        @discardableResult func run(_ args: String...) -> String { run(in: repo, args) }
        @discardableResult func run(in folder: URL, _ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", folder.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
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
        // No agent runs in this window yet: lines selected in the diff offer no Ask hint (with one: diffSelectionChecks).
        if c.agentTab == nil, let side = diff.focusView as? NSTextView {
            side.setSelectedRange((side.string as NSString).range(of: "line two"))
            check(diff.offersAsk && !diff.askRoom.wanted && diff.askRoom.shownTitle == nil,
                  "with no agent running, lines selected in an uncommitted diff offer no Ask hint", diff.askRoom.shownTitle ?? "hidden")
            side.setSelectedRange(NSRange(location: 0, length: 0))
        }

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
            // The staged diff's own rows, not the rows kept on show while its whole file is read.
            let added = { rows().filter { $0.kind == .added }.compactMap { $0.line?.text } }
            _ = await wait(5) { diff.hunkCount == 1 && added().count == 1 }
            let staged = added()
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
        // Revert Hunk… from a row, its folds open: the line put back shows between the changes left, every line
        // of the file there once, none folded away for good.
        _ = await wait(5) { diff.hunkCount == 2 && rows().contains { $0.line?.text == "line thirty-five" } && !rows().contains { $0.kind == .fold } }
        if let row = rows().firstIndex(where: { $0.kind == .added && $0.line?.text == "line thirty-five" }), let window = c.window,
           let menu = rightClick(column, row), let item = menu.items.firstIndex(where: { $0.title == "Revert Hunk…" }) {
            menu.performActionForItem(at: item)
            let reverted = await pressButton("Revert", inSheetOf: window)
            let numbers = { rows().compactMap { $0.kind == .removed ? nil : $0.number } }
            let whole = await wait(6) {
                diff.hunkCount == 1 && !rows().contains { $0.line?.text == "line thirty-five" } && numbers() == Array(1...40) && !rows().contains { $0.kind == .fold }
            }
            check(reverted && whole, "Revert Hunk… in Unified with its folds open: the line put back shows, numbered 1 to 40, nothing folded",
                  "\(diff.hunkCount) hunks, \(numbers().count) lines, folds: " + rows().compactMap { $0.fold?.title }.joined(separator: " | "))
            write("src/app.txt", edited.joined(separator: "\n") + "\n")
            diff.reload()
            _ = await wait(5) { diff.hunkCount == 2 }
        } else {
            check(false, "Unified offers Revert Hunk… on a row of a change", rows().compactMap { $0.fold?.title }.joined(separator: " | "))
        }
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
        let parted = c.editorArea.activeDiff?.tooltip ?? ""
        check(parted.contains("where this branch parted from main (\(String(run("merge-base", "HEAD", "main").prefix(7))))"),
              "its tooltip names where the branch parted from main, not main's version", parted)

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
                // A file shown, then All files again: the same page, its fold still open, not read and laid out anew.
                tab.select(path: "src/app.txt")
                let hidden = await wait(5) { c.editorArea.activeDiff?.path == "src/app.txt" } && page.isHidden
                tab.select(path: nil)
                let back = await wait(5) { tab.allFiles === page && !page.isHidden && !tab.isLoading }
                check(hidden && back && page.entry(at: "src/app.txt") === entry && entry?.rows.contains { $0.fold?.count == 26 } == false,
                      "back to All files from a file: the same page, the fold opened still open", page.blockTitles.joined(separator: " | "))
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

        // From the menu, ⌥⌘G on the editor's file and on the sidebar's, and the sidebar header's counts, in the
        // project's repository.
        let noteFile = proj.appendingPathComponent("git-diff-note.txt")
        // Two lines: the header shows a count that short too.
        try? "note 1\nnote 2\n".write(to: noteFile, atomically: true, encoding: .utf8)
        _ = await wait(8) {
            c.sidebar.git.snapshot?.files["git-diff-note.txt"] == .untracked && c.sidebar.root?.children?.contains { $0.name == "git-diff-note.txt" } == true
        }
        let command = KeyboardShortcuts.shared.commands.first { $0.id == "showGitDiff:" }
        check(command?.path == "Git" && command?.defaultChord == KeyChord(key: "g", command: true, control: true),
              "Git › Git Diff is in the menu bar, ⌃⌘G by default", "\(command?.path ?? "missing") \(command?.defaultChord?.display ?? "no key")")
        // The menu item's action through the responder chain, as a click on it or ⌃⌘G sends it: that needs the
        // window to have the keyboard, so it is brought to the front. Only when another app keeps the front is the
        // action sent to the window straight, said in a note.
        var isKey = false
        if let window = c.window {
            isKey = await bringToFront(window)
            if !isKey { note("Git Diff from the menu: sent to the window straight, \(notFrontmost(window))") }
        }
        if let item = command?.item, let action = item.action, isKey {
            check(c.validateMenuItem(item), "Git › Git Diff is on in a project window")
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            c.showGitDiff(nil)
        }
        let fromMenu = c.editorArea.activeGitDiff
        check(fromMenu.map { canonicalPath($0.root) == canonicalPath(proj.path) && $0.isShowingAllFiles } == true,
              "Git › Git Diff opens the project's changes, all files on one page", fromMenu?.root ?? "no tab")
        check(await wait(8) { fromMenu?.list.rowTitles.contains { $0.contains("git-diff-note.txt") } == true }, "listing the project's changed files",
              fromMenu?.list.rowTitles.joined(separator: " | ") ?? "")
        c.editorArea.closeAll()
        // ⌥⌘G with the file in the editor: its changes, the file selected in the list.
        c.openFile(noteFile)
        _ = await wait(5) { c.editorArea.activePath == canonicalPath(noteFile.path) }
        if let text = c.editorArea.activeTextView { c.window?.makeFirstResponder(text) }
        c.showChanges(nil)
        let fromEditor = c.editorArea.activeGitDiff
        check(await wait(5) { fromEditor?.selectedPath == "git-diff-note.txt" && c.editorArea.activeDiff?.path == "git-diff-note.txt" },
              "⌥⌘G in the editor opens the Git Diff tab on the file being edited", fromEditor?.selectedPath ?? "no tab")
        c.editorArea.closeAll()
        // ⌥⌘G with the file selected in the project sidebar.
        if let node = c.sidebar.root?.children?.first(where: { $0.name == "git-diff-note.txt" }) {
            let row = c.sidebar.outline.row(forItem: node)
            c.sidebar.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            c.window?.makeFirstResponder(c.sidebar.outline)
            c.showChanges(nil)
            let fromSidebar = c.editorArea.activeGitDiff
            check(await wait(5) { fromSidebar?.selectedPath == "git-diff-note.txt" && c.editorArea.activeDiff?.path == "git-diff-note.txt" },
                  "⌥⌘G in the sidebar opens the Git Diff tab on the file selected there", fromSidebar?.selectedPath ?? "no tab")
            c.editorArea.closeAll()
        } else {
            check(false, "the sidebar lists the new file to select")
        }
        // The header's counts: shown however short, a button, opening what they count (Uncommitted).
        let header = c.sidebar.header
        header.layoutSubtreeIfNeeded()
        check(header.summaryIsShown, "the sidebar header shows its counts, however short", "\(header.frame.width) wide")
        let frame = header.summaryFrame
        let hit = header.hitTest(header.convert(NSPoint(x: frame.midX, y: frame.midY), to: header.superview))
        check(hit is HeaderCountsLabel && hit?.toolTip == "Show Git Diff" && (hit?.accessibilityLabel() ?? "").hasPrefix("Show Git Diff"),
              "the header's +N −M is a button: “Show Git Diff”, for the pointer and VoiceOver", hit.map { String(describing: type(of: $0)) } ?? "nothing")
        if let label = hit as? HeaderCountsLabel, let event = mouseEvent(label) {
            label.mouseDown(with: event)
            let clicked = c.editorArea.activeGitDiff
            check(clicked.map { canonicalPath($0.root) == canonicalPath(proj.path) && $0.scope == .uncommitted && $0.isShowingAllFiles } == true,
                  "a click on it opens the Git Diff tab on the changes not committed yet, which they count", clicked.map { "\($0.scope)" } ?? "no tab")
        }
        c.editorArea.closeAll()

        // A file that isn't UTF-8 (Latin-1) and a name git quotes: on the All files page like any other file.
        let edge = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-gitdiff-edge-\(getpid())")
        try? FileManager.default.removeItem(at: edge)
        try? FileManager.default.createDirectory(at: edge, withIntermediateDirectories: true)
        try? "caf\u{E9}\nline 2\n".data(using: .isoLatin1)?.write(to: edge.appendingPathComponent("latin1.txt"))
        try? "one\n".write(to: edge.appendingPathComponent("quote\"name.txt"), atomically: true, encoding: .utf8)
        run(in: edge, ["init", "-q"])
        run(in: edge, ["add", "-A"])
        run(in: edge, ["commit", "-qm", "Base"])
        try? "caf\u{E9} au lait\nline 2\n".data(using: .isoLatin1)?.write(to: edge.appendingPathComponent("latin1.txt"))
        try? "two\n".write(to: edge.appendingPathComponent("quote\"name.txt"), atomically: true, encoding: .utf8)
        let edgeTab = c.editorArea.openGitDiff(root: edge.path)
        let shown = await wait(8) {
            let titles = edgeTab.allFiles?.blockTitles ?? []
            return titles.count == 2 && titles.allSatisfy { $0.hasSuffix(" rows") }
        }
        let latin = edgeTab.allFiles?.entry(at: "latin1.txt")?.rows.contains { $0.kind == .added && $0.line?.text == "café au lait" } == true
        check(shown && latin, "All files shows the lines of a Latin-1 file and of a file whose name git quotes",
              edgeTab.allFiles?.blockTitles.joined(separator: " | ") ?? "no page")
        c.editorArea.closeAll()
        try? FileManager.default.removeItem(at: edge)
        try? FileManager.default.removeItem(at: noteFile)
        try? FileManager.default.removeItem(at: repo)
        GitDiffPane.columnHidden = columnHidden
        DiffLayout.current = layout
    }

    /// Lines selected in a diff reach the agents in the window's tabs as the editor's selection does (Claude Code's
    /// selection_changed, from the stand-in `claude` connected to `agentTab`; Gemini CLI's open files): the new
    /// side as the file's lines, the old side as its text with a caret where it was, both sides selected as the
    /// side that took the keyboard or was selected last (the terminal taking the keyboard after changes nothing),
    /// Unified, the All files page (a right-click's Send to Agent sends the file right-clicked), an .env file as
    /// no file, a commit's version with no line claimed, and the editor's state again once the selection goes.
    /// ⌥⌘K from both sides of the Git Diff tab, and the "⌥⌘K Ask Claude Code" hint in its toolbar while lines of
    /// uncommitted changes are selected (never an .env file's). They need the window to have the keyboard.
    static func diffSelectionChecks(_ c: TerminalWindowController, agentTab: TerminalTab, claude: ClaudeTestClient) async {
        guard let window = c.window, let git = GitRunner.locateGit() else { return }
        guard await bringToFront(window) else { return note("diff selections for agents: skipped, \(notFrontmost(window))") }
        let restore = keepDiffSettings()
        DiffLayout.current = .sideBySide
        GitDiffPane.columnHidden = true // room in the toolbar for the hint
        let repo = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-diffsel-\(getpid())")
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
        // Line 5 changed, lines 15 and 16 removed, a line added after line 25. Beside it a second file and an .env
        // file, each with a line changed.
        let file = repo.appendingPathComponent("app.txt")
        let notes = repo.appendingPathComponent("notes.txt"), env = repo.appendingPathComponent(".env")
        var lines = (1...30).map { "line \($0)" }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? "note one\nnote 2\nnote three\n".write(to: notes, atomically: true, encoding: .utf8)
        try? "KEY=one\n".write(to: env, atomically: true, encoding: .utf8)
        run("init", "-q")
        run("add", "-A")
        run("commit", "-qm", "Base")
        lines[4] = "line five"
        lines.insert("added after 25", at: 25)
        lines.removeSubrange(14...15)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? "note one\nnote two\nnote three\n".write(to: notes, atomically: true, encoding: .utf8)
        try? "KEY=two\n".write(to: env, atomically: true, encoding: .utf8)

        c.showChanges(of: file)
        guard let tab = c.editorArea.activeGitDiff, let diff = c.editorArea.activeDiff, await wait(8, { diff.hunkCount == 3 }),
              let new = diff.focusView as? NSTextView else {
            restore()
            return check(false, "the Git Diff tab shows the file's three changes", "\(c.editorArea.activeDiff?.hunkCount ?? -1) hunks")
        }
        let old = diff.oldSideView
        /// What Claude Code was told last: the file, the text, where it starts and ends (0-based line, character).
        func told() -> (path: String?, text: String?, start: [Int], end: [Int]) {
            let params = claude.last("selection_changed")
            let selection = params?["selection"] as? [String: Any]
            func place(_ key: String) -> [Int] {
                let at = selection?[key] as? [String: Any]
                return [at?["line"] as? Int ?? -1, at?["character"] as? Int ?? -1]
            }
            return (params?["filePath"] as? String, params?["text"] as? String, place("start"), place("end"))
        }
        func isTold(_ text: String, _ start: [Int], _ end: [Int], in other: URL? = nil) async -> Bool {
            let path = (other ?? file).path
            return await wait(3) { let now = told(); return now.path == path && now.text == text && now.start == start && now.end == end }
        }
        /// Claude Code was told no file is selected (the editor's own state here: nothing open in it).
        func isToldNoFile() async -> Bool { await wait(3) { claude.last("selection_changed").map { $0["filePath"] == nil } == true } }
        func describe() -> String { "\(told())" }
        /// Selects rows of `view`, then waits for Claude Code to be told `text` from `start` to `end`.
        func select(_ view: NSTextView, _ first: String, through last: String, tells text: String, _ start: [Int], _ end: [Int]) async -> Bool {
            guard selectRows(view, first, through: last) else { return false }
            return await isTold(text, start, end)
        }

        // The new side: the file's lines 5–6, as the editor would select them; Gemini CLI's open files too.
        window.contentView?.layoutSubtreeIfNeeded()
        let toolbar = diff.toolbarFrames
        window.makeFirstResponder(new)
        check(await select(new, "line five", through: "line 6", tells: "line five\nline 6\n", [4, 0], [6, 0]),
              "lines selected on a diff's new side reach Claude Code as the file's lines 5–6", describe())
        let gemini = c.openFilesForGemini().first
        check(gemini?["path"] as? String == file.path && gemini?["isActive"] as? Bool == true && gemini?["selectedText"] as? String == "line five\nline 6\n"
              && (gemini?["cursor"] as? [String: Int])?["line"] == 5, "and Gemini CLI's open files have them, the caret on line 5", "\(gemini ?? [:])")

        // The Ask hint: Send to Agent's key and the agent's name, at the end of the toolbar's free space.
        let key = KeyboardShortcuts.shared.key(for: #selector(TerminalWindowController.sendToAgent(_:)))?.display ?? ""
        let words = (key.isEmpty ? "" : key + " ") + "Ask Claude Code"
        check(await wait(2) { diff.askRoom.wanted } && diff.askRoom.hint.title == words
              && diff.askRoom.hint.toolTip == "Types the selected lines into Claude Code’s prompt in tab “\(agentTab.title)”. Nothing is sent until you press Return there.",
              "with an agent running, the diff's toolbar offers “\(words)”", "\(diff.askRoom.hint.title) | \(diff.askRoom.hint.toolTip ?? "")")
        window.contentView?.layoutSubtreeIfNeeded()
        if diff.askRoom.bounds.width >= diff.askRoom.hint.fittingSize.width + 8 {
            check(diff.askRoom.shownTitle == words && diff.toolbarFrames == toolbar, "shown, without moving the toolbar's controls",
                  "\(diff.askRoom.shownTitle ?? "hidden"), moved: \(diff.toolbarFrames != toolbar)")
        } else {
            check(diff.askRoom.shownTitle == nil, "hidden while the toolbar has no room for it")
            note("the Ask hint: the toolbar has \(Int(diff.askRoom.bounds.width)) points free, too few to show it")
        }

        // ⌥⌘K on the new side: Claude Code connected, an @-mention of lines 5–6 in its prompt.
        c.sendToAgent(nil)
        check(await wait(3) { claude.last("at_mentioned")?["filePath"] as? String == file.path && claude.last("at_mentioned")?["lineStart"] as? Int == 4
                && claude.last("at_mentioned")?["lineEnd"] as? Int == 5 },
              "⌥⌘K on the Git Diff tab's new side mentions the file's lines 5–6", "\(claude.last("at_mentioned") ?? [:])")

        // The old side: the removed lines' text, a caret where they were (where line 17 is now: line 15).
        window.makeFirstResponder(old)
        check(await select(old, "line 15", through: "line 16", tells: "line 15\nline 16\n", [14, 0], [14, 0]),
              "lines selected on the old side reach Claude Code as their text, with a caret where they were", describe())
        // Both sides keep their selection drawn: the one selected last is what counts.
        window.makeFirstResponder(new)
        check(await select(new, "line 7", through: "line 8", tells: "line 7\nline 8\n", [6, 0], [8, 0]),
              "with both sides selected, the new side's lines once selected last", describe())
        window.makeFirstResponder(old)
        check(await select(old, "line 14", through: "line 15", tells: "line 14\nline 15\n", [13, 0], [13, 0]),
              "and the old side's once it is selected again (an unchanged line and a removed one: text, from where line 14 is)", describe())
        check(await select(old, "line 15", through: "line 16", tells: "line 15\nline 16\n", [14, 0], [14, 0]), "the removed lines alone again", describe())

        // ⌥⌘K on the old side: the removed lines' text with the file's path, typed into the prompt, never sent.
        agentTab.view.feed(text: "\u{1b}[?2004h") // as an agent taking pastes asks
        c.sendToAgent(nil)
        let typed = await wait(4) {
            let screen = agentTab.screenTail(12).joined()
            return screen.contains("app.txt") && screen.contains("(lines removed)") && screen.contains("line 16")
        }
        check(typed, "⌥⌘K on the old side types the removed lines with the file's path into the agent's prompt",
              agentTab.screenTail(6).joined(separator: " | "))
        agentTab.view.feed(text: "\u{1b}[?2004l")

        // Both sides still have lines selected: the keyboard going to one makes its lines count. A click there that
        // leaves nothing selected tells the agents nothing is, and the keyboard moving on to the terminal changes
        // nothing: the other side's lines, still drawn, are not what counts.
        window.makeFirstResponder(new)
        check(await isTold("line 7\nline 8\n", [6, 0], [8, 0]), "the keyboard back on the new side: its lines, still selected, count again", describe())
        window.makeFirstResponder(old)
        check(await isTold("line 15\nline 16\n", [14, 0], [14, 0]), "and on the old side, its", describe())
        old.setSelectedRange(NSRange(location: old.selectedRange().location, length: 0)) // a click on the old side
        let cleared = await isToldNoFile()
        window.makeFirstResponder(agentTab.view)
        _ = await wait(0.5) { false } // past the selection's debounce
        check(cleared && claude.last("selection_changed").map { $0["filePath"] == nil } == true && c.currentSelectionForClaude()["filePath"] == nil
              && diff.diffShare() == nil && !diff.askRoom.wanted,
              "a click on the old side leaving nothing there tells Claude Code nothing is selected, and the terminal taking the keyboard keeps it so",
              describe())

        // Unified: removed, added and unchanged lines together are the file's lines; removed ones alone their text.
        DiffLayout.current = .unified
        let column = diff.unified.column
        // Once the whole file is read: the three lines between the first two changes show (fewer than a fold takes).
        if await wait(5, { diff.showsUnified && diff.unifiedRows.contains { $0.line?.text == "line 10" } }) {
            window.makeFirstResponder(column.textView)
            check(await select(column.textView, "line 5", through: "line 6", tells: "line five\nline 6\n", [4, 0], [6, 0]),
                  "in Unified, a change selected with its unchanged line reaches Claude Code as the file's lines 5–6", describe())
            check(await select(column.textView, "line 15", through: "line 16", tells: "line 15\nline 16\n", [14, 0], [14, 0]),
                  "and removed lines alone as their text, with a caret where they were", describe())
            // The selection goes: the editor's own state again (no file is being edited), and the hint goes.
            column.textView.setSelectedRange(NSRange(location: 0, length: 0))
            check(await wait(3) { claude.last("selection_changed").map { $0["filePath"] == nil } == true } && !diff.askRoom.wanted,
                  "with the selection gone, Claude Code hears the editor's own state again and the Ask hint goes", describe())
        } else {
            check(false, "the diff shows Unified", "\(diff.unifiedRows.count) rows")
        }
        DiffLayout.current = .sideBySide

        // An .env file's lines: Claude Code hears of no file, Gemini CLI's open files leave it out, no Ask hint.
        c.showChanges(of: env)
        if await wait(8, { c.editorArea.activeDiff?.path == ".env" && c.editorArea.activeDiff?.hunkCount == 1 }), let secret = c.editorArea.activeDiff,
           let side = secret.focusView as? NSTextView {
            window.makeFirstResponder(side)
            // Claude Code was told of no file already (the selection went, above): what it would be told now is checked too.
            let picked = selectRows(side, "KEY=two", through: "KEY=two")
            let silent = await isToldNoFile()
            let payload = c.currentSelectionForClaude()
            check(picked && silent && secret.diffShare() != nil && payload["filePath"] == nil && payload["text"] == nil
                  && !c.openFilesForGemini().contains { $0["path"] as? String == env.path }
                  && !secret.offersAsk && !secret.askRoom.wanted,
                  "lines selected in an .env file's diff reach no agent, and offer no Ask hint", describe())
            side.setSelectedRange(NSRange(location: 0, length: 0))
        } else {
            check(false, "the Git Diff tab shows the .env file's change", c.editorArea.activeDiff?.title ?? "no diff")
        }

        // All files: a file's lines selected on the page reach the agents, the hint offered; a right-click on another
        // file's line makes that file the one Send to Agent sends, though the first one had the keyboard.
        tab.select(path: nil)
        if await wait(8, { tab.allFiles.map { !$0.isHidden && Set($0.paths) == ["app.txt", "notes.txt", ".env"] } == true }), let page = tab.allFiles {
            page.reveal("app.txt")
            let first = page.entry(at: "app.txt")?.block?.column
            page.reveal("notes.txt")
            let second = page.entry(at: "notes.txt")?.block?.column
            let row = second?.rows.firstIndex { $0.kind == .added && $0.line?.text == "note two" }
            if let first, let second, let row {
                window.makeFirstResponder(first.textView)
                check(await select(first.textView, "line five", through: "line 6", tells: "line five\nline 6\n", [4, 0], [6, 0]),
                      "lines selected on the All files page reach Claude Code as the file's lines 5–6", describe())
                check(await wait(2) { page.askRoom.wanted }, "and the page's toolbar offers to ask the agent about them")
                let menu = second.menuForRow?(row)
                check(await isTold("note two\n", [1, 0], [2, 0], in: notes) && page.diffShare()?.path == notes.path,
                      "a right-click on another file's line makes its line the one that counts", describe())
                if let menu, let send = menu.items.firstIndex(where: { $0.title == "Send to Agent" }) {
                    menu.performActionForItem(at: send)
                    check(await wait(3) { claude.last("at_mentioned")?["filePath"] as? String == notes.path && claude.last("at_mentioned")?["lineStart"] as? Int == 1 },
                          "and its Send to Agent mentions that file's line, not the first file's", "\(claude.last("at_mentioned") ?? [:])")
                } else {
                    check(false, "a line's right-click menu on the All files page offers Send to Agent")
                }
                first.textView.setSelectedRange(NSRange(location: 0, length: 0))
                second.textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                check(false, "the All files page lays out both files' lines", page.blockTitles.joined(separator: " | "))
            }
        } else {
            check(false, "All files shows the three changed files", tab.allFiles?.blockTitles.joined(separator: " | ") ?? "no page")
        }

        // A commit's version is not the file now: its text, no line claimed; and no Ask hint, it is committed.
        run("commit", "-qam", "Change")
        let sha = run("rev-parse", "HEAD"), parent = run("rev-parse", "HEAD~1")
        c.editorArea.openCommitDiff(root: repo.path, path: "app.txt", change: DiffPane.CommitChange(sha: sha, parent: parent, oldPath: nil))
        if let committed = c.editorArea.activeDiff, committed.commit?.sha == sha, await wait(8, { committed.hunkCount == 3 }),
           let side = committed.focusView as? NSTextView {
            window.makeFirstResponder(side)
            check(await select(side, "line five", through: "line 6", tells: "line five\nline 6\n", [0, 0], [0, 0]),
                  "lines selected in a commit's diff reach Claude Code as text, with no line of the file claimed", describe())
            check(committed.diffShare() != nil && !committed.askRoom.wanted, "and offer no Ask hint: they are committed")
            side.setSelectedRange(NSRange(location: 0, length: 0))
            c.editorArea.close(committed)
        } else {
            check(false, "the commit's diff of the file opens", c.editorArea.activeDiff?.title ?? "no diff")
        }
        c.editorArea.close(tab)
        try? FileManager.default.removeItem(at: repo)
        restore()
    }

    /// Selects `view`'s rows from the one reading `first` through the line break of the one reading `last`.
    private static func selectRows(_ view: NSTextView, _ first: String, through last: String) -> Bool {
        var offset = 0, start: Int?
        for line in view.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            if start == nil, line == first { start = offset }
            if let start, line == last {
                view.setSelectedRange(NSRange(location: start, length: offset + length + 1 - start))
                return true
            }
            offset += length + 1
        }
        return false
    }

    /// The diff settings as they are now, put back by the closure returned: Side by Side or Unified, the Git
    /// Diff tab's file column (the checks set both, and laying out its window moves the column's edge), and
    /// the branches All changes counts from.
    static func keepDiffSettings() -> () -> Void {
        let keys = ["diffLayout", "gitDiffColumnWidth", "gitDiffColumnHidden", "gitDiffBases"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        return {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
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

    /// Clicks the button titled `title` in the sheet over `window`, once it is up.
    private static func pressButton(_ title: String, inSheetOf window: NSWindow) async -> Bool {
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        guard await wait(5, { window.attachedSheet?.contentView.map(buttons)?.contains { $0.title == title } == true }),
              let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
        button.performClick(nil)
        return true
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
