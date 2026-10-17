import AppKit
import NextTermCore

/// The Secrets menu, after Agents, whose servers and commands use its keys: Show Secrets, Add Key…, Import From, Keys
/// Due to Rotate, Show Key Request, Pause Key Requests for 1 Hour… (Resume Key Requests while paused) and Revoke All
/// Approvals…. Each acts through the Secrets window or a sheet: Add Key… and the imports open their sheets on the list
/// in front; a due key opens Rotate…; Pause and Revoke All confirm in a sheet on the list, Cancel the default; Resume
/// says so under the list; Show Key Request only brings the request's own window forward and answers nothing.
///
/// No item reveals or copies a value, and no title, tooltip or badge holds one: key names and counts only. No item has a
/// default key; Settings › Keyboard Shortcuts lists the fixed ones under "Secrets", so any can be given one. The static
/// items are made once here and keep their identity, so a key the user gave one stays on it. The due rows are rebuilt
/// each time their submenu opens, from memory only, and are never commands: the submenu is empty when the menus are
/// captured, and never asked for keys.
@MainActor
final class SecretsMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = SecretsMenu()

    private(set) weak var menu: NSMenu?
    /// Keys Due to Rotate: its parent item, which carries the badge, and the submenu rebuilt on open.
    private(set) var dueItem: NSMenuItem?
    let dueMenu = NSMenu(title: SecretsMenuModel.dueTitle)
    private(set) var requestItem: NSMenuItem?
    private(set) var pauseItem: NSMenuItem?
    private var observers: [NSObjectProtocol] = []

    #if DEBUG
    /// The self-test's answer to the Pause confirm, given at once in place of the sheet.
    static var answerPause: NSApplication.ModalResponse?
    #endif

    /// The menu's items, under `menu`.
    func fill(_ menu: NSMenu) {
        self.menu = menu
        let show = NSMenuItem(title: SecretsMenuModel.showTitle, action: #selector(AppDelegate.showSecrets(_:)), keyEquivalent: "")
        show.target = AppDelegate.shared
        menu.addItem(show)
        add(menu, SecretsMenuModel.addTitle, #selector(addSecretKey(_:)))
        menu.addItem(importItem())
        menu.addItem(.separator())
        dueMenu.delegate = self
        let due = NSMenuItem(title: SecretsMenuModel.dueTitle, action: nil, keyEquivalent: "")
        due.submenu = dueMenu
        menu.addItem(due)
        dueItem = due
        menu.addItem(.separator())
        requestItem = add(menu, SecretsMenuModel.showRequestTitle, #selector(showKeyRequest(_:)))
        pauseItem = add(menu, SecretsMenuModel.pauseItemTitle, #selector(toggleKeyRequestPause(_:)))
        add(menu, SecretsMenuModel.revokeAllTitle, #selector(revokeAllSecretApprovals(_:)))
        follow()
    }

    /// Import From: A File… and MCP Configs…, then the password managers, one action told apart by its preset.
    private func importItem() -> NSMenuItem {
        let imports = NSMenu(title: SecretsMenuModel.importTitle)
        add(imports, SecretsMenuModel.importFileTitle, #selector(importSecretsFromFile(_:)), tip: SecretsMenuModel.importFileHelp)
        add(imports, SecretsMenuModel.importMCPTitle, #selector(importSecretsFromMCPConfigs(_:)), tip: SecretsMenuModel.importMCPHelp)
        imports.addItem(.separator())
        for preset in SecretImportPreset.allCases {
            add(imports, SecretsMenuModel.managerTitle(preset), #selector(importSecretsFromManager(_:)), preset.rawValue,
                tip: SecretsMenuModel.importManagerHelp)
        }
        let item = NSMenuItem(title: SecretsMenuModel.importTitle, action: nil, keyEquivalent: "")
        item.submenu = imports
        return item
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ value: String? = nil, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.toolTip = tip
        menu.addItem(item)
        return item
    }

    /// The badges follow the vault, the reminders' checks and the requests. The first waits a turn of the run loop, so
    /// the menus are captured with their plain titles where macOS 13 puts the count in the title.
    private func follow() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [SecretsStore.changed, SecretReminders.checked, SecretRequests.changed]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBadges() }
            })
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
    }
}

// MARK: state, badges and the list in front

extension SecretsMenu {
    /// What the items follow, read from memory: the store as last loaded, the requests and the approvals.
    static func state() -> SecretsMenuModel.State {
        let requests = SecretRequests.shared
        return SecretsMenuModel.State(broken: isBroken, showingRequest: requests.showing != nil, waiting: requests.waitingCount,
                                      grants: requests.grants.count, pausedUntil: requests.pausedUntil)
    }

    /// The vault can't be opened on this Mac, or was changed outside Next Term: the list's own rule.
    static var isBroken: Bool {
        let protection: SecretsStore.Protection = SecretsStore.shared.protection
        return protection == .cantOpen || protection == .tampered
    }

    /// Keys due now, as the due rows count them; none while the vault is broken.
    static func dueCount() -> Int {
        let entries: [SecretVault.Entry] = SecretsStore.shared.index?.entries ?? []
        return SecretsMenuModel.dueCount(entries: entries, broken: isBroken, now: SecretReminders.currentDate())
    }

    /// Keys Due to Rotate's count and Show Key Request's. The menu bar's "Secrets" never shows one: its width would
    /// change, moving the menus after it.
    func refreshBadges() {
        if let dueItem { Self.show(Self.dueCount(), title: SecretsMenuModel.dueTitle, on: dueItem) }
        let requests: Int = SecretsMenuModel.requestCount(Self.state())
        if let requestItem { Self.show(requests, title: SecretsMenuModel.showRequestTitle, on: requestItem) }
    }

    /// `count` on `item`: a badge where macOS has them, else in its title, as Skills… shows its updates.
    static func show(_ count: Int, title: String, on item: NSMenuItem) {
        if #available(macOS 14.0, *) {
            item.title = title
            item.badge = count > 0 ? NSMenuItemBadge(count: count) : nil
        } else {
            item.title = SecretsMenuModel.countedTitle(title, count: count)
        }
    }

    /// The list the menu acts on: Settings › Secrets when that tab is the key window's (a sheet on it counts), else the
    /// Secrets window, brought forward (it reloads if the vault changed).
    func frontList() -> SecretsView? {
        let key: NSWindow? = NSApp.keyWindow
        let window: NSWindow? = key?.sheetParent ?? key
        if let tabs = window?.contentView as? NSTabView, let tab = tabs.selectedTabViewItem,
           tab.identifier as? String == "secrets", let view = tab.view as? SecretsView {
            return view
        }
        SecretsWindowController.show()
        return SecretsWindowController.shared?.secretsView
    }

    /// The front list, read again, when it has no sheet open; with one, it says to finish that first, and nothing else
    /// opens over it.
    func freeList() -> SecretsView? {
        guard let view = frontList() else { return nil }
        view.reload()
        guard !view.hasOpenSheet else {
            view.say(SecretsMenuModel.busyLine)
            return nil
        }
        return view
    }

    // MARK: on and off

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let state: SecretsMenuModel.State = Self.state()
        switch item.action {
        case #selector(addSecretKey(_:)): return SecretsMenuModel.isEnabled(.add, state)
        case #selector(importSecretsFromFile(_:)): return SecretsMenuModel.isEnabled(.importFile, state)
        case #selector(importSecretsFromMCPConfigs(_:)): return SecretsMenuModel.isEnabled(.importMCP, state)
        case #selector(importSecretsFromManager(_:)): return SecretsMenuModel.isEnabled(.importManager, state)
        case #selector(rotateDueSecret(_:)): return !state.broken
        case #selector(showKeyRequest(_:)):
            let on: Bool = SecretsMenuModel.isEnabled(.showRequest, state)
            item.toolTip = on ? SecretsMenuModel.showRequestHelp : SecretsMenuModel.noRequestHelp
            return on
        case #selector(toggleKeyRequestPause(_:)):
            item.title = SecretsMenuModel.pauseTitle(state.pausedUntil)
            item.toolTip = state.pausedUntil.map { (until: Date) -> String in
                SecretsMenuModel.pausedHelp(SecretRequests.clockText(until))
            } ?? SecretsMenuModel.pauseHelp
            return SecretsMenuModel.isEnabled(.pause, state)
        case #selector(revokeAllSecretApprovals(_:)):
            let on: Bool = SecretsMenuModel.isEnabled(.revokeAll, state)
            let help: String = SecretsMenuModel.revokeAllHelp + " " + SecretsView.revokeHelp
            item.toolTip = on ? help : SecretsMenuModel.noGrantsHelp
            return on
        default: return true
        }
    }
}

// MARK: actions

extension SecretsMenu {
    /// Add…'s sheet on the list in front, as its button opens it; off, the list's line already says why.
    @objc func addSecretKey(_ sender: Any?) {
        guard let view = freeList(), view.addButton.isEnabled else { return }
        view.add()
    }

    /// Import From › A File…: the open panel as a sheet on the list.
    @objc func importSecretsFromFile(_ sender: Any?) {
        guard let view = freeList(), view.importMenuButton.isEnabled else { return }
        view.importFromFile()
    }

    /// Import From › MCP Configs…: its sheet, which keeps its own refusals (agent control off, no lasting nxtrm).
    @objc func importSecretsFromMCPConfigs(_ sender: Any?) {
        guard let view = freeList(), view.importMenuButton.isEnabled else { return }
        view.importKeys()
    }

    /// Import From › 1Password…, Bitwarden… or Bitwarden Secrets Manager…: the item's preset, as the list's pull-down.
    @objc func importSecretsFromManager(_ sender: NSMenuItem) {
        guard let view = freeList(), view.importMenuButton.isEnabled else { return }
        view.importFromManager(sender)
    }

    /// A due key: the notification click's path, which selects it and opens Rotate…, or says why it can't.
    @objc func rotateDueSecret(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SecretReminders.open(SecretReminder(name: name, kind: .due))
    }

    /// Show All N in Secrets: several due keys' notification click, the first due key selected.
    @objc func showAllDueSecrets(_ sender: NSMenuItem) {
        guard let first = sender.representedObject as? String else { return }
        SecretReminders.open(SecretReminder(name: first, kind: .severalDue))
    }

    /// The waiting request's own window in front, never made key; the user answers it there.
    @objc func showKeyRequest(_ sender: Any?) {
        SecretRequests.shared.bringShowingToFront()
    }

    /// Paused: Resume, on the list, which says so. Else Pause's confirm, a sheet on the list with Cancel the default; or
    /// over an agent's import sheet, which has no Pause of its own and which Pause ends (Cancel leaves it as it was).
    @objc func toggleKeyRequestPause(_ sender: Any?) {
        let requests = SecretRequests.shared
        if requests.pausedUntil != nil {
            guard let view = frontList() else { return }
            requests.resumeAsking()
            return view.say(SecretsMenuModel.resumedLine)
        }
        guard let view = frontList() else { return }
        view.reload()
        let ask: SecretImportAsk? = requests.importAsk(sheetOn: view.window)
        let only: Bool = ask != nil && ask?.sheetWindow?.attachedSheet == nil
        let route: SecretsMenuModel.PauseConfirm = SecretsMenuModel.pauseConfirm(listHasSheet: view.hasOpenSheet,
                                                                                 requestSheetOnly: only,
                                                                                 copying: ask?.isCopying == true)
        guard route != .busy else { return view.say(SecretsMenuModel.busyLine) }
        #if DEBUG
        if let answer = Self.answerPause {
            if answer == .alertFirstButtonReturn { pause(view) }
            return
        }
        #endif
        let over: NSWindow? = route == .overRequest ? ask?.sheetWindow : nil
        view.confirm(SecretApprovalPanel.makePauseAlert(fromMenu: true), over: over) { [weak self, weak view] in
            guard let view else { return }
            self?.pause(view)
        }
    }

    /// The hour's pause, as the panel's Pause gives it: every waiting request declined, every approval ended.
    private func pause(_ view: SecretsView) {
        SecretRequests.shared.pauseForAnHour(from: nil)
        view.reload()
    }

    /// Revoke All Approvals…' confirm, a sheet on the list saying how many it ends, with Cancel the default. The count
    /// follows the approvals while it shows (one allowed in the panel meanwhile, one expiring); with none left, it goes.
    @objc func revokeAllSecretApprovals(_ sender: Any?) {
        let count: Int = SecretRequests.shared.grants.count
        guard count > 0, let view = freeList() else { return }
        let alert: NSAlert = Self.makeRevokeAlert(count: count)
        let watch: NSObjectProtocol = NotificationCenter.default.addObserver(forName: SecretRequests.changed, object: nil,
                                                                             queue: .main) { [weak alert, weak view] _ in
            MainActor.assumeIsolated {
                guard let alert else { return }
                Self.recount(alert, on: view)
            }
        }
        let shown: Bool = view.confirm(alert, ended: { NotificationCenter.default.removeObserver(watch) }) {
            SecretRequests.shared.revokeAll()
        }
        if !shown { NotificationCenter.default.removeObserver(watch) }
    }

    /// The Revoke confirm's count, as the approvals are now; with none left it goes, and the line says so.
    static func recount(_ alert: NSAlert, on view: SecretsView?) {
        let count: Int = SecretRequests.shared.grants.count
        guard count > 0 else {
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
            view?.say(SecretsMenuModel.noGrantsHelp)
            return
        }
        let text: String = SecretsMenuModel.revokeConfirmText(count)
        guard alert.informativeText != text else { return }
        alert.informativeText = text
        alert.layout()
    }

    static func makeRevokeAlert(count: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = SecretsMenuModel.revokeConfirmTitle
        alert.informativeText = SecretsMenuModel.revokeConfirmText(count)
        alert.addButton(withTitle: SecretsMenuModel.revokeButton).keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r" // Return cancels
        return alert
    }
}

// MARK: Keys Due to Rotate

extension SecretsMenu {
    /// The due rows, rebuilt each time the submenu opens from the index in memory: no disk read, no reload, no Touch ID.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === dueMenu else { return }
        fillDue(menu)
    }

    /// Its rows never have keys, so AppKit never fills it while it matches a key press. The top Secrets menu has no
    /// delegate: answering false there would stop the keys the user gave its items.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    /// The rows: each due key in the list's order, at most ten, then Show All; or one row, off, saying none is due or
    /// that Secrets can't change its keys now. The badge follows what was read.
    func fillDue(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = SecretsStore.shared
        let entries: [SecretVault.Entry] = store.index?.entries ?? []
        let rows: [SecretsMenuModel.DueRow] = SecretsMenuModel.dueRows(entries: entries, broken: Self.isBroken,
                                                                        now: SecretReminders.currentDate())
        for row in rows {
            switch row {
            case .key(let name, let help):
                let item = NSMenuItem(title: name, action: #selector(rotateDueSecret(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.toolTip = help
                menu.addItem(item)
            case .more(let count, let first):
                menu.addItem(.separator())
                let item = NSMenuItem(title: SecretsMenuModel.moreTitle(count), action: #selector(showAllDueSecrets(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = first
                menu.addItem(item)
            case .none:
                menu.addItem(Self.offRow(SecretsMenuModel.noneDueTitle, tip: SecretsMenuModel.noneDueHelp))
            case .cantChange:
                let line: String = SecretsView.statusText(store.protection, waitingForKeychain: store.isWaitingForKeychain,
                                                          unlisted: store.isUnlisted, tooLarge: store.isTooLarge)
                menu.addItem(Self.offRow(SecretsMenuModel.cantChangeTitle, tip: line))
            }
        }
        refreshBadges()
    }

    /// A row with no action, so the menu shows it off.
    private static func offRow(_ title: String, tip: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tip
        return item
    }
}
