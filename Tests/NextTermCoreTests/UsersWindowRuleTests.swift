import NextTermCore
import Testing

/// The window the user is in while project windows merge as tabs: the tab in front, never one behind it, keyboard or not.
/// "A" and "B" are tabs of one window, B in front; "S" is a window of its own (Settings), "P" a panel.
@Suite struct UsersWindowRuleTests {
    /// Keyboard and tab in front agree, as almost always: the key window is the user's, as before.
    @Test func theKeyTabInFrontIsTheUsers() {
        #expect(UsersWindowRule.isUsers("B", shown: "B", keyShown: "B", mainShown: "B"))
        #expect(!UsersWindowRule.isUsers("A", shown: "B", keyShown: "B", mainShown: "B"))
        #expect(UsersWindowRule.isUsers("S", shown: "S", keyShown: "S", mainShown: "S"))
    }

    /// The live report: the keyboard left in A, behind B. B is what the user sees, so B is theirs and A is not.
    @Test func aKeyTabBehindAnotherIsNotTheUsersAndTheTabInFrontIs() {
        #expect(!UsersWindowRule.isUsers("A", shown: "B", keyShown: "B", mainShown: "B"))
        #expect(UsersWindowRule.isUsers("B", shown: "B", keyShown: "B", mainShown: "B"))
    }

    /// A panel (Go to Anything, an approval) has the keyboard: the main window, as shown, is the user's.
    @Test func underAPanelTheMainWindowAsShownIsTheUsers() {
        #expect(UsersWindowRule.isUsers("B", shown: "B", keyShown: "P", mainShown: "B"))
        #expect(!UsersWindowRule.isUsers("A", shown: "B", keyShown: "P", mainShown: "B"))
        #expect(!UsersWindowRule.isUsers("S", shown: "S", keyShown: "P", mainShown: "B"))
        #expect(!UsersWindowRule.isUsers("B", shown: "B", keyShown: nil, mainShown: nil))
    }

    /// The keyboard goes to a tab in front or a window of its own; never to a tab behind (it would come to the front).
    @Test func theKeyboardGoesOnlyToATabInFront() {
        #expect(UsersWindowRule.mayTakeKeyboard("B", shown: "B"))
        #expect(UsersWindowRule.mayTakeKeyboard("S", shown: "S"))
        #expect(!UsersWindowRule.mayTakeKeyboard("A", shown: "B"))
    }

    /// Agreeing, nothing is repaired: no visible change in the normal case.
    @Test func nothingIsRepairedWhileKeyboardAndTabAgree() {
        #expect(UsersWindowRule.repair(key: ("B", "B"), main: ("B", "B"), appActive: true, modal: false) == nil)
        #expect(UsersWindowRule.repair(key: ("S", "S"), main: ("S", "S"), appActive: true, modal: false) == nil)
        #expect(UsersWindowRule.repair(key: ("P", "P"), main: ("B", "B"), appActive: true, modal: false) == nil)
        let none: (window: String, shown: String)? = nil
        #expect(UsersWindowRule.repair(key: none, main: none, appActive: true, modal: false) == nil)
    }

    /// The keyboard in a tab behind another goes to the tab in front.
    @Test func aKeyTabBehindGivesTheKeyboardToTheTabInFront() {
        #expect(UsersWindowRule.repair(key: ("A", "B"), main: ("A", "B"), appActive: true, modal: false) == .key("B"))
    }

    /// A panel key over a main tab left behind (the user switched tabs from the panel): the tab in front becomes main, so
    /// the panel's close hands the keyboard to it, not back to the tab left.
    @Test func aMainTabBehindUnderAPanelGivesWayToTheTabInFront() {
        #expect(UsersWindowRule.repair(key: ("P", "P"), main: ("A", "B"), appActive: true, modal: false) == .main("B"))
    }

    /// Never while another app is in front, nor over a modal alert.
    @Test func nothingIsRepairedInTheBackgroundOrOverAModal() {
        #expect(UsersWindowRule.repair(key: ("A", "B"), main: ("A", "B"), appActive: false, modal: false) == nil)
        #expect(UsersWindowRule.repair(key: ("A", "B"), main: ("A", "B"), appActive: true, modal: true) == nil)
    }
}
