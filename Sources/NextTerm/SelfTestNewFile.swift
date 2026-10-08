import AppKit
import NextTermCore

/// New File and New Folder from the project tree's right-click menu, chosen as a hand does: a right-click on a
/// row, then the item picked in the menu that opens. The new item is listed, selected and its name edited at
/// once, and stays so while the tree refreshes around it (its own git status, a file appearing beside it, the
/// Databases scan, a deleted file) until Return names it or Escape keeps "untitled", as in Finder. In a
/// repository and outside one, from a file's row and from open, closed and never opened folders.
extension SelfTest {
    static func newFileChecks(_ c: TerminalWindowController) async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-new-file-\(getpid())")
        defer { try? fm.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        let plain = base.appendingPathComponent("plain")
        let files = [
            "repo/.env": "DATABASE_URL=postgres://app:secret@db.example.com:5432/app\n",
            "repo/tmp/new.env": "A=1\n", "repo/tmp/README.md": "# tmp\n", "repo/src/a.txt": "a\n", "repo/src/b.txt": "b\n",
            "repo/docs/guide.md": "# guide\n", "repo/README.md": "# repo\n",
            "plain/top.txt": "top\n", "plain/lib/x.txt": "x\n",
        ]
        for (path, text) in files {
            let url = base.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let gitPath = GitRunner.locateGit()
        for args in [["init"], ["add", "-A"], ["commit", "-qm", "start"]] {
            guard let gitPath else { break }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gitPath)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }

        // In a repository: the git status refreshes after every change, and the .env makes a Databases group.
        if let (w, sidebar) = await newFileWindow(repo, "in a repository") {
            if gitPath == nil { note("new file: git not found, so no git status refreshes in the repository") }
            check(await wait(10) { !sidebar.databasesGroup.items.isEmpty }, "new file: the repository has a Databases group")
            let tmp = repo.appendingPathComponent("tmp"), src = repo.appendingPathComponent("src")
            sidebar.reveal(tmp.appendingPathComponent("new.env").path)
            sidebar.reveal(src.appendingPathComponent("a.txt").path)
            _ = await wait(5) { newFileRow(sidebar, tmp.appendingPathComponent("new.env")) >= 0 && newFileRow(sidebar, src.appendingPathComponent("a.txt")) >= 0 }
            if let node = sidebar.root?.node(at: src.path) { sidebar.outline.collapseItem(node) } // read, then closed
            await pause(1) // the reveal's own refreshes settle

            // A file's row, its folder open: the new file goes beside it. Everything that reloads rows happens
            // while its name is edited, then a name typed and Return.
            let untitled = tmp.appendingPathComponent("untitled")
            if await newItem("New File", from: tmp.appendingPathComponent("new.env"), sidebar, expect: untitled, "a file's row in a repository") {
                await pause(1.2) // the new file's own change: FSEvents, then git status
                try? "beside\n".write(to: tmp.appendingPathComponent("beside.txt"), atomically: true, encoding: .utf8)
                sidebar.git.refresh()
                try? "DATABASE_URL=postgres://app:secret@db.example.com:5432/app\nCACHE_DATABASE_URL=mysql://u:p@cache.example.com/c\n"
                    .write(to: repo.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
                try? fm.removeItem(at: src.appendingPathComponent("b.txt")) // committed: shown as deleted
                await pause(2.5)
                let state = nameEdit(sidebar, untitled)
                check(state == "editing", "new file: its name is still edited, the row selected, while the tree refreshes around it "
                      + "(its git status, a file beside it, the Databases scan, a deleted file)", state)
                await screenshot(w, suffix: "-new-file")
                typeName("notes.md", in: sidebar)
                press(sidebar, "\r", 36)
                let named = tmp.appendingPathComponent("notes.md")
                check(await wait(3) { fm.fileExists(atPath: named.path) && !fm.fileExists(atPath: untitled.path) }, "new file: Return gives it the name typed",
                      (try? fm.contentsOfDirectory(atPath: tmp.path).sorted().joined(separator: ", ")) ?? "")
                check(await wait(3) { newFileRow(sidebar, named) >= 0 && !editingAName(sidebar) }, "new file: and the tree lists it under that name")
            }

            // The folder's own row, open: New Folder goes inside it. Escape keeps "untitled folder", selected.
            let folder = tmp.appendingPathComponent("untitled folder")
            if await newItem("New Folder", from: tmp, sidebar, expect: folder, "an open folder's row") {
                await pause(1.5)
                let state = nameEdit(sidebar, folder)
                check(state == "editing", "new folder: its name is still edited after the git status refresh", state)
                press(sidebar, "\u{1b}", 53)
                await pause(1)
                var isFolder: ObjCBool = false
                check(fm.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue && !editingAName(sidebar),
                      "new folder: Escape keeps “untitled folder”, as Finder does (⌘Z removes it)")
                let row = newFileRow(sidebar, folder)
                check(row >= 0 && sidebar.outline.selectedRowIndexes == IndexSet(integer: row), "new folder: and it stays selected",
                      "row \(row), selected \(Array(sidebar.outline.selectedRowIndexes))")
            }

            // A closed folder that was read before, and one never opened: each opens to show the new file.
            for (closed, why) in [(src, "a closed folder's row"), (repo.appendingPathComponent("docs"), "a folder never opened")] {
                let file = closed.appendingPathComponent("untitled")
                if await newItem("New File", from: closed, sidebar, expect: file, why) {
                    await pause(1.5)
                    let state = nameEdit(sidebar, file)
                    check(state == "editing", "new file from \(why): its name is still edited after the git status refresh", state)
                    press(sidebar, "\r", 36) // the name as it is
                    check(await wait(2) { fm.fileExists(atPath: file.path) && !editingAName(sidebar) }, "new file from \(why): Return keeps “untitled”")
                }
            }
            await closeNewFileWindow(w, c)
        }

        // Outside a repository: no git status, still the folder's own refreshes.
        if let (w, sidebar) = await newFileWindow(plain, "outside a repository") {
            let lib = plain.appendingPathComponent("lib")
            sidebar.reveal(lib.appendingPathComponent("x.txt").path)
            _ = await wait(5) { newFileRow(sidebar, lib.appendingPathComponent("x.txt")) >= 0 }
            await pause(1)
            let untitled = plain.appendingPathComponent("untitled")
            if await newItem("New File", from: plain.appendingPathComponent("top.txt"), sidebar, expect: untitled, "a file's row outside a repository") {
                try? "beside\n".write(to: plain.appendingPathComponent("beside.txt"), atomically: true, encoding: .utf8)
                await pause(1.5)
                let state = nameEdit(sidebar, untitled)
                check(state == "editing", "new file outside a repository: its name is still edited while a file appears beside it", state)
                press(sidebar, "\u{1b}", 53)
                check(await wait(2) { fm.fileExists(atPath: untitled.path) && !editingAName(sidebar) }, "new file outside a repository: Escape keeps “untitled”")
            }
            if let node = sidebar.root?.node(at: lib.path) { sidebar.outline.collapseItem(node) }
            let folder = lib.appendingPathComponent("untitled folder")
            if await newItem("New Folder", from: lib, sidebar, expect: folder, "a closed folder's row outside a repository") {
                await pause(1.5)
                let state = nameEdit(sidebar, folder)
                check(state == "editing", "new folder outside a repository: its name is still edited", state)
                typeName("parts", in: sidebar)
                press(sidebar, "\r", 36)
                check(await wait(3) { fm.fileExists(atPath: lib.appendingPathComponent("parts").path) }, "new folder outside a repository: Return names it")
            }
            await closeNewFileWindow(w, c)
        }
    }

    /// A window on `folder` with its tree showing, in front.
    private static func newFileWindow(_ folder: URL, _ name: String) async -> (NSWindow, ProjectSidebarView)? {
        let w = AppDelegate.shared.openWindow(directory: folder.path)
        guard let window = w.window, let first = w.tabs.first else {
            check(false, "new file: a window \(name)")
            return nil
        }
        _ = await wait(20) { first.status.integrated }
        if !w.isSidebarVisible { w.toggleProjectSidebar(nil) }
        guard await wait(5, { w.sidebar.root?.path == folder.path && w.sidebar.root?.isLoaded == true }) else {
            check(false, "new file: the tree shows the folder \(name)", w.sidebar.root?.path ?? "nil")
            return nil
        }
        return (window, w.sidebar)
    }

    private static func closeNewFileWindow(_ window: NSWindow, _ c: TerminalWindowController) async {
        let app = AppDelegate.shared!
        guard let w = app.controllers.first(where: { $0.window === window }) else { return }
        for tab in w.tabs { w.remove(tab) }
        _ = await wait(3) { !app.controllers.contains { $0 === w } }
        if app.controllers.contains(where: { $0 === w }) { window.close() }
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// Chooses `title` in the menu of `row`'s row, and checks that `expect` was made and is listed, selected
    /// and its name edited. Whether to go on with it.
    private static func newItem(_ title: String, from row: URL, _ sidebar: ProjectSidebarView, expect: URL, _ why: String) async -> Bool {
        let name = "\(title.lowercased()) from \(why)"
        switch await choose(title, inMenuOf: row, sidebar) {
        case .chosen: break
        case .skipped:
            note("\(name): skipped, another app kept taking the front and closing the menu")
            return false
        case .failed:
            check(false, "\(name): chosen in the row's right-click menu")
            return false
        }
        guard await wait(2, { FileManager.default.fileExists(atPath: expect.path) }) else {
            let made = sidebar.root.flatMap { FileManager.default.enumerator(atPath: $0.path) }?.compactMap { $0 as? String }
                .filter { $0.hasSuffix("untitled") || $0.hasSuffix("untitled folder") } ?? []
            check(false, "\(name): the new item is listed, selected and its name edited", "not made; made: \(made.sorted().joined(separator: ", "))")
            return false
        }
        let state = nameEdit(sidebar, expect)
        check(state == "editing", "\(name): the new item is listed, selected and its name edited", state)
        return state == "editing"
    }

    /// "editing" while `url`'s name is edited in its row, the only one selected, with the keyboard in it; what
    /// is not so otherwise.
    private static func nameEdit(_ sidebar: ProjectSidebarView, _ url: URL) -> String {
        let outline = sidebar.outline
        let row = newFileRow(sidebar, url)
        guard row >= 0 else { return "not in the tree" }
        var wrong: [String] = []
        if outline.selectedRowIndexes != IndexSet(integer: row) { wrong.append("selected rows \(Array(outline.selectedRowIndexes)), its row \(row)") }
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView
        if cell?.isRenaming != true { wrong.append("its name is not being edited") }
        let editor = outline.window?.firstResponder as? NSTextView
        if editor?.isFieldEditor != true || cell.map({ editor?.isDescendant(of: $0) == true }) != true {
            wrong.append("the keyboard is in \(outline.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        return wrong.isEmpty ? "editing" : wrong.joined(separator: "; ")
    }

    /// Whether any name in the tree is being edited: a row's field has the keyboard.
    private static func editingAName(_ sidebar: ProjectSidebarView) -> Bool {
        guard let editor = sidebar.outline.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let cell = (editor.delegate as? NSTextField)?.superview as? FileCellView else { return false }
        return cell.isRenaming && cell.isDescendant(of: sidebar.outline)
    }

    private static func newFileRow(_ sidebar: ProjectSidebarView, _ url: URL) -> Int {
        let folder = canonicalPath(url.deletingLastPathComponent().path)
        let path = (folder as NSString).appendingPathComponent(url.lastPathComponent)
        guard let node = sidebar.root?.node(at: path) ?? sidebar.root?.node(at: folder)?.children?.first(where: { $0.path == path }) else { return -1 }
        return sidebar.outline.row(forItem: node)
    }

    private enum MenuChoice { case chosen, failed, skipped }

    /// A right-click on `url`'s row made of real events, then `title` picked in the menu that opens, with the
    /// arrow keys and Return. The events go through the app's queue, so the menu tracks them as a hand's.
    /// Another app taking the front drops the click or closes the menu: then it tries again, and when that is
    /// all that kept it from working, the choice is skipped rather than failed (as `frontmost` does).
    private static func choose(_ title: String, inMenuOf url: URL, _ sidebar: ProjectSidebarView) async -> MenuChoice {
        let outline = sidebar.outline
        guard let window = outline.window, let menu = outline.menu else { return .failed }
        var opened = false, closed = false, leftFront = false
        var sent: String?
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in leftFront = true },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil) { _ in opened = true },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil) { _ in closed = true },
            center.addObserver(forName: NSMenu.didSendActionNotification, object: menu, queue: nil) { note in
                sent = (note.userInfo?["MenuItem"] as? NSMenuItem)?.title
            },
        ]
        defer { observers.forEach(center.removeObserver) }
        func post(_ type: NSEvent.EventType, key: String = "", code: UInt16 = 0, at location: NSPoint = .zero) {
            let time = ProcessInfo.processInfo.systemUptime
            let event = type == .keyDown || type == .keyUp
                ? NSEvent.keyEvent(with: type, location: .zero, modifierFlags: code == 125 || code == 126 ? [.function, .numericPad] : [], timestamp: time,
                                   windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)
                : NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
        // What an earlier try left in the queue (its app in the background held it) would open a menu later.
        func discardLeftovers() {
            if let now = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.discardEvents(matching: [.rightMouseDown, .rightMouseUp, .keyDown, .keyUp], before: now)
            }
        }
        defer { discardLeftovers() }
        var onlyLeftFront = true
        for attempt in 1...6 {
            discardLeftovers()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            _ = await wait(3) { NSApp.isActive && window.isKeyWindow }
            leftFront = !NSApp.isActive
            let row = newFileRow(sidebar, url)
            guard row >= 0 else { return .failed }
            outline.scrollRowToVisible(row)
            let cell = outline.frameOfCell(atColumn: 0, row: row)
            let location = outline.convert(NSPoint(x: cell.minX + 40, y: cell.midY), to: nil)
            opened = false
            closed = false
            sent = nil
            post(.rightMouseDown, at: location)
            post(.rightMouseUp, at: location)
            // The menu fills in as it opens (menuNeedsUpdate), after it says it began.
            // It must be this row's menu, not one an earlier try's click opened.
            if await wait(3, { opened && !menu.items.isEmpty }), outline.clickedRow == row,
               menu.items.contains(where: { $0.title == title && $0.isEnabled }) {
                // Up or down toward it, a key at a time, until it stays highlighted: a busy app answers late,
                // so a key can land after the next one is sent.
                let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.isEnabled }
                let target = items.firstIndex { $0.title == title } ?? 0
                var settled = false
                for _ in 0..<40 where !settled && !closed {
                    let current = menu.highlightedItem.flatMap { item in items.firstIndex { $0 === item } }
                    if current == target {
                        await pause(0.3)
                        settled = menu.highlightedItem === items[target] && !closed
                        continue
                    }
                    let down = current.map { $0 < target } ?? true
                    let before = menu.highlightedItem
                    post(.keyDown, key: down ? "\u{F701}" : "\u{F700}", code: down ? 125 : 126)
                    post(.keyUp, key: down ? "\u{F701}" : "\u{F700}", code: down ? 125 : 126)
                    _ = await wait(1) { menu.highlightedItem !== before || closed }
                }
                if settled {
                    post(.keyDown, key: "\r", code: 36)
                    post(.keyUp, key: "\r", code: 36)
                    if await wait(3, { closed && sent != nil }) { return sent == title ? .chosen : .failed }
                }
            }
            let menuRow = !opened ? "none" : closed ? "a row" : (outline.item(atRow: outline.clickedRow) as? FileNode)?.name ?? "row \(outline.clickedRow)"
            if !closed { menu.cancelTracking() }
            _ = await wait(2) { closed || !opened }
            note("new file: the menu for “\(url.lastPathComponent)” did not take “\(title)” (try \(attempt): opened \(opened) for \(menuRow), "
                 + "highlighted \(menu.highlightedItem?.title ?? "nothing"), app left the front \(leftFront || !NSApp.isActive))")
            onlyLeftFront = onlyLeftFront && (leftFront || !NSApp.isActive)
            await pause(0.5)
        }
        return onlyLeftFront ? .skipped : .failed
    }

    /// Typed into the name being edited, a key at a time, as the window hands keys over.
    private static func typeName(_ text: String, in sidebar: ProjectSidebarView) {
        // Select all first, as the name's stem is: the whole name is replaced.
        (sidebar.outline.window?.firstResponder as? NSTextView)?.selectAll(nil)
        for character in text { press(sidebar, String(character), 0) }
    }

    private static func press(_ sidebar: ProjectSidebarView, _ key: String, _ code: UInt16) {
        guard let window = sidebar.outline.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }
}
