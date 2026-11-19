import AppKit
import NextTermCore

/// The Services rows' cells, menu (right-click and ⋯) and what its items do.
extension ProjectSidebarView {
    func serviceCell(for item: Any) -> NSView {
        let id = NSUserInterfaceItemIdentifier("service")
        let cell = outline.makeView(withIdentifier: id, owner: self) as? ServiceCellView ?? ServiceCellView()
        cell.identifier = id
        if let service = item as? ServiceItem {
            cell.configure(service)
            cell.onMenu = { [weak self, weak service] in
                guard let self, let service else { return NSMenu() }
                return self.serviceMenu(for: service.row)
            }
        } else {
            cell.configureGroup(servicesGroup)
            cell.onMenu = nil
        }
        return cell
    }

    /// The right-click menu of a Services row or of the group's own row, nil for any other row.
    func servicesMenu(forRow row: Int) -> NSMenu? {
        let item = row >= 0 ? outline.item(atRow: row) : nil
        if let service = item as? ServiceItem { return serviceMenu(for: service.row) }
        if item is ServicesGroup { return servicesGroupMenu() }
        if item is RunOfferItem, outline.parent(forItem: item) as AnyObject? === servicesGroup { return servicesGroupMenu() }
        return nil
    }

    /// Each of the service's pages ("Open Qdrant Dashboard", the first with Open Service Page's key), then Copy Service
    /// Name and Reveal Source File, with the keys of the database rows' same commands.
    func serviceMenu(for row: ServiceRow) -> NSMenu {
        let menu = NSMenu(title: "Service")
        addServicePages(row.links, to: menu)
        if let runtime = row.runtime { addRuntimeItems(runtime, to: menu) }
        let copy = addServiceItem(to: menu, "Copy Service Name", #selector(copyServiceName(_:)), "sidebar.copyName")
        copy.representedObject = row.name
        if let file = row.sourceFile {
            let reveal = addServiceItem(to: menu, "Reveal Source File", #selector(revealServiceSource(_:)), "sidebar.revealSource")
            reveal.representedObject = file
        }
        return menu
    }

    /// A model server's: Start Server in a Tab, Pull Model (the models the files name, each typed for your Return; or
    /// Pull Model…, which types the start of the command for you to finish), and Copy Base URL.
    func addRuntimeItems(_ runtime: LocalRuntime, to menu: NSMenu) {
        if let start = runtime.start {
            let item = menu.addItem(withTitle: "Start Server in a Tab", action: #selector(startServiceServer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = start
            item.toolTip = "Runs “\(start)” in a new tab in the project’s folder"
        }
        if let pull = runtime.pull {
            if runtime.models.isEmpty {
                let item = menu.addItem(withTitle: "Pull Model…", action: #selector(typeServiceCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pull + " "
                item.toolTip = "Types “\(pull) ” in a new tab, for you to name the model"
            } else {
                let parent = menu.addItem(withTitle: "Pull Model", action: nil, keyEquivalent: "")
                let models = NSMenu(title: "Pull Model")
                for model in runtime.models {
                    guard let command = runtime.pullCommand(model) else { continue }
                    let item = models.addItem(withTitle: model, action: #selector(typeServiceCommand(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = command
                    item.toolTip = "Types “\(command)” in a new tab, for you to run"
                }
                models.addItem(.separator())
                let other = models.addItem(withTitle: "Other Model…", action: #selector(typeServiceCommand(_:)), keyEquivalent: "")
                other.target = self
                other.representedObject = pull + " "
                parent.submenu = models
            }
        }
        let copy = menu.addItem(withTitle: "Copy Base URL", action: #selector(copyServiceBaseURL(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = runtime.baseURL
        copy.toolTip = runtime.baseURL
    }

    /// Runs a model server's start command in a new tab in the project's folder, then looks at its port again shortly
    /// after: the server prints no address a tab would notice.
    @objc func startServiceServer(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? String, let root else { return }
        delegate?.sidebar(self, command: command, in: root.path, submit: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkServicePorts() }
    }

    /// Types a command (`ollama pull llama3.2`) in a new tab in the project's folder, without Return.
    @objc func typeServiceCommand(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? String, let root else { return }
        delegate?.sidebar(self, command: command, in: root.path, submit: false)
    }

    @objc func copyServiceBaseURL(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    // MARK: is it up

    /// One look at the ports of the local rows (LoopbackPorts), off the main thread, when the group shows: after a
    /// scan, when it opens, when the window comes forward, when a tab's served address changes. Never on a timer. A row
    /// whose port answers gets a green dot; one that does not, nothing.
    func checkServicePorts() {
        guard let root, !browsingOnly else { return }
        let group = servicesGroup
        let rows = group.items.map(\.row)
        guard !LoopbackPorts.ports(rows).isEmpty else { return }
        guard window != nil, !isHiddenOrHasHiddenAncestor, outline.row(forItem: group) >= 0,
              outline.isItemExpanded(group) else { return }
        group.portLook += 1
        let look = group.portLook
        let path = root.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let up = LoopbackPorts.check(rows)
            DispatchQueue.main.async {
                guard let self, self.root?.path == path, self.servicesGroup.portLook == look else { return }
                self.showRunning(up)
            }
        }
    }

    /// Redraws the rows whose running state changed.
    func showRunning(_ up: Set<String>) {
        let changed = servicesGroup.update(running: up)
        guard !changed.isEmpty else { return }
        for item in changed where outline.row(forItem: item) >= 0 { outline.reloadItem(item) }
        refreshToolTips()
    }

    // MARK: offers

    /// Looks for the model servers the rows name (Ollama, LM Studio), off the main thread, and shows a quiet line for
    /// each one this Mac lacks, as the Run group does. Nothing is looked for while no row names one.
    func lookForServiceTools() {
        guard let root, !browsingOnly else { return }
        let needs = servicesGroup.scan.tools
        let path = root.path
        guard !needs.isEmpty else {
            if servicesGroup.update(offers: []) { reloadServicesGroup() }
            return
        }
        let look = Self.runToolLook
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let offers = ProjectTools.offers(for: needs, look())
            DispatchQueue.main.async {
                guard let self, self.root?.path == path, self.servicesGroup.scan.tools == needs else { return }
                if self.servicesGroup.update(offers: offers) { self.reloadServicesGroup() }
            }
        }
    }

    private func reloadServicesGroup() {
        guard let root else { return }
        invalidateRows(of: root)
        invalidateRows(of: servicesGroup)
        if outline.row(forItem: servicesGroup) >= 0 { outline.reloadItem(servicesGroup, reloadChildren: true) }
        refreshToolTips()
    }

    /// The group's own row: Refresh Services, the sidebar's one scan of the project's files.
    func servicesGroupMenu() -> NSMenu {
        let menu = NSMenu(title: "Services")
        addServiceItem(to: menu, "Refresh Services", #selector(refreshServicesFromMenu), "sidebar.refresh")
        return menu
    }

    @discardableResult
    private func addServiceItem(to menu: NSMenu, _ title: String, _ action: Selector, _ command: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        KeyboardShortcuts.show(command, on: item)
        return item
    }

    /// Double-click or ⌘↓: the row's main page, the one its badge opens.
    func openService(_ row: ServiceRow) {
        ServiceLinks.open(row.link.url, from: window)
    }

    /// A double-click on a Services row opens its main page; on the group's own row it opens or closes the group. False
    /// for any other row.
    func doubleClickedService(_ item: Any?) -> Bool {
        if let service = item as? ServiceItem {
            openService(service.row)
            return true
        }
        guard item is ServicesGroup else { return false }
        toggle(servicesGroup)
        return true
    }

    /// The group's rows appeared in this project's tree: it opens, stays closed if you closed it here, or opens with the
    /// project's folder. Closed is set too, as the outline can show the one group object open from another project.
    func servicesGroupAppeared() {
        guard let root else { return }
        let group = servicesGroup
        switch group.expansion.rowsAppeared(in: root.path, rootIsOpen: outline.isItemExpanded(root)) {
        case .expand: outline.expandItem(group)
        case .collapse: if outline.isItemExpanded(group) { outline.collapseItem(group) }
        case .waitForRoot: break
        }
    }

    /// Keeps the Services group as you left it: one you closed stays closed for this project (not one that closed with
    /// the project's folder), and one found while the folder was closed opens with it. True when `item` is the group, so
    /// the notification needs nothing more.
    func servicesGroupExpansion(_ item: Any, _ name: Notification.Name) -> Bool {
        guard let root else { return false }
        let group = servicesGroup
        let opened = name == NSOutlineView.itemDidExpandNotification
        if item is ServicesGroup {
            if opened {
                group.expansion.groupOpened(in: root.path)
                checkServicePorts()
            }
            if name == NSOutlineView.itemDidCollapseNotification {
                group.expansion.groupClosed(in: root.path, rootIsOpen: outline.isItemExpanded(root))
            }
            return true
        }
        // The wait is this project's own: a switch that opens another project's saved folder leaves the group alone.
        if item as AnyObject === root, opened, group.expansion.rootOpened(root.path), !group.items.isEmpty {
            outline.expandItem(group)
        }
        return false
    }

    /// The service's name ("Qdrant"), never an address or a key.
    @objc func copyServiceName(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    /// Selects the file that named the service in the tree; its contents are not opened.
    @objc func revealServiceSource(_ sender: Any?) {
        guard let file = (sender as? NSMenuItem)?.representedObject as? String, let root else { return }
        reveal((root.path as NSString).appendingPathComponent(file))
    }

    @objc func refreshServicesFromMenu() { scanDatabases() }
}
