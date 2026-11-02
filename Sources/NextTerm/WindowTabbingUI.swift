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
}
