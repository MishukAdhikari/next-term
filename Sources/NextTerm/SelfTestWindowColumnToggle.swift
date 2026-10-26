import AppKit
import NextTermCore

#if DEBUG
/// The window column switched off and on: ⌃⇧⌘S hides it in every window and brings it back, the menu following; an agent
/// hides, shows, unfolds and folds it with set_layout (under a grant here, so a notice says what it did); and the notice
/// that offers it: once its note on hiding it with five windows or more, then, hidden, the offer to show it, its button
/// showing it everywhere, Don't Ask Again ending it, a change of the setting taking it away, the launch's reopening and
/// a second window in one launch offering nothing. Part of NEXTTERM_SELFTEST_ONLY=windowColumn.
extension SelfTest {
    /// Quiet on purpose: this window's badge sits in a darker well 2 points round it, with no ring, edged only with
    /// Increase Contrast, which draws that badge alone again; the worktree's dot is 6 points at the badge's corner, its cut
    /// inside the button; two capitals are set 0.7 points apart and mixed case not; a working mark in the column or ⌘O
    /// never turns, while a tab's does; done is a dark ✓ on a softer green, plain green with Increase Contrast.
    static func calmChecks(_ app: AppDelegate, _ five: [TerminalWindowController], worktree: TerminalWindowController) {
        let column: WindowColumnView = five[0].windowColumn
        guard let own = column.button(for: five[0].indexID), let marked = column.button(for: worktree.indexID) else {
            return check(false, "window column: the calm look's badges to check")
        }
        let badge: NSRect = own.badgeForTest
        let well: Bool = own.isCurrent && own.plateForTest == badge.insetBy(dx: -2, dy: -2)
        let corner: NSRect = marked.badgeForTest
        let dot: NSRect? = marked.dotFrameForTest
        let dotPlaced: Bool = dot == NSRect(x: corner.maxX - 5, y: corner.minY - 1, width: 6, height: 6)
            && dot.map { marked.bounds.contains($0.insetBy(dx: -2, dy: -2)) } == true
        check(well && dotPlaced, "window column: this window's badge sits in a darker well, and a dot is 6 points at a badge's corner, its cut inside",
              "well \(own.plateForTest) round \(badge), dot \(dot.map { "\($0)" } ?? "none") at \(corner)")

        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        func width(_ text: String) -> CGFloat { NSAttributedString(string: text, attributes: [.font: font]).size().width }
        let spread: CGFloat = WindowColumnButton.lettersText("XC").size().width - width("XC")
        let mixed: CGFloat = WindowColumnButton.lettersText("Ag").size().width - width("Ag")
        check(abs(spread - 0.7) < 0.05 && abs(mixed) < 0.01, "window column: two capitals are set a little apart, mixed case as the font sets it",
              "XC +\(spread), Ag +\(mixed)")

        // As View › Agent Spinner has it: a tab's mark turns with Spinning, a listed one never.
        let watched = StatusDotView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        watched.state = .working
        let listed = StatusDotView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        listed.turnsWhileWorking = false
        listed.state = .working
        check(watched.ringTurns == AgentSpinner.turns && listed.ringShows == watched.ringShows && !listed.ringTurns,
              "window column: a working mark in the column or ⌘O stays still while a tab's turns",
              "spinner \(AgentSpinner.current.rawValue), tab turns \(watched.ringTurns), listed turns \(listed.ringTurns)")

        let contrast: Bool? = DisplayOptions.increasesContrastOverride
        DisplayOptions.increasesContrastOverride = false
        let quiet: NSImage? = StatusGlyph.image(for: .done)
        column.shownButtons.forEach { $0.resetCounters() }
        DisplayOptions.increasesContrastOverride = true
        let plain: NSImage? = StatusGlyph.image(for: .done)
        column.displayIfNeeded()
        let redrawn: [Int] = column.shownButtons.filter { $0.drawCount > 0 }.map(\.id)
        DisplayOptions.increasesContrastOverride = contrast
        check(quiet != nil && plain != nil && quiet?.tiffRepresentation != plain?.tiffRepresentation && redrawn == [five[0].indexID],
              "window column: Increase Contrast makes done plain green and draws this window's badge alone again, for its edge",
              "redrawn \(redrawn) of \(column.shownButtons.map(\.id))")
    }

    /// ⌃⇧⌘S, as the keyboard sends it: hidden in every window, View says Show Window Column, the setting off and the
    /// windows open kept for the offer; again, folded in every window and Hide Window Column.
    static func hideKeyChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window, await bringToFront(window) else { return note("window column: ⌃⇧⌘S not checked, as " + notFrontmost(c.window ?? NSWindow())) }
        let chord: KeyChord? = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")
        check(chord?.display == "⌃⇧⌘S", "window column: Hide Window Column has ⌃⇧⌘S", chord?.display ?? "none")
        let all: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        let item: NSMenuItem? = viewMenuItems().first { $0.action == #selector(AppDelegate.toggleWindowColumn(_:)) }
        pressKey(window, code: 1, [.command, .shift, .control])
        for each in all { each.window?.layoutIfNeeded() }
        let hidden: Bool = all.allSatisfy { $0.columnHost.shown.form == .hidden } && defaultsValue(WindowColumnSettings.shownKey) == false
        _ = item.map(app.validateMenuItem)
        let offTitle: String = item?.title ?? ""
        let kept: Bool = UserDefaults.standard.object(forKey: WindowColumnOffer.hiddenWithKey) as? Int == app.windowIndex.windows.count
        pressKey(window, code: 1, [.command, .shift, .control])
        for each in all { each.window?.layoutIfNeeded() }
        let back: Bool = all.allSatisfy { $0.columnHost.shown.form == .folded } && defaultsValue(WindowColumnSettings.shownKey) == true
        _ = item.map(app.validateMenuItem)
        let onTitle: String = item?.title ?? ""
        check(hidden && offTitle == "Show Window Column" && kept && back && onTitle == "Hide Window Column",
              "window column: ⌃⇧⌘S hides the column in every window and brings it back, the menu and the setting following",
              "hidden \(hidden), menu \(offTitle), count kept \(kept), back \(back), menu \(onTitle)")
        // The column's own right-click menu shows both keys as the user has them.
        let menu = WindowColumnView.columnMenu()
        let keys: [String] = menu.items.map { KeyboardShortcuts.chord(of: $0)?.display ?? "" }
        check(keys == ["⌃⇧⌘S", "⌃⌘S"], "window column: its right-click menu shows ⌃⇧⌘S and ⌃⌘S", keys.joined(separator: ", "))
    }

    /// set_layout under a grant (as a remote door's own setting has it): hidden in every window, with a notice saying so
    /// and how to bring it back; shown and unfolded in one call; folded again; the same again changes nothing.
    static func layoutToolChecks(_ app: AppDelegate, _ c: TerminalWindowController) async {
        guard let window = c.window, await bringToFront(window) else { return note("window column: set_layout not checked, as " + notFrontmost(c.window ?? NSWindow())) }
        func call(_ arguments: [String: Any]) async -> [String: Any] {
            var result = MCPServer.CallResult(text: "", isError: false)
            MCPControl.call("set_layout", arguments, caller: nil, approval: .preApprovedByGrant("g-selftest")) { result = $0 }
            _ = await wait(10) { !result.text.isEmpty }
            return (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? ["error": result.text]
        }
        let all: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        let key: String? = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display
        let hid = await call(["window_column": "hidden"])
        for each in all { each.window?.layoutIfNeeded() }
        let hiddenEverywhere: Bool = all.allSatisfy { $0.columnHost.shown.form == .hidden } && !app.showsWindowColumn
        let told: Bool = GitToast.text == WindowColumnSettings.grantedLine(shown: false, key: key)
        let hidSaid: Bool = hid["window_column"] as? String == "hidden" && hid["window_column_here"] as? String == "hidden"
            && (hid["changed"] as? [String]) == ["window_column"]
        GitToast.dismiss()
        let opened = await call(["window_column": "shown", "window_column_folded": false])
        for each in all { each.window?.layoutIfNeeded() }
        let unfolded: Bool = all.allSatisfy { $0.columnHost.shown.form == .expanded } && app.windowColumnExpanded
        let openedSaid: Bool = opened["window_column_here"] as? String == "unfolded" && opened["window_column_folded"] as? Bool == false
        GitToast.dismiss()
        let folded = await call(["window_column_folded": true])
        for each in all { each.window?.layoutIfNeeded() }
        let foldedAgain: Bool = all.allSatisfy { $0.columnHost.shown.form == .folded } && folded["window_column_here"] as? String == "folded"
        let same = await call(["window_column": "shown", "window_column_folded": true])
        let nothing: Bool = (same["changed"] as? [String])?.isEmpty == true
        check(hiddenEverywhere && told && hidSaid && unfolded && openedSaid && foldedAgain && nothing,
              "window column: set_layout hides it in every window with a notice naming the key, shows and unfolds it in one call, folds it, and the same again changes nothing",
              "hidden \(hiddenEverywhere), notice \(told), said \(hidSaid), unfolded \(unfolded) \(openedSaid), folded \(foldedAgain), same \(nothing): \(hid)")
    }

    /// The notice about the column, each step as a fresh launch with a fresh record. `open` opens a window as the user
    /// does; `close` closes one.
    static func offerChecks(_ app: AppDelegate, _ c: TerminalWindowController, open: @escaping () async -> TerminalWindowController?,
                            close: @escaping (TerminalWindowController) async -> Void) async {
        guard let window = c.window, await bringToFront(window) else { return note("window column: the offer not checked, as " + notFrontmost(c.window ?? NSWindow())) }
        let defaults = UserDefaults.standard
        let key: String? = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display
        WindowColumns.offersSuppressed = false
        defer {
            WindowColumns.offersSuppressed = true
            app.windowColumns.holdsOffers = false
            GitToast.dismiss()
            app.showsWindowColumn = true
        }
        /// A fresh record, the column on or off as `shown`, hidden long ago with two windows when off.
        func fresh(shown: Bool) {
            app.showsWindowColumn = shown
            for key in WindowColumnOffer.keys { defaults.removeObject(forKey: key) }
            if !shown {
                defaults.set(2, forKey: WindowColumnOffer.hiddenWithKey)
                defaults.set(Date().addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970, forKey: WindowColumnOffer.hiddenAtKey)
            }
            GitToast.dismiss()
            app.windowColumns.resetOffersForTest()
        }
        /// A window opened, the notice it brings (nil for none after a moment), and the window to close after.
        func opening() async -> (TerminalWindowController?, String?) {
            let opened = await open()
            _ = await wait(2) { GitToast.text != nil }
            return (opened, GitToast.text)
        }

        // The column on, five windows or more: once, how to hide it; Keep It keeps it.
        fresh(shown: true)
        let (tipWindow, tip) = await opening()
        let count: Int = app.windowIndex.windows.count
        GitToast.pressOtherButtonForTest()
        let kept: Bool = app.showsWindowColumn && defaults.bool(forKey: WindowColumnOffer.hideTipKey)
        check(tip == WindowColumnOffer.text(.hide, windows: count, key: key) && kept,
              "window column: with five windows or more it says once how to hide it, and Keep It keeps it", tip ?? "no notice")
        if let tipWindow { await close(tipWindow) }

        // Hidden: the offer to show it; Show shows it in every window and ends the offer.
        fresh(shown: false)
        let (showWindow, offer) = await opening()
        let showCount: Int = app.windowIndex.windows.count
        GitToast.pressButtonForTest()
        let all: [TerminalWindowController] = app.controllers.filter { !$0.hasClosed }
        for each in all { each.window?.layoutIfNeeded() }
        let shownEverywhere: Bool = app.showsWindowColumn && all.allSatisfy { $0.columnHost.shown.form != .hidden }
        check(offer == WindowColumnOffer.text(.show, windows: showCount, key: key) && shownEverywhere && defaults.bool(forKey: WindowColumnOffer.showOfferedKey),
              "window column: hidden, with more windows open it offers to show it, and Show shows it in every window", offer ?? "no notice")
        if let showWindow { await close(showWindow) }

        // Don't Ask Again: never again, a fresh launch included.
        fresh(shown: false)
        let (declinedWindow, declined) = await opening()
        GitToast.pressOtherButtonForTest()
        if let declinedWindow { await close(declinedWindow) }
        app.windowColumns.resetOffersForTest()
        let (againWindow, again) = await opening()
        check(declined != nil && again == nil && !app.showsWindowColumn,
              "window column: Don’t Ask Again ends the offer, the column staying hidden", again ?? "")
        if let againWindow { await close(againWindow) }

        // Shown some other way while the offer is up: the offer goes.
        fresh(shown: false)
        let (switchWindow, switchOffer) = await opening()
        app.showsWindowColumn = true
        check(switchOffer != nil && GitToast.text == nil, "window column: the setting changed while the offer shows takes the offer away", switchOffer ?? "no notice")
        if let switchWindow { await close(switchWindow) }

        // The launch's reopening offers nothing, and one launch offers once.
        fresh(shown: false)
        app.windowColumns.holdsOffers = true
        let (heldWindow, held) = await opening()
        app.windowColumns.holdsOffers = false
        if let heldWindow { await close(heldWindow) }
        let (firstWindow, firstOffer) = await opening()
        GitToast.dismiss()
        defaults.set(false, forKey: WindowColumnOffer.showOfferedKey) // due again, but this launch has offered
        let (secondWindow, second) = await opening()
        check(held == nil && firstOffer != nil && second == nil,
              "window column: no offer while the launch reopens projects, and one launch offers once", "held \(held ?? "none"), second \(second ?? "none")")
        for opened in [firstWindow, secondWindow] { if let opened { await close(opened) } }
    }
}
#endif
