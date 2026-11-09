import AppKit
import NextTermCore

#if DEBUG
/// The window column's three hints (plan 033 R3), in two windows, with the clocks and the front window stood in for so
/// none of it waits a minute or a day: each shows when its trigger fires and every rule lets it, and not while the user
/// types or in a window under a minute old; its showing counts after it has been up a second (here, a fifth); one hint at
/// a time; a passive one retires at its third showing; each retires when its feature is used (H1 by its own button and by
/// View › Window Column Position, H2 by Go to Next Agent Needing You, H3 by the list opening); × retires it; the off switch
/// takes every hint down and shows none; Reset Tips and Help › Show Tips Again bring them back. H1 is screenshotted in the
/// hover list. NEXTTERM_SELFTEST_ONLY=hints runs it alone.
extension SelfTest {
    static func hintsChecks() async {
        guard let app = AppDelegate.shared else { return }
        guard let first = app.controllers.first(where: { !$0.hasClosed }), let firstWindow = first.window else {
            return check(false, "hints: a window to start from")
        }
        let defaults = UserDefaults.standard
        let saved = (hints: HintRules.keys.map { defaults.object(forKey: $0) }, shown: defaults.object(forKey: WindowColumnSettings.shownKey),
                     expanded: defaults.object(forKey: WindowColumnSettings.expandedKey), side: defaults.object(forKey: "windowColumnSide"),
                     sidebar: app.sidebarSide)
        let clocks = (sinceKey: HintCenter.sinceKey, age: HintCenter.windowAge, exposure: HintCenter.exposureDelay)
        let timing = (dwell: ColumnHints.listDwell, stays: HintStage.stays, looks: HintStage.looksEvery, front: HintStage.front)
        let host: WindowColumnHost = first.columnHost
        let pointer: () -> NSPoint = WindowColumnHost.pointerLocation
        let motion: () -> Bool = WindowColumnHost.reducesMotion
        let contrast: Bool? = DisplayOptions.increasesContrastOverride
        var second: TerminalWindowController?
        defer {
            HintStage.shared.resetForTest()
            host.hideList(animated: false)
            if let second, !second.hasClosed { second.window?.close() }
            HintCenter.sinceKey = clocks.sinceKey
            HintCenter.windowAge = clocks.age
            HintCenter.exposureDelay = clocks.exposure
            ColumnHints.listDwell = timing.dwell
            HintStage.stays = timing.stays
            HintStage.looksEvery = timing.looks
            HintStage.front = timing.front
            WindowColumnHost.pointerLocation = pointer
            WindowColumnHost.reducesMotion = motion
            DisplayOptions.increasesContrastOverride = contrast
            if app.sidebarSide != saved.sidebar { app.toggleSidebarSide(nil) }
            app.setWindowColumnSide(saved.sidebar)
            // Showing, counting and retiring wrote the hints' keys, and moving and pinning the column its own: as they were.
            for (key, value) in zip(HintRules.keys, saved.hints) { restoreDefault(value, key) }
            restoreDefault(saved.shown, WindowColumnSettings.shownKey)
            restoreDefault(saved.expanded, WindowColumnSettings.expandedKey)
            restoreDefault(saved.side, "windowColumnSide")
            WindowColumns.suppressed = true
            HintStage.suppressed = true
            app.windowColumns.rebuild()
        }
        // The user is never typing, every window has been open long enough, and the window in front is the first; a
        // showing counts after a fifth of a second, and H2 and H3 stay up for a little over half a second.
        HintCenter.sinceKey = { 60 }
        HintCenter.windowAge = { _ in 600 }
        HintCenter.exposureDelay = 0.2
        ColumnHints.listDwell = 0.2
        HintStage.stays = 0.6
        HintStage.looksEvery = 0.1
        HintStage.front = { first }
        // The real pointer is on no list, and the hints come in at once.
        WindowColumnHost.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
        WindowColumnHost.reducesMotion = { true }
        WindowColumns.suppressed = false
        HintStage.suppressed = false
        app.showsWindowColumn = true
        app.windowColumnExpanded = false
        if app.sidebarSide != .left { app.toggleSidebarSide(nil) }
        app.setWindowColumnSide(.left)
        /// As a fresh install has them: nothing seen, retired or due, tips on, and the upgrade seeding done.
        func freshTips() {
            HintStage.shared.resetForTest()
            host.hideList(animated: false)
            HintRules.reset(defaults)
            defaults.removeObject(forKey: HintRules.tipsKey)
            defaults.set(true, forKey: HintRules.seededKey)
        }
        /// The day between two hints, gone: the next may show at once.
        func nextDay() { defaults.removeObject(forKey: HintRules.lastAnyShownKey) }
        freshTips()
        _ = await bringToFront(firstWindow)

        app.newWindow(nil)
        guard let made = app.controllers.last, made !== first, let tab = made.activeTab, await wait(20, { tab.status.integrated }) else {
            return check(false, "hints: a second window opens, its shell started")
        }
        second = made
        HintStage.front = { first } // the second came in front: the checks' front window is still the first
        firstWindow.layoutIfNeeded()
        guard await wait(3, { host.shown.form == .folded }) else {
            return check(false, "hints: with two windows the first shows its rail", "\(host.shown)")
        }
        // The column coming fired H3's trigger already: each check starts from nothing seen.
        freshTips()

        await basicsChecks(app, first, freshTips: freshTips, nextDay: nextDay)
        await sideChecks(app, first, freshTips: freshTips, nextDay: nextDay)
        await nextAgentChecks(app, first, made, freshTips: freshTips)
        await switchChecks(app, first, freshTips: freshTips, nextDay: nextDay)
    }

    /// H3: the column's first showing puts "Rest here…" beside the rail's foot, as static text, taking no keyboard; it
    /// counts after it has been up a while, goes after a few seconds, and holds back for typing and a new window, waiting
    /// while its column shows; at its third showing it retires; opening the list retires it.
    private static func basicsChecks(_ app: AppDelegate, _ c: TerminalWindowController, freshTips: () -> Void, nextDay: () -> Void) async {
        let host: WindowColumnHost = c.columnHost
        let keyboard: NSResponder? = c.window?.firstResponder
        ColumnHints.shared.columnAppeared()
        let up: Bool = await wait(2) { host.hint?.hint == .columnBasics }
        if up { await screenshot(c, suffix: "-hint-column-basics") }
        let line: HintLine? = host.hint
        let beside: Bool = line.map { $0.beside && $0.superview === host && abs($0.frame.minX - host.column.frame.maxX) < 0.5 } ?? false
        let staticText: Bool = line?.label?.accessibilityRole() == .staticText && line?.label?.accessibilityHelp() == HintWords.columnBasics
        check(up && line?.wordsWhole == true && line?.words == HintWords.columnBasics && beside && staticText && HintCenter.shared.visible?.hint == .columnBasics
                && c.window?.firstResponder === keyboard && line?.alphaValue == 1,
              "hints: the column's first showing puts “Rest here to see your windows” beside the rail's foot, as static text, at once with Reduce Motion and without the keyboard",
              "up \(up), “\(line?.words ?? "")”, plate \(line?.frame ?? .zero), words \(line?.label?.frame ?? .zero) of \(line?.wordsWidth ?? 0), font \(line?.label?.font?.pointSize ?? 0), beside \(beside), static text \(staticText), keyboard kept \(c.window?.firstResponder === keyboard)")
        let counted: Bool = await wait(1) { HintCenter.shared.record(.columnBasics).shown == 1 }
        check(counted, "hints: up past its exposure time, a showing counts", "\(HintCenter.shared.record(.columnBasics))")
        // Another hint's moment, while this one is up: it holds back.
        check(!HintCenter.shared.eligible(.columnSide, in: c), "hints: one hint at a time across the app")
        let went: Bool = await wait(2) { host.hint == nil && HintCenter.shared.visible == nil }
        check(went, "hints: after a few seconds the line goes by itself")

        // Typing holds it back, and it waits: the keys left alone, it shows.
        nextDay()
        HintCenter.sinceKey = { 0.5 }
        ColumnHints.shared.columnAppeared()
        await pause(0.4)
        let heldForKeys: Bool = host.hint == nil && HintStage.shared.isWaiting(.columnBasics)
        HintCenter.sinceKey = { 60 }
        let cameLater: Bool = await wait(2) { host.hint?.hint == .columnBasics }
        check(heldForKeys && cameLater, "hints: never while the user is typing; the trigger waits, and once the keys are left alone it shows",
              "held \(heldForKeys), came \(cameLater)")
        _ = await wait(2) { host.hint == nil }
        // A window under a minute old: nothing.
        nextDay()
        HintCenter.windowAge = { _ in 10 }
        ColumnHints.shared.columnAppeared()
        await pause(0.4)
        let heldForAge: Bool = host.hint == nil
        HintCenter.windowAge = { _ in 600 }
        _ = await wait(2) { host.hint != nil }
        _ = await wait(2) { host.hint == nil }
        check(heldForAge && HintCenter.shared.record(.columnBasics).shown == 3 && HintCenter.shared.record(.columnBasics).retired == .countReached,
              "hints: never in a window open under a minute; a passive hint retires at its third showing",
              "held \(heldForAge), \(HintCenter.shared.record(.columnBasics))")
        nextDay()
        ColumnHints.shared.columnAppeared()
        await pause(0.4)
        check(host.hint == nil, "hints: retired, it shows no more")

        // Resting on the rail opens the list: the basics are known.
        freshTips()
        host.showList()
        let retired: HintRules.Retirement? = HintCenter.shared.record(.columnBasics).retired
        host.hideList(animated: false)
        check(retired == .actionPerformed, "hints: the list opening on the rail retires the column's basics", "\(String(describing: retired))")
    }

    /// H1: the list open a moment shows "⇄ Move column right" at its foot as a real button with its tooltip; it
    /// counts; a click moves the column and retires it, as View › Window Column Position does; × retires it.
    private static func sideChecks(_ app: AppDelegate, _ c: TerminalWindowController, freshTips: () -> Void, nextDay: () -> Void) async {
        let host: WindowColumnHost = c.columnHost
        freshTips()
        HintCenter.shared.retire(.columnBasics, reason: .closed) // its own checks are done
        host.showList()
        let up: Bool = await wait(2) { host.hint?.hint == .columnSide }
        host.list?.layoutSubtreeIfNeeded() // as the next display would: the line was just put up
        let line: HintLine? = host.hint
        let words = HintWords.columnSide(onRight: false)
        let inList: Bool = line.map { host.hintInList && $0.superview === host.list && !$0.beside } ?? false
        let button: NSButton? = line?.button
        let real: Bool = line?.wordsWhole == true && button?.title == "⇄ Move column right" && button?.toolTip == words.help && button?.isBordered == false
            && button?.accessibilityHelp() == words.help && button?.refusesFirstResponder == true
        // Above the list's foot, the rows left clear of it.
        let foot: NSRect = host.list?.hideButton.frame ?? .zero
        let rows: CGFloat = host.list?.shownButtons.map(\.frame.maxY).max() ?? 0
        let placed: Bool = line.map { abs($0.frame.maxY - foot.minY) < 0.5 && rows <= $0.frame.minY } ?? false
        check(up && inList && real && placed,
              "hints: the list open a moment shows “⇄ Move column right” at its foot, a real borderless button with “Or ask your agent…” as its tooltip",
              "up \(up), in the list \(inList), button “\(button?.title ?? "")” tip “\(button?.toolTip ?? "")”, line \(line?.frame ?? .zero), foot \(foot), rows end \(rows)")
        await screenshot(c, suffix: "-hint-column-side")
        let counted: Bool = await wait(1) { HintCenter.shared.record(.columnSide).shown == 1 }
        button?.performClick(nil)
        let moved: Bool = await wait(2) { app.windowColumnOnRight && host.columnOnRight }
        check(counted && moved && HintCenter.shared.record(.columnSide).retired == .actionPerformed && host.hint == nil && !host.listShowing,
              "hints: it counts once seen, and its button moves the column to the right edge and retires it",
              "counted \(counted), moved \(moved), \(HintCenter.shared.record(.columnSide))")
        app.setWindowColumnSide(.left)

        // View › Window Column Position › Right retires it too.
        freshTips()
        HintCenter.shared.retire(.columnBasics, reason: .closed)
        let item = NSMenuItem(title: "Right", action: #selector(AppDelegate.chooseWindowColumnSide(_:)), keyEquivalent: "")
        item.representedObject = "right"
        app.chooseWindowColumnSide(item)
        check(HintCenter.shared.record(.columnSide).retired == .actionPerformed, "hints: moving the column from the View menu retires it",
              "\(HintCenter.shared.record(.columnSide))")
        app.setWindowColumnSide(.left)
        _ = await wait(2) { host.shown.form == .folded && !host.columnOnRight }

        // On the right edge, it offers the left.
        freshTips()
        HintCenter.shared.retire(.columnBasics, reason: .closed)
        app.setWindowColumnSide(.right) // retires it: brought back below, the column staying on the right
        UserDefaults.standard.removeObject(forKey: HintRules.key(.columnSide, .retired))
        _ = await wait(2) { host.columnOnRight && host.shown.form == .folded }
        host.showList()
        _ = await wait(2) { host.hint?.hint == .columnSide }
        let left: String = host.hint?.button?.title ?? ""
        check(left == "⇄ Move column left", "hints: with the column on the right it offers the left edge", "“\(left)”")
        // × closes it for good.
        host.hint?.setHoveringForTest(true)
        let shows: Bool = host.hint?.closeButton.alphaValue == 1
        host.hint?.closeButton.performClick(nil)
        let closed: Bool = host.hint == nil && HintCenter.shared.record(.columnSide).retired == .closed
        host.hideList(animated: false)
        nextDay()
        host.showList()
        await pause(0.5)
        check(shows && closed && host.hint == nil, "hints: its × shows under the pointer and closes it for good",
              "× shown \(shows), closed \(closed), \(HintCenter.shared.record(.columnSide))")
        host.hideList(animated: false)
        app.setWindowColumnSide(.left)
        _ = await wait(2) { host.shown.form == .folded && !host.columnOnRight }
    }

    /// H2: a bell in a tab of the second window marks it; the first, in front, says "Press ⇧⌘U to jump to it" with the
    /// key as the user has it, at its column's foot; Go to Next Agent Needing You retires it.
    private static func nextAgentChecks(_ app: AppDelegate, _ c: TerminalWindowController, _ other: TerminalWindowController,
                                        freshTips: () -> Void) async {
        let host: WindowColumnHost = c.columnHost
        freshTips()
        HintCenter.shared.retire(.columnBasics, reason: .closed)
        HintCenter.shared.retire(.columnSide, reason: .closed)
        let behind: TerminalTab = other.addTab(directory: NSTemporaryDirectory(), select: false)
        guard await wait(20, { behind.status.integrated }) else { return check(false, "hints: the second window's tab behind starts its shell") }
        await pause(0.5)
        behind.view.send(txt: "printf '\\a'\r")
        guard await wait(5, { behind.status.state == .attention }) else { return note("hints: H2 not checked, the bell did not ring") }
        for controller in app.controllers { controller.refresh() }
        let up: Bool = await wait(4) { host.hint?.hint == .nextAgent }
        if up { await screenshot(c, suffix: "-hint-next-agent") }
        let key: String? = KeyboardShortcuts.shared.chord(for: "goToNextAgentNeedingYou:")?.display
        let words: String? = HintWords.nextAgent(key: key)
        check(up && words != nil && host.hint?.words == words && host.hint?.beside == true && host.hint?.wordsWhole == true,
              "hints: a needs-you mark in another window says “Press \(key ?? "?") to jump to it” at the front window's column foot",
              "up \(up), “\(host.hint?.words ?? "")”")
        app.goToNextAgentNeedingYou(nil)
        check(HintCenter.shared.record(.nextAgent).retired == .actionPerformed && host.hint == nil,
              "hints: Go to Next Agent Needing You retires it", "\(HintCenter.shared.record(.nextAgent))")
        other.remove(behind)
        if let window = c.window { _ = await bringToFront(window) }

        // Beside the rail only over the project sidebar: with the sidebar hidden, nothing goes over the text.
        let wasShown: Bool = c.isSidebarVisible
        c.setSidebarVisible(false)
        await pause(0.3)
        let probe = HintLine(.columnBasics, words: HintWords.columnBasics)
        let overText: Bool = host.showHint(probe, inList: false)
        if overText { host.removeHint() }
        c.setSidebarVisible(wasShown)
        check(!overText, "hints: with the project sidebar hidden, a hint beside the rail waits rather than cover the editor or terminal")
    }

    /// The off switch takes the hint up down and shows none; Reset Tips and Help › Show Tips Again bring them back.
    private static func switchChecks(_ app: AppDelegate, _ c: TerminalWindowController, freshTips: () -> Void, nextDay: () -> Void) async {
        let host: WindowColumnHost = c.columnHost
        freshTips()
        ColumnHints.shared.columnAppeared()
        let up: Bool = await wait(2) { host.hint != nil }
        HintCenter.shared.tipsOn = false
        let down: Bool = host.hint == nil && HintCenter.shared.visible == nil
        ColumnHints.shared.columnAppeared()
        host.showList()
        await pause(0.5)
        let none: Bool = host.hint == nil
        host.hideList(animated: false)
        check(up && down && none, "hints: tips turned off take the hint up down, and none shows", "up \(up), down \(down), none \(none)")
        HintCenter.shared.tipsOn = true
        for hint in Hint.allCases { HintCenter.shared.retire(hint, reason: .closed) }
        HintCenter.shared.reset()
        let fresh: Bool = Hint.allCases.allSatisfy { HintCenter.shared.record($0) == HintRules.Record() }
        ColumnHints.shared.columnAppeared()
        let back: Bool = await wait(2) { host.hint?.hint == .columnBasics }
        check(fresh && back, "hints: Reset Tips brings back the tips closed", "fresh \(fresh), back \(back)")
        HintStage.shared.resetForTest()
        for hint in Hint.allCases { HintCenter.shared.retire(hint, reason: .closed) }
        app.showTipsAgain(nil)
        check(Hint.allCases.allSatisfy { HintCenter.shared.record($0).retired == nil }, "hints: Help › Show Tips Again does the same")
        // Increase Contrast: the words in the label colour.
        nextDay()
        DisplayOptions.increasesContrastOverride = true
        ColumnHints.shared.columnAppeared()
        _ = await wait(2) { host.hint != nil }
        check(host.hint?.label?.textColor == Theme.text, "hints: with Increase Contrast the words are in the label colour",
              String(describing: host.hint?.label?.textColor))
        DisplayOptions.increasesContrastOverride = nil
        HintStage.shared.resetForTest()
    }
}
#endif
