/// Whether a window's contents can be seen, from what AppKit says of it: NSWindow.canBeSeen asks this, and the terminals'
/// drawing and the sidebar's git refresh go by its answer.
public enum WindowSeen {
    public struct Facts: Equatable, Sendable {
        /// macOS reports the window visible (its occlusion state).
        public var occlusionVisible: Bool
        /// Merged with other windows and not the tab in front, as its tab group has it.
        public var backgroundTab: Bool
        /// A self-test run: on screen at all is enough, so a Mac that locks meanwhile fails no check.
        public var selfTestRun: Bool
        public var visible: Bool
        public var miniaturized: Bool
        /// macOS has reported the window visible at least once.
        public var everReportedVisible: Bool
        public var key: Bool
        public var appActive: Bool

        public init(occlusionVisible: Bool, backgroundTab: Bool, selfTestRun: Bool = false, visible: Bool, miniaturized: Bool = false,
                    everReportedVisible: Bool, key: Bool, appActive: Bool) {
            self.occlusionVisible = occlusionVisible
            self.backgroundTab = backgroundTab
            self.selfTestRun = selfTestRun
            self.visible = visible
            self.miniaturized = miniaturized
            self.everReportedVisible = everReportedVisible
            self.key = key
            self.appActive = appActive
        }
    }

    public static func seen(_ facts: Facts) -> Bool {
        // On screen, whatever its tab group says. A tab dragged out of a full-screen group can stay on screen while its
        // group still counts it behind another tab (seen in 0.11.81); judged by its tab, it drew nothing new, its picture
        // frozen. A tab really out of sight is never reported visible (probed on macOS 26.5, ordered in or not).
        if facts.occlusionVisible { return true }
        if facts.backgroundTab { return false }
        if facts.selfTestRun { return facts.visible && !facts.miniaturized }
        // A window macOS has never marked visible (one that first came in behind a tab, as a merged window brought back by
        // an update's restore) is seen while it has the keyboard; its terminals otherwise drew nothing at all. Once
        // occlusion has spoken for it, it alone decides, so a locked screen, a sleeping display or another Space stop the
        // drawing as before.
        return !facts.everReportedVisible && facts.key && facts.visible && !facts.miniaturized && facts.appActive
    }
}
