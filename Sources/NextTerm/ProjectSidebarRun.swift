import AppKit
import NextTermCore

/// The Run rows' cells, menu (right-click and ⋯), what they do, and the look along PATH for the tools they need.
extension ProjectSidebarView {
    func runCell(for item: Any) -> NSView {
        let id = NSUserInterfaceItemIdentifier("run")
        let cell = outline.makeView(withIdentifier: id, owner: self) as? RunCellView ?? RunCellView()
        cell.identifier = id
        if let run = item as? RunItem {
            cell.configure(run)
            cell.onAction = { [weak self, weak run] in
                guard let self, let run else { return }
                self.run(run.task)
            }
            cell.onMenu = { [weak self, weak run] in
                guard let self, let run else { return NSMenu() }
                return self.runMenu(for: run.task)
            }
        } else if let offer = item as? RunOfferItem {
            cell.configure(offer)
            cell.onAction = { [weak self, weak offer] in
                guard let self, let offer else { return }
                self.delegate?.sidebar(self, install: offer.offer)
            }
            cell.onMenu = nil
        } else {
            cell.configureGroup(runGroup)
            cell.onAction = nil
            cell.onMenu = nil
        }
        return cell
    }

    /// Types the task's command into a new tab in the project's folder and runs it.
    func run(_ task: RunTask) {
        delegate?.sidebar(self, run: task)
    }

    /// The right-click menu of a Run row or of the group's own row, nil for any other row.
    func runMenu(forRow row: Int) -> NSMenu? {
        let item = row >= 0 ? outline.item(atRow: row) : nil
        if let run = item as? RunItem { return runMenu(for: run.task) }
        if item is RunGroup || item is RunOfferItem { return runGroupMenu() }
        return nil
    }

    /// Run in New Tab, Copy Command and Reveal Source File.
    func runMenu(for task: RunTask) -> NSMenu {
        let menu = NSMenu(title: "Task")
        addRunItem(to: menu, "Run in New Tab", #selector(runFromMenu(_:)), "sidebar.open").representedObject = task.command
        addRunItem(to: menu, "Copy Command", #selector(copyRunCommand(_:)), "sidebar.copyName").representedObject = task.command
        addRunItem(to: menu, "Reveal Source File", #selector(revealServiceSource(_:)), "sidebar.revealSource")
            .representedObject = task.file
        return menu
    }

    /// The group's own row: Refresh, the sidebar's one scan of the project's files, and a look along PATH again.
    func runGroupMenu() -> NSMenu {
        let menu = NSMenu(title: "Run")
        addRunItem(to: menu, "Refresh Tasks", #selector(refreshServicesFromMenu), "sidebar.refresh")
        return menu
    }

    @discardableResult
    private func addRunItem(to menu: NSMenu, _ title: String, _ action: Selector, _ command: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        KeyboardShortcuts.show(command, on: item)
        return item
    }

    @objc func runFromMenu(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? String,
              let task = runGroup.tasks.first(where: { $0.task.command == command })?.task else { return }
        run(task)
    }

    @objc func copyRunCommand(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// A double-click on a task runs it; on the group's own row it opens or closes the group. False for any other row.
    func doubleClickedRun(_ item: Any?) -> Bool {
        if let run = item as? RunItem {
            self.run(run.task)
            return true
        }
        if item is RunOfferItem { return true }
        guard item is RunGroup else { return false }
        toggle(runGroup)
        return true
    }

    // MARK: showing

    /// A scan's tasks, shown as the Services rows are: each row keeps its place, and the group opens the first time it
    /// appears unless you closed it for this project. Then a look along PATH for the tools the project needs.
    func showRun(_ scan: RunScan) {
        if runGroup.update(scan) { reloadRunGroup() }
        lookForRunTools()
    }

    /// Looks for the tools the project needs, off the main thread, and shows a line for each one missing. Nothing is
    /// looked for while the project has no task.
    func lookForRunTools() {
        guard let root, !browsingOnly else { return }
        let needs = runGroup.needs
        let path = root.path
        guard !needs.isEmpty, !runGroup.tasks.isEmpty else {
            if runGroup.update(offers: []) { reloadRunGroup() }
            return
        }
        let look = Self.runToolLook
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let offers = ProjectTools.offers(for: needs, look())
            DispatchQueue.main.async {
                guard let self, self.root?.path == path, self.runGroup.needs == needs else { return }
                if self.runGroup.update(offers: offers) { self.reloadRunGroup() }
            }
        }
    }

    /// The login shell's PATH, without a folder in a protected place (a look there would set off macOS's prompt).
    nonisolated static var runToolLook: @Sendable () -> ProjectTools.Look {
        #if DEBUG
        if let look = SelfTestRunLook.look { return look }
        #endif
        return {
            let protected = ProtectedPlaces.current
            return ProjectTools.Look(path: LoginShell.path.filter { !protected.holds($0) })
        }
    }

    private func reloadRunGroup() {
        let group = runGroup
        guard let root else { return }
        let hadRows = outline.row(forItem: group) >= 0
        invalidateRows(of: root)
        invalidateRows(of: group)
        let hasRows = !group.items.isEmpty
        if hadRows != hasRows {
            outline.reloadItem(root, reloadChildren: true)
        } else if hasRows {
            outline.reloadItem(group, reloadChildren: true)
        }
        if !hadRows, hasRows { runGroupAppeared() }
        refreshToolTips()
    }

    /// The group's rows appeared: it opens, stays closed if you closed it here, or opens with the project's folder.
    private func runGroupAppeared() {
        guard let root else { return }
        let group = runGroup
        switch group.expansion.rowsAppeared(in: root.path, rootIsOpen: outline.isItemExpanded(root)) {
        case .expand: outline.expandItem(group)
        case .collapse: if outline.isItemExpanded(group) { outline.collapseItem(group) }
        case .waitForRoot: break
        }
    }

    /// Keeps the Run group as you left it, project by project. True when `item` is the group.
    func runGroupExpansion(_ item: Any, _ name: Notification.Name) -> Bool {
        guard let root else { return false }
        let group = runGroup
        let opened = name == NSOutlineView.itemDidExpandNotification
        if item is RunGroup {
            if opened { group.expansion.groupOpened(in: root.path) }
            if name == NSOutlineView.itemDidCollapseNotification {
                group.expansion.groupClosed(in: root.path, rootIsOpen: outline.isItemExpanded(root))
            }
            return true
        }
        if item as AnyObject === root, opened, group.expansion.rootOpened(root.path), !group.items.isEmpty {
            outline.expandItem(group)
        }
        return false
    }
}

#if DEBUG
/// For the self-test: the look along PATH it gives, so an offer shows (or not) whatever this Mac has.
enum SelfTestRunLook {
    nonisolated(unsafe) static var look: (@Sendable () -> ProjectTools.Look)?
}
#endif
