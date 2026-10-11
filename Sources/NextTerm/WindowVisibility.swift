import AppKit

extension NSWindow {
    /// Whether anyone can see the window: not when it is minimized, the app hidden, the window covered by
    /// others or on another Space, or the screen locked or asleep. In a self-test run, whether it is on
    /// screen at all: the run takes half an hour, and a check must not fail because the Mac locked meanwhile.
    /// The sidebar's git refresh (GitMonitor) and the terminals' drawing (NextTermView) go by it.
    var canBeSeen: Bool {
        if Self.selfTestRun { return isVisible && !isMiniaturized }
        return occlusionState.contains(.visible)
    }

    /// Read once: each terminal asks at every change it draws.
    private static let selfTestRun = SelfTest.isRequested

    /// What changes `canBeSeen`, to observe for a window: occlusion covers them all; minimizing and hiding are
    /// observed too, for a self-test run.
    static let visibilityNotifications: [(name: Notification.Name, ofApp: Bool)] = [
        (NSWindow.didChangeOcclusionStateNotification, false), (NSWindow.didMiniaturizeNotification, false),
        (NSWindow.didDeminiaturizeNotification, false), (NSApplication.didHideNotification, true),
        (NSApplication.didUnhideNotification, true),
    ]
}
