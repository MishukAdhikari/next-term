import AppKit
import NextTermCore

/// The keys beside the window's icon buttons ("⌘B" before the sidebar icon, as a tab shows "⌘1"): each
/// names its command's key, follows a new one, goes when the key is removed, and gives way when room is
/// short, before anything else in the tab bar, the sidebar's header or the rail would.
extension SelfTest {
    static func keyHintChecks(_ c: TerminalWindowController) async {
        let shortcuts = KeyboardShortcuts.shared
        let saved = UserDefaults.standard.data(forKey: "keyBindings")
        defer {
            UserDefaults.standard.set(saved, forKey: "keyBindings")
            shortcuts.apply()
        }
        UserDefaults.standard.removeObject(forKey: "keyBindings")
        shortcuts.apply()
        tabBarKeyHintChecks()
        headerKeyHintChecks()
        railKeyHintChecks()
        popupKeyHintChecks(c.branchPopup)
        // The window's own arrow: VoiceOver hears what it does, and the key once, in its help.
        let arrow = c.tabBar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("the terminal") == true }
        check(arrow?.accessibilityLabel()?.contains("⌘") == false && arrow?.accessibilityHelp() == shortcuts.chord(for: "toggleTerminalCollapsed:")?.display,
              "key hints: the terminal's arrow names its key once, in its help", "\(arrow?.accessibilityLabel() ?? "no arrow") | \(arrow?.accessibilityHelp() ?? "none")")
    }

    /// Whether VoiceOver is given any of `fields` among `view`'s children. It gets a control's cell, not the
    /// control, so a field that says it is no element is still heard while its cell is one.
    private static func voiceOverHears(_ fields: [NSTextField], in view: NSView?) -> Bool {
        let cells = fields.compactMap(\.cell)
        let children = view?.accessibilityChildren() ?? []
        return children.contains { child in cells.contains { $0 === child as AnyObject } }
    }

    /// The pointer coming onto a view or leaving it, as AppKit tells a tracking area's owner.
    private static func crossing(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    /// The pointer comes onto `hint`'s button in `view` (or leaves it), through the tracking area the hint keeps
    /// on the button. False when there is none.
    private static func pointer(onto hint: KeyHint?, in view: NSView, _ onto: Bool) -> Bool {
        var area: NSTrackingArea?
        for case let button as NSButton in view.subviews where area == nil {
            area = button.trackingAreas.first { $0.owner === hint }
        }
        guard let owner = area?.owner as? NSResponder, let event = crossing(onto ? .mouseEntered : .mouseExited) else { return false }
        if onto { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
        return true
    }

    private static func tabBarKeyHintChecks() {
        let shortcuts = KeyboardShortcuts.shared
        func key(_ id: String) -> String? { shortcuts.chord(for: id)?.display }
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: TabBarView.height))
        bar.showsSidebarButton = true
        bar.moreMenu = { NSMenu() }
        bar.onToggleCollapse = {}
        bar.setCollapseButton(symbol: "chevron.down", toolTip: "Collapse the terminal", label: "Collapse the terminal")
        let items = ["claude", "zsh", "npm run dev"].enumerated().map { i, title in
            TabBarItem(title: title, state: .idle, tooltip: title, accessibilityStatus: "", shortcut: "⌘\(i + 1)")
        }
        bar.update(items: Array(items.prefix(2)), selectedIndex: 0)
        var keys = bar.shownKeys
        check(keys.sidebar == key("toggleProjectSidebar:") && keys.newTab == key("newTab:") && keys.collapse == key("toggleTerminalCollapsed:")
                && keys.sidebar != nil && keys.newTab != nil && keys.collapse != nil,
              "key hints: the tab bar's sidebar, + and fold buttons show their keys, as the tabs show ⌘1", "\(keys)")
        let hints = bar.subviews.compactMap { $0 as? KeyHint }
        let helped = bar.subviews.compactMap { $0 as? NSButton }.filter { $0.accessibilityHelp() == key("newTab:") }
        let tab = bar.tabView(at: 0)
        let tabKey = tab?.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden && $0.stringValue == "⌘1" } ?? []
        let heard = voiceOverHears(hints, in: bar) || tabKey.isEmpty || voiceOverHears(tabKey, in: tab)
        check(!hints.isEmpty && !heard && helped.count == 1,
              "key hints: VoiceOver hears a key once, as its button's or its tab's help", "heard \(heard), \(helped.count) buttons with ⌘T")

        // Settings changes a key: the hint follows at once, says nothing without one, and comes back.
        shortcuts.set(KeyChord(key: "j", command: true, control: true), for: "toggleTerminalCollapsed:")
        check(bar.shownKeys.collapse == "⌃⌘J", "key hints: a new key shows at once", bar.shownKeys.collapse ?? "none")
        shortcuts.set(nil, for: "toggleTerminalCollapsed:")
        check(bar.shownKeys.collapse == nil, "key hints: and none shows when the command has no key", bar.shownKeys.collapse ?? "none")
        shortcuts.reset("toggleTerminalCollapsed:")
        check(bar.shownKeys.collapse == "⌘J", "key hints: and back", bar.shownKeys.collapse ?? "none")

        // The editor's ⌖ button: its command has no key until one is given.
        let editor = TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: TabBarView.height))
        editor.allowsNewTab = false
        editor.onReveal = {}
        editor.update(items: [TabBarItem(title: "a.txt", state: .idle, tooltip: "", accessibilityStatus: "")], selectedIndex: 0)
        let none = editor.shownKeys.reveal
        shortcuts.set(KeyChord(key: "l", command: true, control: true), for: "revealInSidebar:")
        let given = editor.shownKeys.reveal
        shortcuts.reset("revealInSidebar:")
        check(none == nil && given == "⌃⌘L", "key hints: Show File in Project Sidebar shows a key only once it has one", "\(none ?? "none"), then \(given ?? "none")")

        // Narrower and narrower: the tabs are as wide, and as many show, as they would without any key.
        bar.update(items: items, selectedIndex: 0)
        func tabs() -> [String] {
            stride(from: 300, through: 1100, by: 10).map { width -> String in
                bar.setFrameSize(NSSize(width: CGFloat(width), height: TabBarView.height))
                bar.needsLayout = true
                bar.layoutSubtreeIfNeeded()
                return "\(width): \(bar.visibleRange.count) × \(bar.tabView(at: 0)?.frame.width ?? 0)"
            }
        }
        let withKeys = tabs()
        let shownAt = [420, 1100].map { width -> Bool in
            bar.setFrameSize(NSSize(width: CGFloat(width), height: TabBarView.height))
            bar.needsLayout = true
            keys = bar.shownKeys
            return keys.sidebar != nil || keys.newTab != nil || keys.collapse != nil
        }
        for id in ["toggleProjectSidebar:", "newTab:", "toggleTerminalCollapsed:"] { shortcuts.set(nil, for: id) }
        let withoutKeys = tabs()
        for id in ["toggleProjectSidebar:", "newTab:", "toggleTerminalCollapsed:"] { shortcuts.reset(id) }
        let changed = zip(withKeys, withoutKeys).filter { $0 != $1 }.map { "\($0) vs \($1)" }
        check(changed.isEmpty && shownAt == [false, true], "key hints: in a narrow tab bar they give way before a tab narrows or goes behind »",
              "shown at 420 and 1100: \(shownAt); " + changed.prefix(3).joined(separator: "; "))

        // There, one that gave way shows while the pointer is on its button, and a click where it shows still
        // reaches what is under it. The sidebar icon's shows after it: before it are the window's buttons.
        bar.setFrameSize(NSSize(width: 420, height: TabBarView.height))
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        let plus = hints.first { $0.key == key("newTab:") }
        let entered = pointer(onto: plus, in: bar, true)
        let hovered = plus?.hoverKey
        let box = plus?.hoverFrame ?? .zero
        let spot = bar.convert(NSPoint(x: box.midX, y: box.midY), to: nil)
        let through = bar.hitTest(spot)
        _ = pointer(onto: plus, in: bar, false)
        let under = bar.hitTest(spot)
        let left = plus?.hoverKey
        let clickedThrough = under != nil && through === under && !(through is KeyHintOverlay)
        check(entered && bar.shownKeys.newTab == nil && hovered == key("newTab:") && left == nil && clickedThrough,
              "key hints: in a narrow tab bar the +'s key shows while the pointer is on it, lets a click through, and goes as it leaves",
              "\(hovered ?? "none"), then \(left ?? "none"); a click there reaches \(String(describing: through)), without it \(String(describing: under))")
        let sidebar = hints.first { $0.key == key("toggleProjectSidebar:") }
        _ = pointer(onto: sidebar, in: bar, true)
        let sidebarKey = sidebar?.hoverKey
        let sidebarBox = sidebar?.hoverFrame ?? .zero
        _ = pointer(onto: sidebar, in: bar, false)
        check(sidebarKey == key("toggleProjectSidebar:") && sidebarBox.minX >= bar.leadingInset,
              "key hints: the sidebar icon's key shows clear of the window's buttons", "\(sidebarKey ?? "none") at \(sidebarBox)")
    }

    private static func headerKeyHintChecks() {
        let shortcuts = KeyboardShortcuts.shared
        let header = SidebarHeaderView(frame: NSRect(x: 0, y: 0, width: 460, height: TabBarView.height))
        header.inset = 70
        header.onRight = false
        header.onBranchClick = {}
        var snapshot = GitSnapshot(root: NSTemporaryDirectory())
        snapshot.branch = "feature/key-hints"
        snapshot.upstream = "origin/feature/key-hints"
        snapshot.behind = 152
        snapshot.folderStats[""] = LineStats(added: 41, removed: 10, files: 3)
        header.show(snapshot)
        func layOut(_ width: Int) {
            header.setFrameSize(NSSize(width: CGFloat(width), height: TabBarView.height))
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
        }
        layOut(460)
        let key = shortcuts.chord(for: "toggleProjectSidebar:")?.display
        check(key != nil && header.shownHideKey == key && !header.titleIsTruncated && header.summaryIsShown && header.syncText == "Pull 152",
              "key hints: the sidebar's hide button shows its key beside the branch, its counts and Pull, all in full",
              "\(header.shownHideKey ?? "none"), \(header.syncText)")
        let heard = voiceOverHears(header.subviews.compactMap { $0 as? KeyHint }, in: header)
        check(header.hideButton.accessibilityHelp() == key && header.hideButton.accessibilityLabel()?.contains("⌘") == false && !heard,
              "key hints: the hide button's help names the key, its label does not, and VoiceOver hears it there only",
              "\(header.hideButton.accessibilityHelp() ?? "none"), heard beside it \(heard)")

        // Narrower and narrower: the branch name, the counts, the glyph and Pull fare as they would without
        // the key, which goes first.
        func row() -> [String] {
            stride(from: 220, through: 520, by: 5).map { width -> String in
                layOut(width)
                let counts = header.summaryIsShown ? (header.summaryIsTruncated ? "cut" : "shown") : "hidden"
                return "\(width): \(header.titleIsTruncated) \(counts) \(header.branchGlyphIsShown) \(header.syncText)"
            }
        }
        let withKey = row()
        layOut(300)
        let narrow = header.shownHideKey
        shortcuts.set(nil, for: "toggleProjectSidebar:")
        let withoutKey = row()
        layOut(460)
        let removed = header.shownHideKey
        shortcuts.reset("toggleProjectSidebar:")
        let changed = zip(withKey, withoutKey).filter { $0 != $1 }.map { "\($0) vs \($1)" }
        check(changed.isEmpty && narrow == nil, "key hints: in a narrow header the key gives way before anything in it is cut or shortened",
              "at 300: \(narrow ?? "none"); " + changed.prefix(3).joined(separator: "; "))
        check(removed == nil, "key hints: the header's goes when ⌘B is removed", removed ?? "none")

        // There the key that gave way shows the moment the pointer is on the button, just before its icon,
        // over the counts or Pull. Nothing in the header moves for it, and it goes as the pointer leaves.
        layOut(300)
        let hint = header.subviews.compactMap { $0 as? KeyHint }.first
        let place = header.titleFrame
        let entered = pointer(onto: hint, in: header, true)
        let hovered = hint?.hoverKey
        let box = hint?.hoverFrame ?? .zero
        let held = header.titleFrame
        let labels = header.subviews.compactMap { $0 as? KeyHintOverlay }.map(\.label)
        let heardOver = labels.isEmpty || voiceOverHears(labels, in: header)
        _ = pointer(onto: hint, in: header, false)
        let left = hint?.hoverKey
        let icon = header.hideButton.frame.midX - (header.hideButton.image?.size.width ?? 0) / 2
        let beside = box.maxX <= icon && box.maxX >= icon - KeyHint.gap
        let came = entered && key != nil && hovered == key
        check(came && header.shownHideKey == nil && beside && left == nil,
              "key hints: in a narrow header the hide button's key shows while the pointer is on it, just before its icon, and goes as it leaves",
              "\(hovered ?? "none") at \(box), icon at \(icon); then \(left ?? "none")")
        check(held == place && header.titleFrame == place && !heardOver && header.hideButton.accessibilityHelp() == key,
              "key hints: the branch name keeps its place meanwhile, and VoiceOver hears the key in the button's help only",
              "\(place), then \(held) and \(header.titleFrame); heard over the row \(heardOver)")
    }

    /// The branch popup's Fetch key (⌘R unless Settings changes it), before its fetch button.
    private static func popupKeyHintChecks(_ popup: BranchPopupController) {
        let shortcuts = KeyboardShortcuts.shared
        let background = popup.panelWindow.contentView
        let fetch = background?.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix("Fetch") == true }
        let hints = background?.subviews.compactMap { $0 as? KeyHint } ?? []
        let heard = voiceOverHears(hints, in: background)
        let key = shortcuts.chord(for: "branchPopup.fetch")?.display
        let named = fetch?.accessibilityLabel() == "Fetch from all remotes" && fetch?.accessibilityHelp() == key
        check(key == "⌘R" && hints.map(\.key) == ["⌘R"] && !heard && named,
              "key hints: the branch popup's fetch button is heard by its words, with ⌘R once, in its help",
              "\(hints.map(\.key)), heard \(heard), \(fetch?.accessibilityLabel() ?? "no button") | \(fetch?.accessibilityHelp() ?? "none")")
        // It follows the key Settings gives Fetch, and goes while Fetch has none.
        defer { shortcuts.reset("branchPopup.fetch") }
        shortcuts.set(KeyChord(key: "r", command: true, option: true), for: "branchPopup.fetch")
        let moved = (hints.map(\.key), fetch?.accessibilityHelp(), hints.first?.isHidden)
        shortcuts.set(nil, for: "branchPopup.fetch")
        let removed = (hints.map(\.key), fetch?.accessibilityHelp(), hints.first?.isHidden)
        check(moved.0 == ["⌥⌘R"] && moved.1 == "⌥⌘R" && moved.2 == false && removed.0 == [""] && removed.1 == nil && removed.2 == true,
              "key hints: the branch popup's follows the key Settings gives Fetch, and goes without one", "\(moved), then \(removed)")
    }

    private static func railKeyHintChecks() {
        let rail = TerminalRail(frame: NSRect(x: 0, y: 0, width: TerminalRail.width, height: 400))
        let owners = (0..<6).map { _ in NSObject() }
        rail.update(marks: owners.map { TerminalRail.Mark(id: ObjectIdentifier($0), state: .idle, toolTip: "", label: "zsh", selected: false) })
        func layOut(_ height: Int) {
            rail.setFrameSize(NSSize(width: TerminalRail.width, height: CGFloat(height)))
            rail.needsLayout = true
            rail.layoutSubtreeIfNeeded()
        }
        layOut(400)
        let key = KeyboardShortcuts.shared.chord(for: "toggleTerminalCollapsed:")?.display
        check(key != nil && rail.shownKey == key, "key hints: the folded terminal's rail shows its key under the arrow", rail.shownKey ?? "none")
        func marks() -> [Int] {
            stride(from: 80, through: 300, by: 4).map { height -> Int in
                layOut(height)
                return rail.markButtons.filter { !$0.isHidden }.count
            }
        }
        let withKey = marks()
        layOut(150)
        let short = rail.shownKey
        KeyboardShortcuts.shared.set(nil, for: "toggleTerminalCollapsed:")
        let withoutKey = marks()
        KeyboardShortcuts.shared.reset("toggleTerminalCollapsed:")
        check(withKey == withoutKey && short == nil, "key hints: on a short rail it gives way before a tab's mark does",
              "at 150: \(short ?? "none"); \(withKey) vs \(withoutKey)")

        // There it shows under the arrow while the pointer is on the arrow, over the first mark, which stays.
        layOut(150)
        let hint = rail.subviews.compactMap { $0 as? KeyHint }.first
        let marks = rail.markButtons.map(\.frame)
        let arrow = rail.convert(NSPoint(x: TerminalRail.width / 2, y: rail.topInset + TabBarView.height / 2), to: nil)
        let below = rail.convert(NSPoint(x: TerminalRail.width / 2, y: rail.bounds.height - 10), to: nil)
        let moves = [arrow, below].compactMap {
            NSEvent.mouseEvent(with: .mouseMoved, location: $0, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 0, pressure: 0)
        }
        var seen: [String?] = []
        for move in moves {
            rail.mouseMoved(with: move)
            seen.append(hint?.hoverKey)
        }
        if let move = moves.first { rail.mouseMoved(with: move) }
        if let exit = crossing(.mouseExited) { rail.mouseExited(with: exit) }
        let left = hint?.hoverKey
        let onArrow = seen.first ?? nil
        let lower = seen.last ?? nil
        let stayed = rail.markButtons.map(\.frame) == marks
        check(moves.count == 2 && rail.shownKey == nil && onArrow == key && lower == nil && left == nil && stayed,
              "key hints: on a short rail the key shows while the pointer is on the arrow, and the marks stay put",
              "on the arrow \(onArrow ?? "none"), lower \(lower ?? "none"), gone \(left ?? "none")")
    }
}
