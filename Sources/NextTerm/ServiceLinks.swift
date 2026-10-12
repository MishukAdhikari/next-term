import AppKit
import NextTermCore

/// The one way a service's page opens, from a badge or a menu item. The link is checked again (`SafeWebLink`): links
/// are built valid, so a refusal can only be a bug, met with a beep and nothing opened. Then it opens as a web link
/// ⌘-clicked in the terminal does (WebLinks), so a LangGraph Studio link opens in a browser where Studio works.
enum ServiceLinks {
    static func open(_ url: URL, from window: NSWindow?) {
        guard SafeWebLink.isAllowed(url) else { return NSSound.beep() }
        #if DEBUG
        if recordsOnly {
            opened.append(url)
            return
        }
        #endif
        WebLinks.open(url, from: window)
    }

    #if DEBUG
    /// The self-test turns this on: each page that would open is recorded in `opened`, and nothing opens.
    nonisolated(unsafe) static var recordsOnly = false
    nonisolated(unsafe) static var opened: [URL] = []
    #endif
}

extension ProjectSidebarView {
    /// A row's pages at the top of its menu, "Open Neon Console", "Open Vercel Storage", then a separator. Only the first
    /// is Open Service Page's item and shows its key, so one key opens one page.
    func addServicePages(_ links: [ServiceLink], to menu: NSMenu) {
        for (index, link) in links.enumerated() {
            let item = menu.addItem(withTitle: link.title, action: #selector(openServicePageFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = link
            item.toolTip = link.tooltip
            if index == 0 { KeyboardShortcuts.show("sidebar.openServicePage", on: item) }
        }
        if !links.isEmpty { menu.addItem(.separator()) }
    }

    @objc func openServicePageFromMenu(_ sender: Any?) {
        guard let link = (sender as? NSMenuItem)?.representedObject as? ServiceLink else { return }
        ServiceLinks.open(link.url, from: window)
    }
}
