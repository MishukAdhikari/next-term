import AppKit
import NextTermCore

/// The Databases rows' menu (right-click and ⋯) and what its items do.
extension ProjectSidebarView {
    /// Open (SQLite), the hand-offs that apply, Copy Connection Name, Reveal Source File. Remote rows get
    /// no terminal hand-off, and TablePlus asks first (its title ends in an ellipsis).
    func databaseMenu(for db: DetectedDatabase) -> NSMenu {
        let menu = NSMenu(title: "Database")
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = db
        }
        if db.engine == .sqlite, db.isConnection { add("Open", #selector(openDatabaseFromMenu(_:))) }
        if DatabaseHandOff.tablePlusOpens(db), DatabaseHandOff.tablePlus != nil {
            add(db.environment == .remote ? "Open in TablePlus…" : "Open in TablePlus", #selector(openInTablePlusFromMenu(_:)))
        }
        if let client = DatabaseHandOff.terminalClient(for: db) {
            add("Open \(client.name) in New Tab", #selector(openInTerminalFromMenu(_:)))
        }
        if databaseScan.isVercelLinked || db.providers.contains(.vercel), DatabaseHandOff.vercelCLI != nil {
            add("Open in Vercel", #selector(openInVercelFromMenu(_:)))
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add("Copy Connection Name", #selector(copyDatabaseName(_:)))
        if db.sourceFile != nil { add("Reveal Source File", #selector(revealDatabaseSource(_:))) }
        return menu
    }

    /// Double-click or ⌘↓: a SQLite file opens in the viewer; anything else shows its menu.
    func openDatabase(_ db: DetectedDatabase) {
        if db.engine == .sqlite, db.isConnection { return delegate?.sidebar(self, database: db, perform: .open) ?? () }
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp {
            NSMenu.popUpContextMenu(databaseMenu(for: db), with: event, for: outline)
        } else {
            NSSound.beep()
        }
    }

    private func database(of sender: Any?) -> DetectedDatabase? { (sender as? NSMenuItem)?.representedObject as? DetectedDatabase }

    @objc func openDatabaseFromMenu(_ sender: Any?) {
        if let db = database(of: sender) { delegate?.sidebar(self, database: db, perform: .open) }
    }

    @objc func openInTablePlusFromMenu(_ sender: Any?) {
        if let db = database(of: sender) { delegate?.sidebar(self, database: db, perform: .tablePlus) }
    }

    @objc func openInTerminalFromMenu(_ sender: Any?) {
        if let db = database(of: sender) { delegate?.sidebar(self, database: db, perform: .terminal) }
    }

    @objc func openInVercelFromMenu(_ sender: Any?) {
        if let db = database(of: sender) { delegate?.sidebar(self, database: db, perform: .vercel) }
    }

    /// The row's name (the database's or the file's), never its connection.
    @objc func copyDatabaseName(_ sender: Any?) {
        guard let db = database(of: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(db.name, forType: .string)
    }

    /// Selects the env file (or config) it came from in the tree; its contents are not opened.
    @objc func revealDatabaseSource(_ sender: Any?) {
        guard let db = database(of: sender), let file = db.sourceFile, let root else { return }
        reveal((root.path as NSString).appendingPathComponent(file))
    }
}
