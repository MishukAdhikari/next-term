import AppKit
import NextTermCore
import ObjectiveC

nonisolated(unsafe) private var everVisibleKey: UInt8 = 0

extension NSWindow {
    /// Whether anyone can see the window: not when it is minimized, the app hidden, the window covered by
    /// others, on another Space or a tab behind another, or the screen locked or asleep. In a self-test run, whether
    /// it is on screen at all: the run takes half an hour, and a check must not fail because the Mac locked meanwhile.
    /// The sidebar's git refresh (GitMonitor) and the terminals' drawing (NextTermView) go by it; WindowSeen decides.
    var canBeSeen: Bool {
        let occluded: Bool = !occlusionState.contains(.visible)
        if !occluded { everReportedVisible = true }
        return WindowSeen.seen(WindowSeen.Facts(
            occlusionVisible: !occluded, backgroundTab: isBackgroundTab, selfTestRun: Self.selfTestRun, visible: isVisible,
            miniaturized: isMiniaturized, everReportedVisible: everReportedVisible,
            key: isKeyWindow, appActive: NSApp.isActive))
    }

    /// Posted for a window merged with others when its tab came to the front or went behind one (TerminalWindowController
    /// watches its group): macOS posts no occlusion change for it while the screen is locked or the window covered.
    static let tabSelectionDidChange = Notification.Name("NextTerm.windowTabSelectionDidChange")

    /// Whether macOS has ever reported the window visible.
    private var everReportedVisible: Bool {
        get { objc_getAssociatedObject(self, &everVisibleKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &everVisibleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Read once: each terminal asks at every change it draws.
    private static let selfTestRun = SelfTest.isRequested

    /// What changes `canBeSeen`, to observe for a window: occlusion covers most; minimizing and hiding are observed too,
    /// for a self-test run, and the keyboard and the app's activity for a window macOS never marked visible.
    static let visibilityNotifications: [(name: Notification.Name, ofApp: Bool)] = [
        (NSWindow.didChangeOcclusionStateNotification, false), (NSWindow.didMiniaturizeNotification, false),
        (NSWindow.didDeminiaturizeNotification, false), (NSApplication.didHideNotification, true),
        (NSApplication.didUnhideNotification, true), (tabSelectionDidChange, false),
        // The keyboard and the app's being in front decide for a window macOS never marked visible.
        (NSWindow.didBecomeKeyNotification, false), (NSWindow.didResignKeyNotification, false),
        (NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, true),
    ]
}
