import AppKit
import NextTermCore

/// A New Terminal window sets off none of macOS's privacy prompts. In a home folder of the part's own
/// (ProtectedPlaces.homeForTest), with a Desktop, a Documents, a Downloads, Pictures and a ~/Library in it, the window's
/// sidebar says "No project open", lists no file and reads no git there; `cd` into a repository in it brings that
/// project's tree with Open as Project Window, and back home the tree goes again. From a folder above the home, whose
/// tree the window shows, no walk it starts on its own (the Databases scan, Go to File) lists a protected place, by the
/// walks' own record of what they list (ProtectedPlaces.listed, debug builds only), while it does list the home's other
/// folders. NEXTTERM_SELFTEST_ONLY=newTerminal runs it alone.
extension SelfTest {
    static func newTerminalChecks() async {
        #if DEBUG
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-newterm-\(getpid())"
        try? fm.removeItem(atPath: base)
        let home = base + "/ada"
        let repo = home + "/Code/app"
        let folders = ["Desktop", "Documents/site", "Downloads/sdk", "Pictures", "Library/Caches", "Library/Mobile Documents",
                       "Code/notes", "Code/app/src"]
        for folder in folders { try? fm.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true) }
        // SQLite files where the Databases scan looks: one it may find, and three it must never reach.
        let sqlite = Data("SQLite format 3\0".utf8) + Data(count: 84)
        for file in ["Code/notes/kept.sqlite", "Documents/site/data.sqlite", "Desktop/notes.db", "Library/Caches/cache.db"] {
            fm.createFile(atPath: home + "/" + file, contents: sqlite)
        }
        try? "print(1)\n".write(toFile: repo + "/src/main.swift", atomically: true, encoding: .utf8)
        if let git = GitRunner.locateGit() {
            gitOutput(git, repo, ["init", "-q"])
        } else {
            try? fm.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true) // a work tree, for ProjectRoot
        }
        ProtectedPlaces.homeForTest = home
        let places = ProtectedPlaces.current
        ProtectedPlaces.listed.start()
        let w = app.openWindow(directory: home)
        defer {
            _ = ProtectedPlaces.listed.stop()
            ProtectedPlaces.homeForTest = nil
            w.fileFinder.close()
            if !w.hasClosed { w.window?.close() }
            try? fm.removeItem(atPath: base)
        }
        if !w.isSidebarVisible { w.setSidebarVisible(true) } // this window's, not the setting
        guard let tab = w.activeTab, await wait(20, { tab.status.integrated }) else {
            return check(false, "new terminal: the window's shell starts in its home folder")
        }
        w.refresh()

        // In the home folder: no project, so nothing listed, watched or read.
        let sidebar = w.sidebar
        let empty: Bool = sidebar.showsNoProject && sidebar.root == nil && sidebar.outline.numberOfRows == 0
        check(empty && sidebar.projectOffer.isHidden,
              "new terminal: in the home folder the sidebar shows “No project open” and lists no file",
              "no project \(sidebar.showsNoProject), root \(sidebar.root?.path ?? "none"), \(sidebar.outline.numberOfRows) rows")
        let recents: [String] = Array(app.recentProjects.prefix(NoProjectView.recentLimit))
        let ways: [String] = [sidebar.noProject.openRow.title, sidebar.noProject.connectRow.title]
        check(sidebar.noProject.listed == recents && ways == ["Open Folder…", "Connect to Server…"],
              "new terminal: it offers the recent projects, Open Folder… and Connect to Server…",
              "\(sidebar.noProject.listed) | \(ways)")
        await pause(1.5) // a scan or a git read would have started by now
        check(sidebar.git.snapshot == nil && sidebar.databaseScan == DatabaseScan(),
              "new terminal: and reads no git status and scans nothing there")

        // Into a repository in it: its tree, as today, and Open as Project Window.
        tab.view.send(txt: "cd \(ShellQuote.quote(repo))\r")
        let project = canonicalPath(repo)
        let followed = await wait(10) { () -> Bool in
            w.refresh()
            return sidebar.root?.path == project
        }
        _ = await wait(4) { sidebar.root?.children?.map(\.name) == ["src"] }
        check(followed && !sidebar.showsNoProject && sidebar.root?.children?.map(\.name) == ["src"],
              "new terminal: cd into a repository shows its tree", sidebar.root?.path ?? "no root")
        check(!sidebar.projectOffer.isHidden && sidebar.projectOffer.folder == project
                && sidebar.projectOffer.button.title == "Open as Project Window",
              "new terminal: and offers Open as Project Window for it", sidebar.projectOffer.folder ?? "none")

        // Home again (the part's own: a bare `cd` is the user's): the tree goes.
        tab.view.send(txt: "cd \(ShellQuote.quote(home))\r")
        let emptyAgain = await wait(10) { () -> Bool in
            w.refresh()
            return sidebar.showsNoProject
        }
        check(emptyAgain && sidebar.root == nil && sidebar.projectOffer.isHidden, "new terminal: back in the home folder the tree goes again")

        // Above the home folder: a folder the window shows, whose scans must leave the home's protected places out.
        let scans: Int = sidebar.databaseScanStats.read
        tab.view.send(txt: "cd \(ShellQuote.quote(base))\r")
        let scanned = await wait(15) { () -> Bool in
            w.refresh()
            return sidebar.root?.path == base && sidebar.databaseScanStats.read > scans
        }
        let found = await wait(5) { sidebar.databaseScan.databases.map(\.name) == ["kept.sqlite"] }
        check(scanned && found, "new terminal: from above the home folder the Databases scan finds what is outside its protected places",
              "\(sidebar.databaseScan.databases.map(\.name)) | \(sidebar.databaseScanStats)")
        w.goToFile(nil)
        let listedFiles = await wait(10) { w.fileFinder.footerText.contains("files") }
        w.fileFinder.close()
        let listed: [String] = ProtectedPlaces.listed.stop()
        let entered: [String] = listed.filter { (folder: String) -> Bool in places.holds(folder) }
        let walked: Bool = listed.contains(home + "/Code") && listed.contains(home + "/Code/notes")
        check(listedFiles && walked && entered.isEmpty,
              "new terminal: no scan the window started listed a protected place (Desktop, Documents, Downloads, Pictures, ~/Library)",
              entered.isEmpty ? "walked the others: \(walked), Go to File listed: \(listedFiles)" : entered.joined(separator: ", "))
        #endif
    }
}
