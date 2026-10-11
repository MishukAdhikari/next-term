import AppKit
import NextTermCore

/// Git › Rollback… (⌥⌘Z) in a repository of its own: a file changed in the index and again after it comes back to the
/// last commit once the sheet's Roll Back is pressed, and Undo puts both changes back, the staged one staged; a new file
/// goes to the Trash, and Undo takes it back out; a file with nothing uncommitted says so and changes nothing. (A deleted
/// file's sidebar menu offers Rollback… with its key: the deleted-rows checks.) The clicks are the buttons' own, so these
/// run whether or not the app is in front. A file in the way of what has to come back is refused with nothing changed.
/// In the editor, ⌥⌘Z on a changed line rolls back that line alone (Rollback Lines), with Undo on the notice.
extension SelfTest {
    static func rollbackChecks(_ c: TerminalWindowController) async {
        guard let git = GitRunner.locateGit(), let window = c.window else { return note("rollback: skipped, no git or window") }
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-rollback-\(getpid())")
        try? fm.removeItem(at: repo)
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer {
            GitToast.dismiss()
            try? fm.removeItem(at: repo)
        }
        @discardableResult func run(_ args: String...) -> String { gitOutput(git, repo.path, args) } // trimmed
        func write(_ text: String, _ name: String) { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func read(_ name: String) -> String? { try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8) }
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
        func sheetText() -> String { window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: " | ") ?? "" }
        func press(_ title: String) async -> Bool {
            guard await wait(5, { window.attachedSheet?.contentView.map(buttons)?.contains { $0.title == title } == true }),
                  let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }

        run("init", "-q", "-b", "main")
        write("one\n", "a.txt")
        write("one\n", "b.txt")
        run("add", "-A")
        run("commit", "-q", "-m", "start")
        write("two\n", "a.txt")
        run("add", "a.txt")
        write("three\n", "a.txt")
        write("new\n", "new.txt")

        // The Git menu's Rollback… on ⌥⌘Z.
        let item = KeyboardShortcuts.shared.commands.first { $0.id == "gitRollback:" }?.item
        check(item?.title == "Rollback…" && item.flatMap(KeyboardShortcuts.chord(of:))?.display == "⌥⌘Z",
              "rollback: Git › Rollback… is on ⌥⌘Z", "\(item?.title ?? "none") \(item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "no key")")

        // A file changed in the index and after: the sheet names it, Roll Back puts it back to the last commit.
        c.rollback([repo.appendingPathComponent("a.txt")])
        let asked = await wait(10) { sheetText().contains("Roll back “a.txt”?") }
        check(asked && sheetText().contains("Undo, on the notice after, puts everything back"), "rollback: it asks first, naming the file and Undo", sheetText())
        if asked { _ = await press("Roll Back") }
        let back = await wait(10) { read("a.txt") == "one\n" && run("status", "--porcelain").contains("a.txt") == false }
        check(back && GitToast.text == "Rolled back a.txt", "rollback: Roll Back puts the file and the index back to the last commit, and says so",
              "\(read("a.txt")?.debugDescription ?? "none") \(GitToast.text ?? "no notice")")

        // Undo: both changes back, the staged one staged.
        GitToast.pressButtonForTest()
        let undone = await wait(10) { read("a.txt") == "three\n" && run("show", ":a.txt") == "two" }
        check(undone, "rollback: Undo puts both changes back, the staged one staged",
              "worktree \(read("a.txt")?.debugDescription ?? "none"), index \(run("show", ":a.txt").debugDescription)")
        GitToast.dismiss()

        // A new file goes to the Trash, and Undo takes it back out.
        c.rollback([repo.appendingPathComponent("new.txt")])
        let askedNew = await wait(10) { sheetText().contains("so it goes to the Trash") }
        check(askedNew, "rollback: a new file's question says it goes to the Trash", sheetText())
        if askedNew { _ = await press("Roll Back") }
        let trashed = await wait(10) { !fm.fileExists(atPath: repo.appendingPathComponent("new.txt").path) }
        check(trashed, "rollback: the new file is gone from the project")
        GitToast.pressButtonForTest()
        check(await wait(10) { read("new.txt") == "new\n" }, "rollback: Undo takes the new file back out of the Trash")
        GitToast.dismiss()

        // A file where a deleted folder was: the folder's file can't come back through it, so it's refused, and the
        // file stays as it is.
        try? fm.createDirectory(at: repo.appendingPathComponent("dir"), withIntermediateDirectories: true)
        write("one\n", "dir/c.txt")
        run("add", "-A")
        run("commit", "-q", "-m", "dir")
        try? fm.removeItem(at: repo.appendingPathComponent("dir"))
        write("precious\n", "dir")
        c.rollback([repo.appendingPathComponent("dir/c.txt")])
        let refused = await wait(10) { sheetText().contains("can’t come back") }
        check(refused && read("dir") == "precious\n", "rollback: a file in the way of what has to come back is refused, and kept",
              "\(sheetText()) \(read("dir")?.debugDescription ?? "none")")
        if refused { _ = await press("OK") }
        _ = await wait(5) { window.attachedSheet == nil }
        try? fm.removeItem(at: repo.appendingPathComponent("dir"))
        run("checkout", "HEAD", "--", "dir")

        // Rollback Lines: in the editor, ⌥⌘Z with the caret on a changed line puts that line back at once, the other
        // change kept; the file had no unsaved edits, so it is saved. Undo on the notice brings the line back.
        write("one\ntwo\nthree\nfour\nfive\n", "lines.txt")
        run("add", "lines.txt")
        run("commit", "-q", "-m", "lines")
        let edited = "one\nTWO\nthree\nfour\nFIVE\n"
        write(edited, "lines.txt")
        c.openFile(repo.appendingPathComponent("lines.txt"))
        if let editor = c.editorArea.activeEditor, editor.document.name == "lines.txt" {
            window.makeFirstResponder(editor.textView)
            let marked = await wait(10) { editor.changeMarks.lines.count == 2 }
            editor.textView.setSelectedRange(NSRange(location: 5, length: 0)) // on "TWO"
            check(marked && editor.touchesChanges, "rollback lines: the caret on a marked line touches a change", "\(editor.changeMarks.lines)")
            c.gitRollback(nil)
            let onlyThat = "one\ntwo\nthree\nfour\nFIVE\n"
            let back = await wait(10) { editor.document.text == onlyThat && read("lines.txt") == onlyThat }
            check(back && window.attachedSheet == nil && GitToast.text == "Rolled back 1 line in lines.txt",
                  "rollback lines: ⌥⌘Z puts back that line alone, at once, and saves a file that had no unsaved edits",
                  "\(editor.document.text.debugDescription) on disk \(read("lines.txt")?.debugDescription ?? "none"), \(GitToast.text ?? "no notice")")
            GitToast.pressButtonForTest()
            check(await wait(10) { editor.document.text == edited && read("lines.txt") == edited }, "rollback lines: Undo on the notice brings the line back, saved",
                  editor.document.text.debugDescription)
            GitToast.dismiss()
            // On an unchanged line, ⌥⌘Z is the whole file's Rollback…, which asks.
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            _ = await wait(10) { editor.changeMarks.lines.count == 2 }
            check(!editor.touchesChanges, "rollback lines: the caret on an unchanged line touches no change")
            c.gitRollback(nil)
            let asksFile = await wait(10) { sheetText().contains("Roll back “lines.txt”?") }
            check(asksFile, "rollback lines: off the changes, ⌥⌘Z asks about the whole file", sheetText())
            if asksFile { _ = await press("Cancel") }
            _ = await wait(5) { window.attachedSheet == nil }
            c.editorArea.close(editor)
        } else {
            check(false, "rollback lines: lines.txt opens in the editor")
        }
        write("one\ntwo\nthree\nfour\nfive\n", "lines.txt")

        // Nothing uncommitted: it says so, and asks nothing.
        c.rollback([repo.appendingPathComponent("b.txt")])
        let nothing = await wait(10) { GitToast.text?.hasPrefix("Nothing to roll back") == true }
        check(nothing && window.attachedSheet == nil, "rollback: a file with nothing uncommitted says so and changes nothing", GitToast.text ?? "no notice")
        GitToast.dismiss()
    }
}
