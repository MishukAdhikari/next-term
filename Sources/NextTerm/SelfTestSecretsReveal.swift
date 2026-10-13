import AppKit
import NextTermCore

#if DEBUG
/// Reveal's end (review finding 8): a revealed key goes with its window, whichever window holds the list, and a Touch
/// ID still up when the list goes is cancelled, or, given after it went, shows nothing. On a Settings window of the
/// self-test's own and on Window › Secrets, with the stand-in presence check held as a sheet left up would be.
extension SelfTest {
    static func secretsRevealEndChecks(presence: StandInPresence, shownValue: String) async {
        let settings = SettingsWindowController()
        let tabs = settings.window?.contentView as? NSTabView
        let item = tabs?.tabViewItems.first { $0.identifier as? String == "secrets" }
        guard let window = settings.window, let view = item?.view as? SecretsView else {
            return check(false, "secrets: Settings › Secrets holds the list of keys")
        }
        defer {
            presence.holds = false
            presence.endsOnCancel = true
            presence.release(approving: false)
            window.close()
        }
        func open() async -> Bool {
            settings.showTab("secrets")
            settings.showWindow(nil)
            return await wait(5) { window.isVisible && view.window === window }
        }
        func reveals() -> Int { secretsAudit(SecretsStore.shared).filter { $0.event == .reveal }.count }
        /// Reveal, held at the stand-in's sheet; true once the sheet is up.
        func askToReveal(endsOnCancel: Bool) async -> Bool {
            presence.holds = true
            presence.endsOnCancel = endsOnCancel
            view.select("SHOWN_KEY")
            view.revealButton.performClick(nil)
            return await wait(5) { presence.isHolding }
        }
        /// Approves the held sheet, then waits for the reveal the approval let through to finish.
        func approveLate(after before: Int) async -> Bool {
            presence.release(approving: true)
            presence.holds = false
            return await wait(10) { reveals() > before }
        }

        // Shown, then Settings closes with ⌘W: the value goes, and opening Settings again brings none back.
        let opened = await open()
        view.select("SHOWN_KEY")
        view.revealButton.performClick(nil)
        let shown = await wait(10) { view.revealField?.stringValue == shownValue }
        let field = view.revealField
        let popover = view.revealPopover
        window.performClose(nil)
        let gone = await wait(5) { view.revealField == nil && view.revealPopover == nil }
        check(opened && shown && gone && field?.stringValue == "" && popover?.isShown != true,
              "secrets: a key revealed in Settings › Secrets is hidden and wiped when Settings closes")
        let reopened = await open()
        check(reopened && view.revealField == nil && popover?.isShown != true,
              "secrets: opening Settings again after it closed with a key revealed shows no value, with no new Touch ID")

        // Settings closes while Touch ID is up: the sheet is cancelled, and nothing is revealed.
        var before = reveals()
        let asked = await askToReveal(endsOnCancel: true)
        let cancelled = presence.cancelledHolds
        window.performClose(nil)
        let ended = await wait(5) { !presence.isHolding && presence.cancelledHolds == cancelled + 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(asked && ended && view.revealField == nil && reveals() == before,
              "secrets: closing Settings while Touch ID is up for Reveal cancels it, and no key is revealed")

        // Touch ID approved after Settings closed: the value isn't shown, now or when Settings opens again.
        _ = await open()
        before = reveals()
        let askedLate = await askToReveal(endsOnCancel: false)
        window.performClose(nil)
        let approved = await approveLate(after: before)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let hiddenWhileClosed = view.revealField == nil && view.revealPopover == nil
        _ = await open()
        check(askedLate && approved && hiddenWhileClosed && view.revealField == nil && view.revealPopover == nil,
              "secrets: a Touch ID approved after Settings closed reveals nothing, then or when Settings opens again")

        await secretsRevealTabChecks(settings, view: view, presence: presence, shownValue: shownValue)
        window.close()
        await secretsRevealWindowChecks(presence: presence, reveals: reveals)
    }

    /// The Secrets tab loses its view when another Settings tab is chosen: a value shown goes, and a Touch ID approved
    /// after the switch shows nothing when the tab comes back.
    static func secretsRevealTabChecks(_ settings: SettingsWindowController, view: SecretsView, presence: StandInPresence,
                                       shownValue: String) async {
        func reveals() -> Int { secretsAudit(SecretsStore.shared).filter { $0.event == .reveal }.count }
        settings.showTab("secrets")
        _ = await wait(5) { view.window != nil }
        view.select("SHOWN_KEY")
        view.revealButton.performClick(nil)
        let shown = await wait(10) { view.revealField?.stringValue == shownValue }
        let popover = view.revealPopover
        settings.showTab("notifications")
        let gone = view.window == nil && view.revealField == nil && popover?.isShown != true
        settings.showTab("secrets")
        check(shown && gone && view.revealField == nil, "secrets: choosing another Settings tab hides and wipes a revealed key")

        // Touch ID up, then another tab: the asking ends, and a late approval shows nothing.
        let before = reveals()
        presence.holds = true
        presence.endsOnCancel = false
        view.select("SHOWN_KEY")
        view.revealButton.performClick(nil)
        let asked = await wait(5) { presence.isHolding }
        settings.showTab("notifications")
        presence.release(approving: true)
        presence.holds = false
        let approved = await wait(10) { reveals() > before }
        try? await Task.sleep(nanoseconds: 300_000_000)
        settings.showTab("secrets")
        _ = await wait(5) { view.window != nil }
        check(asked && approved && view.revealField == nil && view.revealPopover == nil,
              "secrets: a Touch ID approved after Settings › Secrets was left reveals nothing when the tab comes back")
    }

    /// Window › Secrets closes while Touch ID is up for Reveal: an approval after it closed shows nothing, then or when
    /// the window opens again. The window is left open, as the Settings checks had it.
    static func secretsRevealWindowChecks(presence: StandInPresence, reveals: () -> Int) async {
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible else {
            return check(false, "secrets: Window › Secrets opens again")
        }
        let view = controller.secretsView
        let before = reveals()
        presence.holds = true
        presence.endsOnCancel = false
        defer {
            presence.holds = false
            presence.endsOnCancel = true
        }
        view.select("SHOWN_KEY")
        view.revealButton.performClick(nil)
        let asked = await wait(5) { presence.isHolding }
        window.performClose(nil)
        presence.release(approving: true)
        let approved = await wait(10) { reveals() > before }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let hidden = view.revealField == nil && view.revealPopover == nil
        AppDelegate.shared.showSecrets(nil)
        _ = await wait(5) { window.isVisible }
        check(asked && approved && hidden && view.revealField == nil && view.revealPopover == nil,
              "secrets: a Touch ID approved after Window › Secrets closed reveals nothing, then or when it opens again")
    }
}
#endif
