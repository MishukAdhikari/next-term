import AppKit
import NextTermCore

/// The terminal and chat switch's ways in, in a window (plan 036 U3, U4): ⇧⌘J and View › Switch to Chat or Switch to
/// Terminal act on the tab (or pane) with the keyboard; the icon before a tab's × and the tab's right-click menu act on
/// that tab's pane with the keyboard, in front or not. All of them run ViewSwitchRunner, which says in the tab why a
/// switch is refused. While a chat view's "Open in Terminal" bar is open, its offer counts, even after its session ended
/// (U5).
extension TerminalWindowController {
    /// ⇧⌘J, View › Switch to Chat or Terminal.
    @objc func switchView(_ sender: Any?) {
        guard let tab = activeTab, ViewSwitchRunner.switchOffer(for: tab) != nil else { return NSSound.beep() }
        ViewSwitchRunner.start(tab: tab)
    }

    /// The icon or the right-click menu of tab `group`: its pane with the keyboard, as its title and icon follow.
    func switchView(of group: PaneGroup) {
        let tab = group.focused
        guard ViewSwitchRunner.switchOffer(for: tab) != nil else { return }
        ViewSwitchRunner.start(tab: tab)
    }

    /// View's item: titled for the tab with the keyboard ("Switch to Chat" in front of a terminal view, "Switch to
    /// Terminal" in front of a chat view), and off where no switch is offered or one runs already. A tab that offers
    /// the switch but would refuse it keeps the item on: its use says why in the tab (KTD2).
    func validateViewSwitch(_ item: NSMenuItem) -> Bool {
        let offer: ViewSwitch.Offer? = activeTab.flatMap { ViewSwitchRunner.switchOffer(for: $0) }
        let title = Self.viewSwitchTitle(offer)
        if item.title != title { item.title = title }
        guard let offer else { return false }
        return !offer.switching
    }

    /// "Switch to Chat" or "Switch to Terminal"; with no offer, the name the menu is built with.
    static func viewSwitchTitle(_ offer: ViewSwitch.Offer?) -> String {
        "Switch to " + (offer?.view.other ?? .chat).title
    }

    /// The tab's right-click menu's item, after Rename…, while its pane with the keyboard offers the switch.
    func addViewSwitch(to menu: NSMenu, for group: PaneGroup) {
        guard let offer = ViewSwitchRunner.switchOffer(for: group.focused) else { return }
        menu.addCommand(Self.viewSwitchTitle(offer), "switchView:", enabled: !offer.switching) { [weak self, weak group] in
            guard let self, let group else { return }
            self.switchView(of: group)
        }
    }
}

/// The icon before a tab's × in the top bar and in the tab list (plan 036 KTD9, R8, R9): the ×'s size and weight, in the
/// secondary text colour, at half strength while dimmed. It never takes the keyboard from the terminal. What it shows
/// is ViewSwitch.mark's, worked out by its tab from its own hover and selection.
final class ViewSwitchButton: NSButton {
    /// What it shows; nil while hidden.
    private(set) var shown: ViewSwitch.Mark?
    /// The top bar's tab sets its own tooltip; the tab list shows one tooltip for all its rows (TabListView.rowToolTip).
    private let ownsToolTip: Bool
    private var tip: ShortcutToolTip?

    init(ownsToolTip: Bool = true) {
        self.ownsToolTip = ownsToolTip
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = Theme.textDim
        refusesFirstResponder = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The tooltip for `mark`: its words with the user's own key for the switch ("Switch to Chat (⇧⌘J)"), and no key
    /// while a switch runs.
    static func toolTip(for mark: ViewSwitch.Mark) -> String {
        mark.enabled ? KeyboardShortcuts.shared.hint(mark.tooltip, #selector(TerminalWindowController.switchView(_:))) : mark.tooltip
    }

    /// Shows `mark` (nil: nothing), touching only what changed, as it is called with every refresh of its tab. Returns
    /// whether it came or went, for its tab to lay its title out again.
    @discardableResult
    func show(_ mark: ViewSwitch.Mark?) -> Bool {
        guard mark != shown else { return false }
        let old = shown
        shown = mark
        let hidden = mark == nil
        let changed = isHidden != hidden
        if changed { isHidden = hidden }
        guard let mark else {
            tip = nil
            return changed
        }
        if mark.glyph != old?.glyph {
            image = NSImage(systemSymbolName: mark.glyph.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        }
        let alpha: CGFloat = mark.dimmed ? 0.5 : 1
        if alphaValue != alpha { alphaValue = alpha }
        if isEnabled != mark.enabled { isEnabled = mark.enabled }
        if ownsToolTip, mark.tooltip != old?.tooltip || mark.enabled != old?.enabled {
            if mark.enabled {
                tip = ShortcutToolTip(self, mark.tooltip, #selector(TerminalWindowController.switchView(_:)))
            } else {
                tip = nil
                toolTip = mark.tooltip
            }
        }
        setAccessibilityLabel(mark.spoken)
        return changed
    }
}
