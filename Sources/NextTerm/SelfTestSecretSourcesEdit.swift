import AppKit
import NextTermCore

#if DEBUG
/// Edit… and the list for a key's page: what Touch ID is asked for, the reminder, a link changed or cleared, a
/// suggestion that never replaces a stored page, a stored link that holds a key, the double-click, the columns, and
/// Use in `request_secret`'s window. Keys are pressed from CGEvents; pages are recorded, never opened; every value is
/// made up at run time.
extension SelfTest {
    /// Keys pressed into `field` as a hand presses them: the field takes the keyboard, what it holds is selected and
    /// deleted with ⌫, then each character arrives as its own key down, which the field editor types, so the sheet
    /// hears each change as it does a person's.
    static func secretsType(_ text: String, into field: NSTextField) {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { secretsKey(window, "\u{7f}", code: 51) }
        for character in text { secretsKey(window, String(character), code: 0) }
    }

    /// Whether the keys came from CGEvents as asked, or (noted once) as AppKit's own key events.
    private static var secretKeysNoted = false

    /// A key down made from a CGEvent carrying `characters`, sent to `window`, whose first responder takes it; AppKit's
    /// own key event with the same characters when one can't be made, noted once.
    static func secretsKey(_ window: NSWindow, _ characters: String, code: UInt16) {
        var units: [UniChar] = Array(characters.utf16)
        let source = CGEventSource(stateID: .hidSystemState)
        if let made = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            made.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            if let event = NSEvent(cgEvent: made), event.characters == characters {
                window.sendEvent(event)
                return
            }
        }
        if !secretKeysNoted {
            secretKeysNoted = true
            note("secret sources: a CGEvent's key came without its characters here; the keys are AppKit's own events")
        }
        let time: TimeInterval = ProcessInfo.processInfo.systemUptime
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    /// A click as a hand makes one at `point` in `view`: made from CGEvents aimed at its window, or AppKit's own events
    /// at the same place. The mouse-up waits in the queue, where the view's tracking loop takes it. `count` 2 is a
    /// double-click's second click.
    static func secretsClick(_ view: NSView, at point: NSPoint, count: Int) {
        guard let window = view.window,
              let down = secretsMouse(.leftMouseDown, window, view.convert(point, to: nil), count),
              let up = secretsMouse(.leftMouseUp, window, view.convert(point, to: nil), count) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default,
                              dequeue: true) != nil {}
    }

    private static func secretsMouse(_ type: NSEvent.EventType, _ window: NSWindow, _ inWindow: NSPoint, _ count: Int) -> NSEvent? {
        let onScreen: NSPoint = window.convertPoint(toScreen: inWindow)
        let top: CGFloat = NSScreen.screens.first?.frame.maxY ?? 0
        let global = CGPoint(x: onScreen.x, y: top - onScreen.y)
        let cgType: CGEventType = type == .leftMouseDown ? .leftMouseDown : .leftMouseUp
        let source = CGEventSource(stateID: .hidSystemState)
        if let made = CGEvent(mouseEventSource: source, mouseType: cgType, mouseCursorPosition: global, mouseButton: .left) {
            made.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            made.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            made.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: made), event.windowNumber == window.windowNumber,
               abs(event.locationInWindow.x - inWindow.x) < 1, abs(event.locationInWindow.y - inWindow.y) < 1 {
                return event
            }
        }
        let time: TimeInterval = ProcessInfo.processInfo.systemUptime
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: time,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }
}

extension SelfTest {
    /// On a store of its own: a link holding a stored key is refused before Touch ID is asked; Touch ID names what an
    /// edit changes (its page, its reminder, or several details); an edit of those moves no Rotated date.
    static func secretSourcesStoreChecks(_ base: URL) async {
        let (store, presence) = secretsStore(base, "sources-edit", keyring: SoftwareKeyring())
        let held = secretsValue("held-")
        let heldKey = SecretBytes(utf8: held)
        let added = (try? await store.perform(.add(name: "HELD_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                                   writeOnly: true, value: heldKey))) != nil
        let calls = presence.calls
        var refusal: SecretsStore.Failure?
        do {
            try await store.perform(.add(name: "HOLDER_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                         value: SecretBytes(utf8: secretsValue("holder-")),
                                         link: "https://dashboard.example.com/keys/" + held))
        } catch {
            refusal = error as? SecretsStore.Failure
        }
        let refused: Bool = refusal == .vault(.badLink(.holdsAKey)) && store.index?.entry(named: "HOLDER_KEY") == nil
        check(added && refused && presence.calls == calls,
              "secret sources: a link holding a stored key is refused before Touch ID is asked",
              "\(String(describing: refusal)), \(presence.calls - calls) checks")

        let name = "HOLDER_KEY"
        _ = try? await store.perform(.add(name: name, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("holder-")), remindDays: 90))
        let set: Date? = store.index?.entry(named: name)?.valueSet
        let page = "https://console.example.com/keys"
        let toPage: SecretsStore.Action = .edit(name: name, newName: nil, purpose: nil, purposeBy: .user, link: page)
        let noPage: SecretsStore.Action = .edit(name: name, newName: nil, purpose: nil, purposeBy: .user, link: .some(nil))
        let remind: SecretsStore.Action = .edit(name: name, newName: nil, purpose: nil, purposeBy: .user, remindDays: 30)
        let several: SecretsStore.Action = .edit(name: name, newName: nil, purpose: "rag-api", purposeBy: .user, link: page,
                                                 remindDays: .some(nil))
        let edits: [(SecretsStore.Action, String)] = [(toPage, SecretReason.changeLink(name)), (noPage, SecretReason.changeLink(name)),
                                                      (remind, SecretReason.changeReminder(name)),
                                                      (several, SecretReason.changeDetails(name))]
        for (action, reason) in edits {
            let done: Bool = (try? await store.perform(action)) != nil
            check(done && presence.reasons.last == reason, "secret sources: Touch ID asks to \(reason)",
                  presence.reasons.last ?? "no check")
        }
        let entry = store.index?.entry(named: name)
        let kept: Bool = entry?.link == page && entry?.remindDays == nil && entry?.purpose == "rag-api"
        check(set != nil && entry?.valueSet == set && kept,
              "secret sources: edits of a key's page, reminder and purpose move no Rotated date",
              "\(String(describing: entry?.valueSet)) after \(String(describing: set))")
        let named: Bool = presence.reasons.allSatisfy { (reason: String) -> Bool in !reason.contains(held) }
        check(named, "secret sources: Touch ID's reasons hold names only")
    }
}

extension SelfTest {
    /// Through Window › Secrets' sheets: Add… saves its reminder and the page Use took from the value; Edit… shows both
    /// and offers the name's page never over it; it changes the page and the reminder, clears the page and keeps an age
    /// off the menu, each saved with what Touch ID is asked for.
    static func secretSourcesEditChecks(_ view: SecretsView, _ presence: StandInPresence) async {
        let store = SecretsStore.shared
        let name = "OPENAI_SOURCES_KEY"
        view.add()
        guard let sheet = view.sheet, let link = sheet.linkField, let remind = sheet.remindPopUp else {
            return check(false, "secret sources: Add… has Where it came from and Remind me to rotate")
        }
        secretsType(name, into: sheet.nameField)
        secretsType(secretsValue("sk-" + "or-v1-"), into: sheet.valueField)
        let router: Bool = link.chipLabel.stringValue.hasPrefix("Suggested: OpenRouter")
        check(link.showsSuggestion && router, "secret sources: in Add…'s chip the value's head wins over the name",
              link.chipLabel.stringValue)
        link.useButton.performClick(nil)
        let routerPage: String = link.text
        secretsPick(90, in: remind)
        sheet.saveButton.performClick(nil)
        _ = await wait(10) { view.sheet == nil && store.index?.entry(named: name) != nil }
        let saved = store.index?.entry(named: name)
        let both: Bool = saved?.remindDays == 90 && saved?.link == routerPage && !routerPage.isEmpty
        check(both && presence.reasons.last == SecretReason.save(name),
              "secret sources: Add… saves Remind me to rotate and the page Use took",
              "\(String(describing: saved?.remindDays)), \(presence.reasons.last ?? "no check")")

        view.select(name)
        view.edit()
        if let edit = view.sheet, let field = edit.linkField, let popUp = edit.remindPopUp {
            let shown: Bool = field.text == routerPage && popUp.selectedTag() == 90
            check(shown && !field.showsSuggestion,
                  "secret sources: Edit… shows the page and the reminder, and never offers the name's page over the value's",
                  field.chipLabel.stringValue)
            edit.cancelButton.performClick(nil)
            _ = await wait(5) { view.sheet == nil }
        } else {
            check(false, "secret sources: Edit… opens")
        }
        await secretSourcesEditSaves(view, name, presence)
        _ = try? await store.perform(.delete(name: name))
    }

    /// `days` chosen in Remind me to rotate, as a click on its item does: the item selected, then the pop-up's action.
    static func secretsPick(_ days: Int, in popUp: NSPopUpButton?) {
        guard let popUp else { return }
        popUp.selectItem(withTag: days)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
    }

    /// Edit… on `name` with `change` made in its sheet, then Save: the reason Touch ID was asked with, or nil when the
    /// sheet didn't open or Save didn't go through (the sheet is cancelled then).
    static func secretSourcesEdit(_ view: SecretsView, _ name: String, _ presence: StandInPresence,
                                  _ change: (SecretEditSheet) -> Void) async -> String? {
        view.select(name)
        view.edit()
        guard let sheet = view.sheet else { return nil }
        let calls = presence.calls
        change(sheet)
        sheet.saveButton.performClick(nil)
        let closed: Bool = await wait(10) { view.sheet == nil }
        if !closed {
            sheet.cancelButton.performClick(nil)
            _ = await wait(5) { view.sheet == nil }
        }
        return closed && presence.calls > calls ? presence.reasons.last : nil
    }
}

extension SelfTest {
    /// Edit… saves: a new page and reminder together, the page alone, the page cleared, the reminder alone; an age off
    /// the menu (45 days) shows as its own item and stays when only what it's for changes. Each asks Touch ID for what
    /// it changes, and none moves the Rotated date.
    static func secretSourcesEditSaves(_ view: SecretsView, _ name: String, _ presence: StandInPresence) async {
        let store = SecretsStore.shared
        let set: Date? = store.index?.entry(named: name)?.valueSet
        let typed = "https://console.example.com/keys"
        let both: String? = await secretSourcesEdit(view, name, presence) { (sheet: SecretEditSheet) in
            if let field = sheet.linkField { secretsType(typed, into: field.field) }
            secretsPick(180, in: sheet.remindPopUp)
        }
        var entry = store.index?.entry(named: name)
        let changed: Bool = entry?.link == typed && entry?.linkFrom == .user && entry?.remindDays == 180
        check(changed && both == SecretReason.changeDetails(name),
              "secret sources: Edit… changes the page and the reminder, asking to change the key's details", both ?? "not saved")

        let page = "https://console.example.com/keys/rag-api"
        let pageOnly: String? = await secretSourcesEdit(view, name, presence) { (sheet: SecretEditSheet) in
            if let field = sheet.linkField { secretsType(page, into: field.field) }
        }
        entry = store.index?.entry(named: name)
        check(entry?.link == page && pageOnly == SecretReason.changeLink(name),
              "secret sources: Edit… changes the page alone, asking to change the key's page", pageOnly ?? "not saved")
        let cleared: String? = await secretSourcesEdit(view, name, presence) { (sheet: SecretEditSheet) in
            if let field = sheet.linkField { secretsType("", into: field.field) }
        }
        entry = store.index?.entry(named: name)
        check(entry?.link == nil && entry?.linkFrom == nil && cleared == SecretReason.changeLink(name),
              "secret sources: Edit… clears the page", cleared ?? "not saved")
        let remindOnly: String? = await secretSourcesEdit(view, name, presence) { (sheet: SecretEditSheet) in
            secretsPick(30, in: sheet.remindPopUp)
        }
        let reminded: Bool = store.index?.entry(named: name)?.remindDays == 30
        check(reminded && remindOnly == SecretReason.changeReminder(name),
              "secret sources: Edit… changes the reminder alone, asking to change when to remind", remindOnly ?? "not saved")

        _ = try? await store.perform(.edit(name: name, newName: nil, purpose: nil, purposeBy: .user, remindDays: 45))
        var offMenu = ""
        let purposeOnly: String? = await secretSourcesEdit(view, name, presence) { (sheet: SecretEditSheet) in
            let held: Bool = sheet.remindPopUp?.selectedTag() == 45
            offMenu = held ? sheet.remindPopUp?.titleOfSelectedItem ?? "" : "not selected"
            secretsType("rag-api, staging", into: sheet.purposeField)
        }
        entry = store.index?.entry(named: name)
        let kept: Bool = offMenu == "45 days" && entry?.remindDays == 45
        check(kept && purposeOnly == SecretReason.changePurpose(name),
              "secret sources: an age off the menu shows as its own item, and stays when only what it's for changes",
              "\(offMenu), \(String(describing: entry?.remindDays)), \(purposeOnly ?? "not saved")")
        check(set != nil && entry?.valueSet == set, "secret sources: none of Edit…'s saves moves the Rotated date")
    }
}

extension SelfTest {
    /// A key whose stored link holds another key's value, that key stored write-only after the link was saved: its Page
    /// cell says it can't be opened, with the reason, not the link, as its tooltip; Open Page is off with that reason;
    /// Edit… shows the field empty and says why, and its Save removes the link. No text in the sheet holds the value.
    static func secretSourcesHeldChecks(_ view: SecretsView, _ presence: StandInPresence) async {
        let store = SecretsStore.shared
        let value = secretsValue("held-")
        let link = "https://dashboard.example.com/keys/" + value
        _ = try? await store.perform(.add(name: "SOURCE_HOLDER_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: secretsValue("holder-")), link: link))
        _ = try? await store.perform(.add(name: "SOURCE_HELD_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                          writeOnly: true, value: SecretBytes(utf8: value)))
        await secretSourcesHeldViewChecks(view, presence, link: link, value: value)
        for name in ["SOURCE_HOLDER_KEY", "SOURCE_HELD_KEY"] { _ = try? await store.perform(.delete(name: name)) }
    }

    private static func secretSourcesHeldViewChecks(_ view: SecretsView, _ presence: StandInPresence, link: String,
                                                    value: String) async {
        let store = SecretsStore.shared
        guard let row = view.entries.firstIndex(where: { (entry: SecretVault.Entry) -> Bool in entry.name == "SOURCE_HOLDER_KEY" }),
              let holder = store.index?.entry(named: "SOURCE_HOLDER_KEY"), holder.link == link else {
            return check(false, "secret sources: a link saved before the key it holds is kept")
        }
        let column = view.table.tableColumns.first { (column: NSTableColumn) -> Bool in column.identifier.rawValue == "page" }
        let cell = view.tableView(view.table, viewFor: column, row: row) as? NSTextField
        let sentence: String = SecretLink.Refusal.holdsAKey.sentence
        let cellSays: Bool = cell?.stringValue == SecretLink.cantOpen && cell?.toolTip == sentence
        let item = view.pageItem(for: holder)
        let itemOff: Bool = item?.isEnabled == false && item?.action == nil && item?.toolTip == sentence
        check(cellSays && itemOff,
              "secret sources: a stored link holding a key can't be opened, in its Page cell and in Open Page, which says why",
              "\(cell?.stringValue ?? "no cell"), \(item?.title ?? "no item")")
        var shown = ""
        var hidden = false
        let reason: String? = await secretSourcesEdit(view, "SOURCE_HOLDER_KEY", presence) { (sheet: SecretEditSheet) in
            let field = sheet.linkField
            hidden = field?.field.stringValue.isEmpty == true && field?.refusalLabel.stringValue == SecretLinkField.hiddenLine
            shown = secretsViewText(sheet.window?.contentView)
        }
        check(hidden && !shown.isEmpty && !shown.contains(value),
              "secret sources: Edit… keeps a stored link that holds a key out of its field, and says why")
        let removed: Bool = store.index?.entry(named: "SOURCE_HOLDER_KEY")?.link == nil
        check(removed && reason == SecretReason.changeLink("SOURCE_HOLDER_KEY"),
              "secret sources: Save in that Edit… removes the link", reason ?? "not saved")
    }

    /// Every text a view and the views in it show: labels, fields, placeholders and tooltips.
    static func secretsViewText(_ view: NSView?) -> String {
        guard let view else { return "" }
        var texts: [String] = [view.toolTip ?? ""]
        if let field = view as? NSTextField { texts += [field.stringValue, field.placeholderString ?? ""] }
        if let button = view as? NSButton { texts.append(button.title) }
        for subview in view.subviews { texts.append(secretsViewText(subview)) }
        return texts.filter { (text: String) -> Bool in !text.isEmpty }.joined(separator: "\n")
    }
}

extension SelfTest {
    /// A double-click on a Page cell opens its page; one on the Page column's header opens no page and no sheet,
    /// whichever row is selected.
    static func secretSourcesDoubleClickChecks(_ view: SecretsView, _ name: String, page: String) async {
        let table = view.table
        guard let row = view.entries.firstIndex(where: { (entry: SecretVault.Entry) -> Bool in entry.name == name }),
              let column = table.tableColumns.firstIndex(where: { (column: NSTableColumn) -> Bool in column.identifier.rawValue == "page" }) else {
            return check(false, "secret sources: the key with a page is listed")
        }
        table.scrollRowToVisible(row)
        let cell: NSRect = table.frameOfCell(atColumn: column, row: row)
        let point = NSPoint(x: cell.midX, y: cell.midY)
        ServiceLinks.opened = []
        secretsClick(table, at: point, count: 1)
        secretsClick(table, at: point, count: 2)
        _ = await wait(5) { !ServiceLinks.opened.isEmpty }
        let opened: [String] = ServiceLinks.opened.map { (url: URL) -> String in url.absoluteString }
        check(opened == [page] && view.sheet == nil, "secret sources: a double-click on the Page cell opens the page", "\(opened)")
        ServiceLinks.opened = []
        view.select(name)
        if let header = table.headerView {
            let rect: NSRect = header.headerRect(ofColumn: column)
            let at = NSPoint(x: rect.midX, y: rect.midY)
            secretsClick(header, at: at, count: 1)
            secretsClick(header, at: at, count: 2)
            _ = await wait(1) { view.sheet != nil || !ServiceLinks.opened.isEmpty }
        }
        check(view.sheet == nil && ServiceLinks.opened.isEmpty,
              "secret sources: a double-click on the Page header opens no page and no sheet")
        view.sheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
        ServiceLinks.opened = []
    }

    /// The six columns fit the list, none under its least width, at Window › Secrets' smallest width and as it opens:
    /// the list never scrolls sideways.
    static func secretSourcesColumnChecks(_ window: NSWindow, _ view: SecretsView) {
        let frame: NSRect = window.frame
        defer { window.setFrame(frame, display: true) }
        let table = view.table
        for width in [window.minSize.width, 640] {
            var resized: NSRect = frame
            resized.size.width = width
            window.setFrame(resized, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let clip: CGFloat = table.enclosingScrollView?.contentView.bounds.width ?? 0
            let last: NSRect = table.rect(ofColumn: table.numberOfColumns - 1)
            let squeezed: [NSTableColumn] = table.tableColumns.filter { (column: NSTableColumn) -> Bool in
                column.width < column.minWidth - 0.5
            }
            let widths: String = table.tableColumns.map { (column: NSTableColumn) -> String in
                "\(column.title) \(Int(column.width))"
            }.joined(separator: ", ")
            let sideways: Bool = table.enclosingScrollView?.hasHorizontalScroller ?? true
            check(clip > 0 && last.maxX <= clip + 0.5 && squeezed.isEmpty && !sideways,
                  "secret sources: the list's six columns fit Window › Secrets at \(Int(width)) wide",
                  "a list \(Int(clip)) wide: \(widths)")
        }
    }

    /// Use in request_secret's window: a value with OpenAI's head suggests its page, Use fills the field, and Save keeps
    /// it as the suggestion; the answer names no page.
    static func secretSourcesRequestUseChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }
        let call = secretsStart("request_secret", ["name": "SOURCE_USED_KEY", "reason": "the page checks"])
        _ = await wait(10) { requests.showing?.requestWindow != nil }
        guard let window = requests.showing?.requestWindow else {
            return check(false, "secret sources: request_secret opens its window again")
        }
        let link = window.linkField
        secretsType(secretsValue("sk-" + "proj-"), into: window.valueField)
        let offered: Bool = link.showsSuggestion && link.chipLabel.stringValue == "Suggested: OpenAI · API Keys"
        link.useButton.performClick(nil)
        let filled: Bool = link.text == sourcesOpenAIPage && link.linkFrom == .suggested
        window.saveButton.performClick(nil)
        let answer = await call.value
        let entry = store.index?.entry(named: "SOURCE_USED_KEY")
        let kept: Bool = entry?.link == sourcesOpenAIPage && entry?.linkFrom == .suggested
        check(offered && filled && kept && !secretsJSON(answer).contains("openai.com"),
              "secret sources: Use in request_secret's window fills the page, and Save keeps it as the suggestion",
              "\(link.chipLabel.stringValue), \(entry?.link ?? "no link")")
        window.close()
        _ = try? await store.perform(.delete(name: "SOURCE_USED_KEY"))
    }
}
#endif
