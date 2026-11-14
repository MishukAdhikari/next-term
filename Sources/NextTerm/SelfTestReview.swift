import AppKit
import NextTermCore

/// Review comments (plan 039 U3), in a repository of its own: lines selected in a file's uncommitted diff offer
/// Comment; two comments make Review (2); lines added above move a comment with its lines, and one whose lines
/// changed is outdated; the review goes to a program as one bracketed paste and Return, and is empty after. The
/// program is a stand-in that turns bracketed paste on and writes what it reads to a file.
extension SelfTest {
    static func reviewCommentsChecks() async {
        guard let app = AppDelegate.shared, let git = GitRunner.locateGit() else { return }
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-review-\(getpid())")
        try? fm.removeItem(at: repo)
        try? fm.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        func run(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let file = repo.appendingPathComponent("src/app.txt")
        var lines = (1...40).map { "line \($0)" }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        run("init", "-q")
        run("add", "-A")
        run("commit", "-qm", "Base")
        lines[1] = "line two"
        lines[34] = "line thirty-five"
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let got = repo.appendingPathComponent("got").path

        let holder = app.openWindow(directory: repo.path)
        guard let tab = holder.tabs.first, let window = holder.window else { return check(false, "review: the window has a tab") }
        defer {
            ReviewList.close()
            tab.view.send(txt: "\u{03}")
            window.close()
            try? fm.removeItem(at: repo)
        }
        window.makeKeyAndOrderFront(nil)
        holder.showChanges(of: file)
        guard await wait(10, { holder.editorArea.activeDiff?.hunkCount == 2 }), let diff = holder.editorArea.activeDiff,
              let side = diff.focusView as? NSTextView else {
            return check(false, "review: the file's diff shows")
        }
        let room = diff.askRoom
        window.setContentSize(NSSize(width: max(window.frame.width, 1400), height: max(window.frame.height, 800)))
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(side)
        var missed = ""
        func comment(on text: String, note: String) async -> Bool {
            let range = (side.string as NSString).range(of: text)
            side.setSelectedRange(range)
            guard await wait(3, { window.contentView?.layoutSubtreeIfNeeded(); return !room.comment.isHidden }) else {
                missed = "found \(range.location != NSNotFound), offers \(diff.offersAsk), room \(Int(room.bounds.width)) wide, Comment \(Int(room.comment.fittingSize.width))"
                return false
            }
            room.comment.performClick(nil)
            guard await wait(3, { NoteEditor.shown != nil }), let editor = NoteEditor.shown else { return false }
            editor.note = note
            editor.saveNote()
            return true
        }
        check(await comment(on: "line two", note: "Spell it as a digit"), "review: lines selected in an uncommitted diff offer Comment, which takes a note", missed)
        check(await comment(on: "line thirty-five", note: "Keep this one"), "review: a second comment")
        let draft = ReviewDraft.of(window)
        check(draft.comments.map(\.lines) == [2...2, 35...35] && draft.comments.allSatisfy(\.inFile),
              "review: the comments hold the lines in the file now", "\(draft.comments.map(\.lines))")
        check(await wait(3) { !room.review.isHidden && room.review.title == "Review (2)" }, "review: the toolbar shows Review (2)", room.review.title)
        check(await wait(3) { diff.commentedLines.right == [2, 35] && diff.commentedLines.left.isEmpty },
              "review: the diff marks the commented lines", "\(diff.commentedLines)")

        // Three lines added at the top, the second comment's line changed: the first follows, the second is outdated.
        var moved = ["new 1", "new 2", "new 3"] + lines
        moved[3 + 34] = "line 35 again"
        try? (moved.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        draft.reanchor()
        check(draft.comments.map(\.lines) == [5...5, 35...35] && draft.comments.map(\.outdated) == [false, true],
              "review: a comment follows its lines; one whose lines changed is outdated",
              "\(draft.comments.map(\.lines)) \(draft.comments.map(\.outdated))")
        room.review.performClick(nil)
        check(await wait(3) { ReviewList.isShown }, "review: Review (2) lists the comments")
        ReviewList.close()

        _ = await wait(20) { tab.status.integrated }
        // Under sh, not the tab's zsh, whose settings for the terminal may come back before cat runs.
        let script = "printf '\\033[?2004h'; stty raw -echo; exec cat > \(ShellQuote.quote(got))"
        tab.view.send(txt: "/bin/sh -c \(ShellQuote.quote(script))\r")
        _ = await wait(10) { tab.view.getTerminal().bracketedPasteMode }
        ReviewUI.send(draft, to: tab)
        func read() -> String { (try? String(contentsOfFile: got, encoding: .utf8)) ?? "" }
        let sent = await wait(5) { read().hasSuffix("\u{1b}[201~\r") }
        let text = read()
        check(sent && text.contains("src/app.txt:5\r```") && text.contains("Spell it as a digit") && text.contains("src/app.txt:35 (outdated")
              && text.contains("Keep this one") && text.hasPrefix("\u{1b}[200~Review comments on your changes:"),
              "review: it goes to the program as one paste, then Return", text.debugDescription)
        check(draft.comments.isEmpty && room.review.isHidden, "review: sent, the review is empty and Review is gone")
    }
}
