import AppKit
import NextTermCore

/// The bar over the home folder's tree while a window with no project browses it (BreadcrumbBar), after Browse Home
/// Folder in the part's own home folder (newTerminalChecks): it starts at Home with nothing selected, follows the
/// selected row to its folder, selects a folder's row when that folder is clicked, and ⌘↑ walks up to Home and from there
/// back to "No project open", as Back does. None of it reads a folder the tree had not read. Part of
/// NEXTTERM_SELFTEST_ONLY=newTerminal.
extension SelfTest {
    #if DEBUG
    static func breadcrumbChecks(_ w: TerminalWindowController, home: String) async {
        guard let window = w.window, let tab = w.activeTab else { return }
        let sidebar = w.sidebar, bar = sidebar.breadcrumbs, outline = sidebar.outline
        let name: String = (home as NSString).lastPathComponent
        func titles() -> [String] { bar.segments.map(\.title) }
        func selectedPath() -> String? { (outline.item(atRow: outline.selectedRow) as? FileNode)?.path }

        // Shown over the tree, at Home.
        sidebar.layoutSubtreeIfNeeded()
        let treeTop: CGFloat = outline.enclosingScrollView?.frame.minY ?? -1
        check(!bar.isHidden && bar.frame.maxY == treeTop && bar.shownTitles == [name] && bar.backButton.accessibilityLabel() == "Back",
              "breadcrumbs: Browse Home Folder shows the bar over the tree, with Back and the home folder",
              "hidden \(bar.isHidden), ends at \(bar.frame.maxY) over \(treeTop), \(bar.shownTitles), back \(bar.backButton.accessibilityLabel() ?? "unlabelled")")

        // A file selected: the path to its folder. The tree reads Code, app and src here, as the user opening them would.
        sidebar.reveal(home + "/Code/app/src/main.swift")
        let followed = await wait(5) { selectedPath() == home + "/Code/app/src/main.swift" && titles() == [name, "Code", "app", "src"] }
        check(followed, "breadcrumbs: a file selected shows the path to its folder", "\(selectedPath() ?? "nothing selected"): \(titles())")

        // From here on nothing is read that the tree had not read.
        func loadedFolders(_ node: FileNode) -> [String] {
            guard let children = node.children else { return [] }
            return [node.path] + children.filter(\.isDirectory).flatMap(loadedFolders)
        }
        let loadedBefore: Set<String> = Set(sidebar.root.map(loadedFolders) ?? [])
        ProtectedPlaces.listed.start()

        // A folder clicked: its row, with the keyboard.
        bar.segmentButton(at: 1)?.performClick(nil)
        let code = await wait(3) { selectedPath() == home + "/Code" && titles() == [name, "Code"] }
        check(code && window.firstResponder === outline, "breadcrumbs: a folder clicked selects its row and gives the tree the keyboard",
              "\(selectedPath() ?? "nothing selected"): \(titles()), keyboard \(String(describing: window.firstResponder))")

        // ⌘↑: the enclosing folder, here Home's row.
        let commandUp: NSEvent.ModifierFlags = [.command, .numericPad, .function]
        pressKey("\u{F700}", code: 126, commandUp, in: window)
        let up = await wait(3) { outline.selectedRow == 0 && outline.item(atRow: 0) as AnyObject === sidebar.root && titles() == [name] }
        check(up, "breadcrumbs: ⌘↑ selects the enclosing folder", "\(selectedPath() ?? "nothing selected"): \(titles())")

        // ⌘↑ from Home: "No project open" again, the keyboard with the tab.
        pressKey("\u{F700}", code: 126, commandUp, in: window)
        let left = await wait(3) { sidebar.showsNoProject && sidebar.root == nil && !w.browsesHome && bar.isHidden }
        check(left && window.firstResponder === tab.view, "breadcrumbs: ⌘↑ from the home folder goes back to “No project open”, the keyboard to the tab",
              "no project \(sidebar.showsNoProject), browsing \(w.browsesHome), bar hidden \(bar.isHidden), keyboard \(String(describing: window.firstResponder))")

        let read: [String] = ProtectedPlaces.listed.stop()
        let unread: [String] = read.filter { !loadedBefore.contains($0) }
        check(unread.isEmpty, "breadcrumbs: the bar, its folders and ⌘↑ read nothing the tree had not read", unread.joined(separator: ", "))

        // Browse again: the tree as it was. Then Back.
        sidebar.noProject.browseRow.performClick(nil)
        let again = await wait(5) { !bar.isHidden && sidebar.root?.path == home && sidebar.root?.node(at: home + "/Code/app")?.isLoaded == true }
        check(again, "breadcrumbs: Browse Home Folder again brings the bar and the tree back as it was")
        bar.backButton.performClick(nil)
        let recents: [String] = Array(AppDelegate.shared.recentProjects.prefix(NoProjectView.recentLimit))
        let back = await wait(3) { sidebar.showsNoProject && bar.isHidden && !w.browsesHome }
        check(back && sidebar.noProject.listed == recents, "breadcrumbs: Back returns to “No project open”, with its recent projects",
              "no project \(sidebar.showsNoProject), bar hidden \(bar.isHidden), listed \(sidebar.noProject.listed)")
    }
    #endif
}
