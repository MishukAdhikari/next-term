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
        return nil
    }

    /// Each of the service's pages ("Open Qdrant Dashboard", the first with Open Service Page's key), then Copy Service
    /// Name and Reveal Source File, with the keys of the database rows' same commands.
    func serviceMenu(for row: ServiceRow) -> NSMenu {
        let menu = NSMenu(title: "Service")
        addServicePages(row.links, to: menu)
        let copy = addServiceItem(to: menu, "Copy Service Name", #selector(copyServiceName(_:)), "sidebar.copyName")
        copy.representedObject = row.name
        if let file = row.sourceFile {
            let reveal = addServiceItem(to: menu, "Reveal Source File", #selector(revealServiceSource(_:)), "sidebar.revealSource")
            reveal.representedObject = file
        }
        return menu
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
        let group = servicesGroup
        if outline.isItemExpanded(group) { outline.collapseItem(group) } else { outline.expandItem(group) }
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
            if opened { group.expansion.groupOpened(in: root.path) }
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
