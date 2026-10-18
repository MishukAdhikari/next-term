import AppKit
import NextTermCore

#if DEBUG
/// The Secrets menu, on the self-test's temporary vault with the stand-in presence check: where it sits and what it
/// lists; no key on any item and none of its commands with a default; Show Secrets; Add Key… and the imports on the list
/// in front; a broken vault and no vault; the due keys and their badge (on the self-test's day, `selfTestNow`); Show Key
/// Request; Pause and Resume; Revoke All Approvals…; and no value in any title, tooltip or badge. Keys and values are
/// made up at run time. The menus' own keys while these run, and yours back after.
extension SelfTest {
    static func secretsMenuChecks(base: URL) async {
        let requests = SecretRequests.shared
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = UserDefaults.standard.data(forKey: "keyBindings")
        let savedNow = SecretReminders.selfTestNow
        requests.resetForSelfTest()
        defer {
            requests.resetForSelfTest()
            SecretsMenu.answerPause = nil
            SecretReminders.selfTestNow = savedNow
            UserDefaults.standard.set(savedBindings, forKey: "keyBindings")
            shortcuts.apply()
        }
        shortcuts.bindings = KeyBindings()
        shortcuts.apply()
        guard let secrets = NSApp.mainMenu?.items.first(where: { $0.title == SecretsMenuModel.menuTitle })?.submenu else {
            return check(false, "secrets menu: the menu bar has it")
        }
        secretsMenuShapeChecks(secrets)
        secretsMenuCommandChecks(secrets)
        guard let view = await secretsMenuShowCheck(secrets) else { return }
        defer { SecretsWindowController.shared?.window?.close() }
        await secretsMenuBrokenChecks(secrets)
        await secretsMenuAddChecks(secrets, view)
        await secretsMenuImportChecks(secrets, view, base: base)
        await secretsMenuBusyChecks(secrets, view, base: base)
        await secretsMenuDueChecks(secrets, view)
        await secretsMenuRequestChecks(secrets)
        await secretsMenuRequestWindowCheck(secrets)
        await secretsMenuImportRequestChecks(secrets, view, base: base)
        await secretsMenuPauseChecks(secrets, view)
        await secretsMenuRevokeChecks(secrets, view)
        _ = try? await SecretsStore.shared.perform(.delete(name: "MENU_KEY"))
    }

    // MARK: helpers

    /// The item in `menu`, or in its submenus, with `action`.
    static func secretsMenuItem(_ menu: NSMenu, _ action: Selector, _ value: String? = nil) -> NSMenuItem? {
        secretsMenuItems(menu).first { (item: NSMenuItem) -> Bool in
            item.action == action && (value == nil || item.representedObject as? String == value)
        }
    }

    /// Every item of `menu` and of its submenus, as they are now.
    static func secretsMenuItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { (item: NSMenuItem) -> [NSMenuItem] in
            let inner: [NSMenuItem] = item.submenu.map { (submenu: NSMenu) -> [NSMenuItem] in secretsMenuItems(submenu) } ?? []
            return [item] + inner
        }
    }

    /// The titles as a menu shows them, a separator as "—".
    static func secretsMenuTitles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map { (item: NSMenuItem) -> String in item.isSeparatorItem ? "—" : item.title }
    }

    /// Whether the item is on, as the menu would ask when it opens; its title and tooltip follow.
    static func secretsMenuOn(_ item: NSMenuItem?) -> Bool {
        guard let item else { return false }
        return SecretsMenu.shared.validateMenuItem(item)
    }

    /// The item chosen, as a click sends its action.
    static func secretsMenuChoose(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// The count an item shows: its badge's, or in its title where macOS 13 puts it.
    static func secretsMenuCount(_ item: NSMenuItem?, title: String) -> Int {
        if #available(macOS 14.0, *) { return item?.badge?.itemCount ?? 0 }
        for count in 1...99 where item?.title == SecretsMenuModel.countedTitle(title, count: count) { return count }
        return 0
    }

    /// The Secrets window in front and key, as the menus find it.
    static func secretsMenuFocus(_ view: SecretsView) async {
        view.window?.makeKeyAndOrderFront(nil)
        _ = await wait(5) { NSApp.keyWindow === view.window }
    }
}

// MARK: shape, commands, Show Secrets

extension SelfTest {
    /// The bar's order, the items in theirs, Import From's, and the due submenu empty until it first opens and never
    /// asked for keys. The top menu has no delegate, so the keys given its items always fire.
    static func secretsMenuShapeChecks(_ secrets: NSMenu) {
        let bar: [String] = (NSApp.mainMenu?.items ?? []).dropFirst().map(\.title)
        check(bar == ["File", "Edit", "View", "Agents", "Secrets", "Git", "Notifications", "Window"],
              "secrets menu: it sits between Agents and Git", bar.joined(separator: ", "))
        let listed: [String] = secretsMenuTitles(secrets)
        let expected: [String] = [SecretsMenuModel.showTitle, SecretsMenuModel.addTitle, SecretsMenuModel.importTitle, "—",
                                  SecretsMenuModel.dueTitle, "—", SecretsMenuModel.showRequestTitle,
                                  SecretsMenuModel.pauseItemTitle, SecretsMenuModel.revokeAllTitle]
        check(listed == expected, "secrets menu: Show Secrets, Add Key…, Import From, Keys Due to Rotate, then the requests' three",
              listed.joined(separator: ", "))
        let imports: [String] = secretsMenuTitles(secrets.items.first { $0.title == SecretsMenuModel.importTitle }?.submenu)
        let managers: [String] = SecretImportPreset.allCases.map(SecretsMenuModel.managerTitle)
        let expectedImports: [String] = ["A File…", "MCP Configs…", "—"] + managers
        check(imports == expectedImports,
              "secrets menu: Import From lists A File…, MCP Configs…, then the password managers", imports.joined(separator: ", "))
        let menu = SecretsMenu.shared
        let due: NSMenu? = secrets.items.first { $0.title == SecretsMenuModel.dueTitle }?.submenu
        let isDue: Bool = due === menu.dueMenu && menu.dueMenu.items.isEmpty
        let delegated: Bool = menu.dueMenu.delegate === menu && secrets.delegate == nil
        check(isDue && delegated,
              "secrets menu: Keys Due to Rotate is empty until it first opens, and only it has a delegate",
              "\(menu.dueMenu.items.count) rows")
        let event: NSEvent? = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                               context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false,
                                               keyCode: 1)
        var target: AnyObject?
        var action: Selector?
        let asked: Bool = event.map { (event: NSEvent) -> Bool in
            withUnsafeMutablePointer(to: &target) { (targets: UnsafeMutablePointer<AnyObject?>) -> Bool in
                withUnsafeMutablePointer(to: &action) { (actions: UnsafeMutablePointer<Selector?>) -> Bool in
                    menu.menuHasKeyEquivalent(menu.dueMenu, for: event, target: AutoreleasingUnsafeMutablePointer(targets),
                                              action: actions)
                }
            }
        } ?? true
        check(!asked && menu.dueMenu.items.isEmpty, "secrets menu: Keys Due to Rotate is never filled to match a key press")
    }

    /// No item has a key; Settings › Keyboard Shortcuts lists each fixed command under Secrets with no default key, and
    /// none for a due row; Window no longer has Show Secrets' action (its open window is still in the window list).
    static func secretsMenuCommandChecks(_ secrets: NSMenu) {
        let keyed: [String] = secretsMenuItems(secrets).filter { !$0.keyEquivalent.isEmpty }.map(\.title)
        check(keyed.isEmpty, "secrets menu: no item has a key", keyed.joined(separator: ", "))
        let commands: [KeyboardShortcuts.Command] = KeyboardShortcuts.shared.commands
        let listed: [KeyboardShortcuts.Command] = commands.filter { (command: KeyboardShortcuts.Command) -> Bool in
            command.path == "Secrets" || command.path.hasPrefix("Secrets › ")
        }
        let ids: Set<String> = Set(listed.map(\.id))
        let unkeyed: Bool = listed.allSatisfy { $0.defaultChord == nil }
        let show: String? = listed.first { $0.id == "showSecrets:" }?.path
        check(ids == Set(SecretsMenuModel.commandIDs) && unkeyed && show == "Secrets",
              "secrets menu: Keyboard Shortcuts lists its commands under Secrets, Show Secrets among them, none with a default key",
              ids.sorted().joined(separator: ", "))
        let rows: [String] = commands.map(\.id).filter { $0.hasPrefix("rotateDueSecret") || $0.hasPrefix("showAllDueSecrets") }
        check(rows.isEmpty, "secrets menu: no due row is a command", rows.joined(separator: ", "))
        let window: NSMenu? = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
        let left: Bool = window?.items.contains { $0.action == #selector(AppDelegate.showSecrets(_:)) } ?? true
        check(!left, "secrets menu: Window has no Secrets item of its own any more")
    }

    /// Show Secrets opens the Secrets window, as Window › Secrets did.
    static func secretsMenuShowCheck(_ secrets: NSMenu) async -> SecretsView? {
        SecretsWindowController.shared?.window?.close()
        let item: NSMenuItem? = secretsMenuItem(secrets, #selector(AppDelegate.showSecrets(_:)))
        secretsMenuChoose(item)
        let opened: Bool = await wait(5) { SecretsWindowController.shared?.window?.isVisible == true }
        check(opened && item?.target === AppDelegate.shared, "secrets menu: Show Secrets opens the Secrets window")
        return opened ? SecretsWindowController.shared?.secretsView : nil
    }
}

// MARK: a broken vault, no vault, Add Key… and the imports

extension SelfTest {
    /// A vault this Mac can't open: Add Key… and Import From off, and Keys Due to Rotate's one row says why; Pause stays
    /// on, and Show Key Request and Revoke All Approvals… follow their own rules. With no vault, Add Key… is on.
    static func secretsMenuBrokenChecks(_ secrets: NSMenu) async {
        let store = SecretsStore.shared
        let menu = SecretsMenu.shared
        _ = try? await store.perform(.add(name: "MENU_KEY", purpose: "the menu checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: secretsValue("menu-")), asksEveryUse: false))
        let vaultPath: String = store.folder.path(SecretFolder.vaultName)
        guard let original = FileManager.default.contents(atPath: vaultPath) else {
            return check(false, "secrets menu: a vault for the broken checks")
        }
        let add: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.addSecretKey(_:)))
        let imports: [NSMenuItem?] = [secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromFile(_:))),
                                      secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromMCPConfigs(_:))),
                                      secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromManager(_:)), "bws")]
        let other = SoftwareKeyring(kind: .secureEnclave)
        if let made = try? SecretVault.create(keyring: other),
           let foreign = try? made.vault.add(name: "MENU_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                             value: SecretBytes(utf8: secretsValue("foreign-"))) {
            try? store.folder.write(SecretFolder.vaultName, data: foreign)
            await store.load()
            let saysWhy: Bool = secretsMenuBrokenOff(add, imports, line: SecretsView.cantOpenLine)
            check(store.protection == .cantOpen && saysWhy,
                  "secrets menu: with a vault this Mac can't open, Add Key… and Import From are off, and the due row says why",
                  secretsMenuTitles(menu.dueMenu).joined(separator: ", "))
            let pause: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.toggleKeyRequestPause(_:)))
            let request: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.showKeyRequest(_:)))
            let revoke: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.revokeAllSecretApprovals(_:)))
            check(secretsMenuOn(pause) && !secretsMenuOn(request) && !secretsMenuOn(revoke),
                  "secrets menu: with a broken vault, Pause stays on, and Show Key Request and Revoke All Approvals… follow their own rules")
        } else {
            check(false, "secrets menu: a vault made with another keyring")
        }
        // Changed outside Next Term: the same, with the tampered line, once a use has found it. load() reads the index with
        // no key, so no MAC check: until then the menu stays on, as the list's own check has it.
        if let planted = secretsTampered(original, { $0["purpose"] = "changed by hand" }) {
            try? store.folder.write(SecretFolder.vaultName, data: planted)
            await store.load()
            let quiet: Bool = !SecretsMenu.isBroken
            // Refused at unlock, before any value is opened; nothing it returns is kept.
            _ = try? await store.perform(.reveal(name: "MENU_KEY"))
            let line: String = SecretsView.statusText(store.protection, waitingForKeychain: store.isWaitingForKeychain,
                                                      unlisted: store.isUnlisted, tooLarge: store.isTooLarge)
            let saysWhy: Bool = secretsMenuBrokenOff(add, imports, line: line)
            check(quiet && store.protection == .tampered && saysWhy,
                  "secrets menu: with a vault changed outside Next Term, Add Key… and Import From are off after its first use, "
                      + "and the due row says why",
                  line)
        } else {
            check(false, "secrets menu: a tampered vault")
        }
        // No vault yet: the first Add makes it.
        try? FileManager.default.removeItem(atPath: vaultPath)
        await store.load()
        check(store.index == nil && !SecretsMenu.isBroken && secretsMenuOn(add), "secrets menu: with no vault yet, Add Key… is on")
        try? store.folder.write(SecretFolder.vaultName, data: original)
        await store.load()
        check(store.index?.entry(named: "MENU_KEY") != nil, "secrets menu: the vault is back for the checks after")
    }

    /// With the vault broken: Add Key… and every import off, and Keys Due to Rotate's one row off, saying it can't
    /// change keys, with `line`, the list's own status line, as its tooltip.
    static func secretsMenuBrokenOff(_ add: NSMenuItem?, _ imports: [NSMenuItem?], line: String) -> Bool {
        let menu = SecretsMenu.shared
        menu.menuNeedsUpdate(menu.dueMenu)
        let off: Bool = !secretsMenuOn(add) && imports.allSatisfy { (item: NSMenuItem?) -> Bool in !secretsMenuOn(item) }
        let row: NSMenuItem? = menu.dueMenu.items.first
        let rowSays: Bool = secretsMenuTitles(menu.dueMenu) == [SecretsMenuModel.cantChangeTitle] && row?.toolTip == line
        return off && rowSays && row?.isEnabled == false
    }

    /// Add Key… opens Add…'s sheet on the Secrets window, or on Settings › Secrets when that is in front; chosen again
    /// with a sheet open, it opens no second one, and the line under the list says to finish first.
    static func secretsMenuAddChecks(_ secrets: NSMenu, _ view: SecretsView) async {
        let add: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.addSecretKey(_:)))
        await secretsMenuFocus(view)
        secretsMenuChoose(add)
        let opened: Bool = await wait(5) { view.sheet != nil }
        let first: SecretEditSheet? = view.sheet
        view.say("")
        secretsMenuChoose(add)
        check(opened && view.sheet === first && view.actionLabel.stringValue == SecretsMenuModel.busyLine,
              "secrets menu: Add Key… opens Add…'s sheet, and again with it open, only says to finish first",
              view.actionLabel.stringValue)
        view.sheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
        view.say("")

        let settings = SettingsWindowController()
        let tab: NSTabViewItem? = (settings.window?.contentView as? NSTabView)?.tabViewItems.first { $0.identifier as? String == "secrets" }
        guard let window = settings.window, let list = tab?.view as? SecretsView else {
            return check(false, "secrets menu: Settings › Secrets holds a list")
        }
        defer { window.close() }
        settings.showTab("secrets")
        settings.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let inFront: Bool = await wait(5) { NSApp.keyWindow === window }
        secretsMenuChoose(add)
        let onTab: Bool = await wait(5) { list.sheet != nil }
        check(inFront && onTab && view.sheet == nil, "secrets menu: with Settings › Secrets in front, Add Key… opens on its list")
        list.sheet?.cancelButton.performClick(nil)
        _ = await wait(5) { list.sheet == nil }
    }
}

// MARK: Import From and Keys Due to Rotate

extension SelfTest {
    /// Import From's items open their sheets on the list, as its pull-down does: MCP Configs… (or its own refusal), A
    /// File… for the picked file (the open panel stood in), and a password manager's for its preset.
    static func secretsMenuImportChecks(_ secrets: NSMenu, _ view: SecretsView, base: URL) async {
        await secretsMenuFocus(view)
        secretsMenuChoose(secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromMCPConfigs(_:))))
        let mcp: Bool = await wait(5) { view.importSheet != nil }
        view.importSheet?.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
        check(mcp, "secrets menu: Import From › MCP Configs… opens its sheet on the list")

        let env: URL = base.appendingPathComponent("menu-import.env")
        try? "MENU_IMPORT_TOKEN=\(secretsValue("import-"))\n".write(to: env, atomically: true, encoding: .utf8)
        SecretsView.pickedForSelfTest = env
        defer {
            SecretsView.pickedForSelfTest = nil
            try? FileManager.default.removeItem(at: env)
        }
        secretsMenuChoose(secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromFile(_:))))
        let file: Bool = await wait(10) { view.fileImportSheet != nil }
        view.fileImportSheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.fileImportSheet == nil }
        check(file, "secrets menu: Import From › A File… opens the copy sheet for the file picked")

        secretsMenuChoose(secretsMenuItem(secrets, #selector(SecretsMenu.importSecretsFromManager(_:)), "bws"))
        let manager: Bool = view.managerSheet?.preset == .bws
        view.managerSheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.managerSheet == nil }
        check(manager, "secrets menu: Import From › Bitwarden Secrets Manager… opens that preset's sheet")
        view.say("")
    }

    /// On the self-test's day, a key 2 days past its 1-day reminder is listed, with its help, counted in the badge, and
    /// opens Rotate…; with a sheet open, nothing new opens and the line says why. With 10 more due, the submenu lists 10
    /// and Show All N, which says how many; none due, "No Keys Due", off. No title, tooltip or badge holds a stored value
    /// or its last four. Keys earlier checks left may be due on that day too: the rows are the list's rule's, ours among
    /// them.
    static func secretsMenuDueChecks(_ secrets: NSMenu, _ view: SecretsView) async {
        let store = SecretsStore.shared
        let menu = SecretsMenu.shared
        let name = "MENU_DUE_KEY"
        let value: String = secretsValue("due-")
        _ = try? await store.perform(.add(name: name, purpose: "the menu checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: value), remindDays: 1))
        guard let entry = store.index?.entry(named: name) else { return check(false, "secrets menu: the due key is saved") }
        let due: Date = Calendar.current.date(byAdding: .day, value: 2, to: entry.lastSet) ?? entry.lastSet
        SecretReminders.selfTestNow = due
        menu.menuNeedsUpdate(menu.dueMenu)
        let rows: [String] = secretsMenuTitles(menu.dueMenu)
        let row: NSMenuItem? = menu.dueMenu.items.first { (item: NSMenuItem) -> Bool in item.title == name }
        let count: Int = secretsMenuCount(menu.dueItem, title: SecretsMenuModel.dueTitle)
        let total: Int = SecretsMenu.dueCount()
        let help: String? = SecretAge.dueHelp(entry: entry, now: due)
        let listed: Bool = rows == secretsMenuDueTitles(now: due) && row?.toolTip == help
        check(listed && total >= 1 && count == total && secretsMenuOn(row),
              "secrets menu: a key past its reminder is listed under Keys Due to Rotate, with its help, and counted",
              "\(rows.joined(separator: ", ")), \(count) of \(total)")
        await secretsMenuFocus(view)
        secretsMenuChoose(row)
        let rotating: Bool = await wait(5) { view.rotateSheet?.name == name }
        let open: SecretRotateSheet? = view.rotateSheet
        secretsMenuChoose(row)
        let said: String = view.actionLabel.stringValue
        check(rotating && view.rotateSheet === open && said.hasPrefix("\(name) is due to rotate. Finish or cancel"),
              "secrets menu: a due key opens Rotate… for it, and with a sheet open, nothing new opens and the line says why", said)
        view.rotateSheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.rotateSheet == nil }

        let more: [String] = (1...10).map { (n: Int) -> String in "MENU_DUE_KEY_\(n)" }
        for extra in more {
            _ = try? await store.perform(.add(name: extra, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                              value: SecretBytes(utf8: secretsValue("due-more-")), remindDays: 1))
        }
        menu.menuNeedsUpdate(menu.dueMenu)
        let many: [String] = secretsMenuTitles(menu.dueMenu)
        let showAll: NSMenuItem? = menu.dueMenu.items.last
        let badge: Int = secretsMenuCount(menu.dueItem, title: SecretsMenuModel.dueTitle)
        let allDue: Int = SecretsMenu.dueCount()
        let tenThenSeparator: Bool = many.count == 12 && many[10] == "—" && many == secretsMenuDueTitles(now: due)
        let firstDue: Bool = showAll?.representedObject as? String == many.first
        let showsAll: Bool = showAll?.title == SecretsMenuModel.moreTitle(allDue) && firstDue
        check(allDue >= 11 && tenThenSeparator && showsAll && badge == allDue,
              "secrets menu: 11 or more keys due list 10, then Show All N in Secrets", many.joined(separator: ", "))
        secretsMenuValueCheck(secrets, value: value)
        secretsMenuChoose(showAll)
        let all: String = view.actionLabel.stringValue
        check(all.hasPrefix("\(allDue) keys are due to rotate"), "secrets menu: Show All says how many keys are due", all)

        // A day before any key's value was set, none is due, whatever earlier checks left.
        let earliest: Date = (store.index?.entries ?? []).map(\.lastSet).min() ?? entry.lastSet
        SecretReminders.selfTestNow = earliest.addingTimeInterval(-86_400)
        menu.menuNeedsUpdate(menu.dueMenu)
        let none: NSMenuItem? = menu.dueMenu.items.first
        let noneRow: Bool = secretsMenuTitles(menu.dueMenu) == [SecretsMenuModel.noneDueTitle] && none?.isEnabled == false
        let noneHelp: Bool = none?.toolTip == SecretsMenuModel.noneDueHelp
        let noCount: Bool = secretsMenuCount(menu.dueItem, title: SecretsMenuModel.dueTitle) == 0
        check(noneRow && noneHelp && noCount,
              "secrets menu: with no key due, the one row reads No Keys Due, off, and there is no count")
        for left in [name] + more { _ = try? await store.perform(.delete(name: left)) }
        view.say("")
    }

    /// Keys Due to Rotate's titles on `now`, as the list's rule gives them for the vault as it is (a separator as "—").
    static func secretsMenuDueTitles(now: Date) -> [String] {
        let entries: [SecretVault.Entry] = SecretsStore.shared.index?.entries ?? []
        let rows: [SecretsMenuModel.DueRow] = SecretsMenuModel.dueRows(entries: entries, broken: SecretsMenu.isBroken, now: now)
        return rows.flatMap { (row: SecretsMenuModel.DueRow) -> [String] in
            switch row {
            case .key(let name, _): return [name]
            case .more(let count, _): return ["—", SecretsMenuModel.moreTitle(count)]
            case .none: return [SecretsMenuModel.noneDueTitle]
            case .cantChange: return [SecretsMenuModel.cantChangeTitle]
            }
        }
    }

    /// Every title, tooltip and badge in the menu, the filled due rows among them: none holds `value` or its last four,
    /// and no item, a due row included, has a key.
    static func secretsMenuValueCheck(_ secrets: NSMenu, value: String) {
        let tail = String(value.suffix(4))
        var texts: [String] = []
        for item in secretsMenuItems(secrets) {
            texts.append(item.title)
            texts.append(item.toolTip ?? "")
            if #available(macOS 14.0, *) { texts.append(item.badge?.stringValue ?? "") }
        }
        let holding: [String] = texts.filter { $0.contains(value) || $0.contains(tail) }
        check(!texts.isEmpty && holding.isEmpty, "secrets menu: no title, tooltip or badge holds a stored value or its last four",
              "\(holding.count) do")
        let keyed: [String] = secretsMenuItems(secrets).filter { !$0.keyEquivalent.isEmpty }.map(\.title)
        check(keyed.isEmpty, "secrets menu: no item has a key, the filled due rows among them", keyed.joined(separator: ", "))
    }
}

// MARK: requests: Show Key Request, Pause and Resume, Revoke All Approvals…

extension SelfTest {
    /// Off with no request; with a stand-in one waiting, on with a count of 1, and choosing it brings the panel back on
    /// screen (taken off first, so only the item can) without making it key or answering it.
    static func secretsMenuRequestChecks(_ secrets: NSMenu) async {
        let requests = SecretRequests.shared
        let menu = SecretsMenu.shared
        requests.resetForSelfTest()
        let item: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.showKeyRequest(_:)))
        let offAtFirst: Bool = !secretsMenuOn(item) && item?.toolTip == SecretsMenuModel.noRequestHelp
        let request = secretsRequest(asker: "wrapper:selftest-menu", command: ["true"], names: ["MENU_KEY"])
        let answers = SecretsAnswers()
        requests.ask(request) { answers.take($0) }
        menu.refreshBadges()
        let count: Int = secretsMenuCount(menu.requestItem, title: SecretsMenuModel.showRequestTitle)
        let on: Bool = secretsMenuOn(item) && item?.toolTip == SecretsMenuModel.showRequestHelp
        let key: NSWindow? = NSApp.keyWindow
        let panel: NSWindow? = request.panel?.window
        // Floating, the panel stays above other windows when ordered back: off screen, only the item brings it back.
        panel?.orderOut(nil)
        let away: Bool = panel?.isVisible == false
        secretsMenuChoose(item)
        let shown: Bool = away && panel?.isVisible == true && panel?.isKeyWindow == false
        let inFront: Bool = shown && NSApp.keyWindow === key
        check(offAtFirst && on && count == 1 && inFront && answers.all.isEmpty,
              "secrets menu: Show Key Request is off with no request, then on with a count of 1, and brings the panel forward unanswered and not key",
              "off \(offAtFirst), on \(on), count \(count), in front \(inFront)")
        requests.resetForSelfTest()
        menu.refreshBadges()
    }

    /// Cancel pauses nothing; Pause declines a waiting request, and the item reads Resume Key Requests with "Paused
    /// until"; Resume needs no confirm and the list says so. Without the seam, Pause asks in a sheet on the Secrets
    /// window whose Return is Cancel.
    static func secretsMenuPauseChecks(_ secrets: NSMenu, _ view: SecretsView) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        let item: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.toggleKeyRequestPause(_:)))
        await secretsMenuFocus(view)
        SecretsMenu.answerPause = .alertSecondButtonReturn
        secretsMenuChoose(item)
        let cancelled: Bool = requests.pausedUntil == nil
        let waiting = secretsRequest(asker: "wrapper:selftest-menu-pause", command: ["true"], names: ["MENU_KEY"])
        let answers = SecretsAnswers()
        requests.ask(waiting) { answers.take($0) }
        SecretsMenu.answerPause = .alertFirstButtonReturn
        secretsMenuChoose(item)
        _ = secretsMenuOn(item)
        let declined: Bool = requests.pausedUntil != nil && secretsRefusal(answers.last) != nil
        let resume: Bool = item?.title == SecretsMenuModel.resumeTitle && item?.toolTip?.hasPrefix("Paused until") == true
        let paused: Bool = declined && resume
        check(cancelled && paused, "secrets menu: Cancel pauses nothing; Pause declines the waiting request and the item reads Resume",
              "\(item?.title ?? "none"), \(item?.toolTip ?? "no tooltip")")
        SecretsMenu.answerPause = nil
        secretsMenuChoose(item)
        _ = secretsMenuOn(item)
        let titledPause: Bool = item?.title == SecretsMenuModel.pauseItemTitle
        let saidResumed: Bool = view.actionLabel.stringValue == SecretsMenuModel.resumedLine
        check(requests.pausedUntil == nil && titledPause && saidResumed,
              "secrets menu: Resume Key Requests resumes with no confirm, and the list says so", view.actionLabel.stringValue)

        secretsMenuChoose(item)
        _ = await wait(5) { view.alert != nil }
        let alert: NSAlert? = view.alert
        let enter: NSButton? = alert?.buttons.first { $0.keyEquivalent == "\r" }
        let worded: Bool = alert?.messageText == "Pause key requests for an hour?"
            && alert?.informativeText == SecretApprovalPanel.menuPauseText
        let asked: Bool = worded && alert?.buttons.first?.keyEquivalent == ""
        let onWindow: Bool = view.window?.attachedSheet != nil
        enter?.performClick(nil)
        _ = await wait(5) { view.alert == nil }
        let cancels: Bool = enter?.title == "Cancel" && requests.pausedUntil == nil
        check(asked && onWindow && cancels,
              "secrets menu: Pause asks in a sheet on the Secrets window, Return on Cancel, which pauses nothing")
        view.say("")
        requests.resetForSelfTest()
    }

    /// Off with no approval; on with one. Chosen, it asks in a sheet saying how many it ends, Return on Cancel, which
    /// keeps it; then `secretsMenuRevokeSheetChecks`, which ends with Revoke ending them.
    static func secretsMenuRevokeChecks(_ secrets: NSMenu, _ view: SecretsView) async {
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        let item: NSMenuItem? = secretsMenuItem(secrets, #selector(SecretsMenu.revokeAllSecretApprovals(_:)))
        let offWithNone: Bool = !secretsMenuOn(item) && item?.toolTip == SecretsMenuModel.noGrantsHelp
        let request = secretsRequest(asker: "wrapper:selftest-menu-revoke", command: ["true"], names: ["MENU_KEY"])
        let answers = SecretsAnswers()
        requests.ask(request) { answers.take($0) }
        request.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        request.panel?.allowButton.performClick(nil)
        _ = await wait(10) { !requests.grants.isEmpty }
        let on: Bool = secretsMenuOn(item) && item?.toolTip?.hasPrefix(SecretsMenuModel.revokeAllHelp) == true
        check(offWithNone && on, "secrets menu: Revoke All Approvals… is off with no approval, and on with one")

        await secretsMenuFocus(view)
        secretsMenuChoose(item)
        _ = await wait(5) { view.alert != nil }
        let alert: NSAlert? = view.alert
        let worded: Bool = alert?.messageText == SecretsMenuModel.revokeConfirmTitle
            && alert?.informativeText == SecretsMenuModel.revokeConfirmText(1)
        let asked: Bool = worded && alert?.buttons.first?.keyEquivalent == ""
        let enter: NSButton? = alert?.buttons.first { $0.keyEquivalent == "\r" }
        enter?.performClick(nil)
        _ = await wait(5) { view.alert == nil }
        let kept: Bool = requests.grants.count == 1 && enter?.title == "Cancel"
        check(asked && kept, "secrets menu: Revoke All Approvals… asks in a sheet saying how many, and Return cancels",
              alert?.informativeText ?? "no sheet")
        await secretsMenuRevokeSheetChecks(item, view)
        requests.resetForSelfTest()
    }
}
#endif
