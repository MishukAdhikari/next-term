import NextTermCore
import Testing

@Suite struct WindowSeenTests {
    private func facts(occlusion: Bool = false, behind: Bool = false, selfTest: Bool = false, visible: Bool = true, mini: Bool = false,
                       ever: Bool = true, key: Bool = false, active: Bool = true) -> WindowSeen.Facts {
        WindowSeen.Facts(occlusionVisible: occlusion, backgroundTab: behind, selfTestRun: selfTest, visible: visible, miniaturized: mini,
                         everReportedVisible: ever, key: key, appActive: active)
    }

    /// The 0.11.81 report: a tab dragged out of a full-screen group, on screen, while its group still counts it behind
    /// another tab. It must keep drawing; judged by its tab it froze on its last picture.
    @Test func aTabOnScreenThatItsGroupCountsBehindIsSeen() {
        #expect(WindowSeen.seen(facts(occlusion: true, behind: true)))
        #expect(WindowSeen.seen(facts(occlusion: true, behind: true, selfTest: true)))
    }

    /// A tab really out of sight behind another: macOS never reports it visible, ordered in or not.
    @Test func aTabOutOfSightIsNotSeen() {
        #expect(!WindowSeen.seen(facts(occlusion: false, behind: true, visible: true, key: true)))
        #expect(!WindowSeen.seen(facts(occlusion: false, behind: true, selfTest: true, visible: true)))
        #expect(!WindowSeen.seen(facts(occlusion: false, behind: true, ever: false, key: true)))
    }

    @Test func occlusionDecidesForAWindowOnItsOwn() {
        #expect(WindowSeen.seen(facts(occlusion: true)))
        #expect(!WindowSeen.seen(facts(occlusion: false))) // covered, another Space, a locked screen
    }

    /// One that first came in behind a tab, never marked visible: seen while it has the keyboard in the app in front.
    @Test func aWindowNeverMarkedVisibleIsSeenWhileItHasTheKeyboard() {
        #expect(WindowSeen.seen(facts(ever: false, key: true, active: true)))
        #expect(!WindowSeen.seen(facts(ever: false, key: true, active: false)))
        #expect(!WindowSeen.seen(facts(ever: false, key: false)))
        #expect(!WindowSeen.seen(facts(ever: true, key: true))) // occlusion has spoken for it since
        #expect(!WindowSeen.seen(facts(mini: true, ever: false, key: true)))
    }

    @Test func aSelfTestRunCountsAnyWindowOnScreen() {
        #expect(WindowSeen.seen(facts(occlusion: false, selfTest: true, visible: true)))
        #expect(!WindowSeen.seen(facts(occlusion: false, selfTest: true, visible: true, mini: true)))
        #expect(!WindowSeen.seen(facts(occlusion: false, selfTest: true, visible: false)))
    }
}
