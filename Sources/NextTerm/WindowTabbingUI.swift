import AppKit
import NextTermCore

extension NSWindow {
    /// What a system tab bar and the title row above it take off the window's top while one shows (TitleBarCover); 0
    /// without one.
    var tabBarCover: CGFloat {
        guard tabGroup?.isTabBarVisible == true, let content = contentView else { return 0 }
        let layout: NSRect = content.convert(contentLayoutRect, from: nil)
        return TitleBarCover.top(contentHeight: content.bounds.height, layoutMaxY: layout.maxY, tabBarShown: true)
    }

    /// Where the window's own top row starts, in screen coordinates: its top, or under a system tab bar while one shows.
    /// Panels placed a set distance below a window's top (Go to File, Agent Sessions, the update prompt) go from here.
    var contentTop: CGFloat { frame.maxY - tabBarCover }
}

/// How Next Term places project windows as tabs (plan 032): macOS's automatic tabbing stays on for the user's own merges
/// (Merge All Windows, Show Tab Bar, dragging tabs), and Next Term decides where each window it shows goes.
enum WindowTabbing {
    /// Project windows merge as tabs of one window under this identifier; no other window has it.
    static let projectIdentifier = "NextTerm.project"

    /// For the self-test: project windows made meanwhile never merge, but in its own part (windowTabs).
    nonisolated(unsafe) static var suppressed = false

    /// `body` with macOS's automatic tabbing off: a window ordered in there opens apart, whatever System Settings'
    /// "Prefer tabs" says. Explicit tabbing still works meanwhile.
    static func withoutAutomaticTabbing(_ body: () -> Void) {
        let was: Bool = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        body()
        NSWindow.allowsAutomaticWindowTabbing = was
    }

    /// What a tab bar and the title row above it took off a window's top when one last showed, out of full screen: a restore
    /// lays merged windows out with it before their tab bar is there. Measured on this Mac, never assumed.
    static var measuredCover: CGFloat? {
        get {
            let saved: Double = UserDefaults.standard.double(forKey: measuredCoverKey)
            return saved > 0 && saved < 400 ? CGFloat(saved) : nil
        }
        set {
            guard newValue != measuredCover else { return }
            UserDefaults.standard.set(newValue.map(Double.init), forKey: measuredCoverKey)
        }
    }
    private static let measuredCoverKey = "windowTabBarCover"

    /// Whether macOS would open a document over `target` as a tab: "Prefer tabs" Always, or In Full Screen while it is.
    static func systemPrefersTabs(over target: TerminalWindowController) -> Bool {
        switch NSWindow.userTabbingPreference {
        case .always: return true
        case .inFullScreen: return target.window?.styleMask.contains(.fullScreen) == true
        default: return false
        }
    }
}

extension NSWindow {
    /// A window that is never a tab of another (Settings, Welcome, the viewers): merging and the tab commands are
    /// project windows' only.
    func keepsItsOwnFrame() {
        tabbingMode = .disallowed
    }

    /// Merged with other windows and not the tab in front: out of sight behind it. macOS still reports such a window
    /// visible and not minimized (probed on macOS 26.5), so whatever asks whether a window is seen asks this too.
    var isBackgroundTab: Bool {
        guard let group = tabGroup, group.windows.count > 1 else { return false }
        return group.selectedWindow !== self
    }

    /// The window on screen in its place: the tab in front of its group, or itself.
    var shownWindow: NSWindow { isBackgroundTab ? tabGroup?.selectedWindow ?? self : self }

    /// On screen in the window order: visible, not in the Dock, and in front of its group.
    var isShownFrame: Bool { isVisible && !isMiniaturized && !isBackgroundTab }

    /// The windows merged with this one as tabs, in the tab bar's order, this one among them; just this one when apart.
    var mergedWindows: [NSWindow] {
        guard let windows = tabGroup?.windows, windows.count > 1 else { return [self] }
        return windows
    }

    /// The window the user is in (UsersWindowRule): the tab shown in place of Next Term's key window, or of its main one
    /// while a panel or a sheet has the keyboard. A tab behind another is not, even holding the keyboard.
    var isUsersWindow: Bool {
        UsersWindowRule.isUsers(self, shown: shownWindow, keyShown: NSApp.keyWindow?.shownWindow, mainShown: NSApp.mainWindow?.shownWindow)
    }

    /// The keyboard to this window, made key, and brought to the front too with `raise`, while it is the tab in front of
    /// its group or a window of its own. A tab behind another is left as it is, and the keyboard with it: making it key
    /// would bring its tab to the front over the one the user chose. Returns whether it was given.
    @discardableResult
    func takeKeyboard(raise: Bool = true) -> Bool {
        guard UsersWindowRule.mayTakeKeyboard(self, shown: shownWindow) else { return false }
        if raise { makeKeyAndOrderFront(nil) } else { makeKey() }
        return true
    }
}

/// Where the user is among Next Term's windows, merged as tabs or not (UsersWindowRule), and the one repair that keeps the
/// keyboard there.
enum UsersWindow {
    /// The key window as the user sees it: the tab in front of its group when the keyboard sits in one behind it.
    static var key: NSWindow? { NSApp.keyWindow?.shownWindow }

    nonisolated(unsafe) private static var repairPending = false

    /// A panel or a window of Next Term's own (Go to Anything, an approval, Find in Files) is closing with the keyboard:
    /// AppKit hands the keyboard back to the window that had it before, and a tab behind another made key comes to the
    /// front, over the tab the user went to meanwhile. Until the close is over, no tab behind another takes the keyboard
    /// (TerminalWindow.canBecomeKey), so AppKit gives it to the tab in front.
    nonisolated(unsafe) private(set) static var keyWindowClosing = false

    /// Watches every window's close for `keyWindowClosing`; once, at launch.
    static func watchCloses() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, closing === NSApp.keyWindow, !(closing is TerminalWindow),
                      closing.sheetParent == nil, !keyWindowClosing else { return }
                keyWindowClosing = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        keyWindowClosing = false
                        repairSoon()
                    }
                }
            }
        }
    }

    /// The keyboard, or the main window, left in a tab behind another (by whatever route: a panel's close, a restore while
    /// the app was in the background) goes to the tab in front, a turn later, once for however many ask meanwhile. While
    /// the keyboard and the tab in front agree, nothing happens. A repair's own change of key asks again and finds nothing.
    static func repairSoon() {
        guard !repairPending, needsRepair != nil else { return }
        repairPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                repairPending = false
                switch needsRepair {
                case .key(let shown): shown.makeKeyAndOrderFront(nil)
                case .main(let shown): shown.makeMain()
                case nil: break
                }
            }
        }
    }

    private static var needsRepair: UsersWindowRule.Repair<NSWindow>? {
        let shown: (NSWindow?) -> (window: NSWindow, shown: NSWindow)? = { window in
            guard let window else { return nil }
            let front: NSWindow = window.shownWindow
            // Only to a tab on screen that can take it; a minimized group or one closing is left to AppKit.
            guard front === window || (front.isVisible && !front.isMiniaturized && front.canBecomeKey) else { return nil }
            return (window, front)
        }
        // A main window with a sheet of its own keeps it: the sheet is where its keyboard goes.
        let main: NSWindow? = NSApp.mainWindow.flatMap { $0.attachedSheet == nil ? $0 : nil }
        return UsersWindowRule.repair(key: shown(NSApp.keyWindow), main: shown(main), appActive: NSApp.isActive,
                                      modal: NSApp.modalWindow != nil)
    }
}

/// The View menu's items for macOS's tab bar, named for project tabs whichever window is in front: macOS names them
/// "Show Tab Bar" and "Show All Tabs" each time it checks them, and with Settings or a panel in front only it does.
final class ProjectTabMenuTitles: NSObject, NSMenuDelegate {
    static let shared = ProjectTabMenuTitles()

    func menuWillOpen(_ menu: NSMenu) {
        let group: NSWindowTabGroup? = NSApp.keyWindow?.tabGroup
        for item in menu.items {
            if item.action == #selector(NSWindow.toggleTabBar(_:)) {
                item.title = group?.isTabBarVisible == true ? "Hide Project Tab Bar" : "Show Project Tab Bar"
            } else if item.action == #selector(NSWindow.toggleTabOverview(_:)) {
                item.title = group?.isOverviewVisible == true ? "Exit Project Tab Overview" : "Show All Project Tabs"
            }
        }
    }
}
