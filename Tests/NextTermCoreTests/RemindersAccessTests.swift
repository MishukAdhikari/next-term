import Foundation
import Testing
@testable import NextTermCore

/// Reminders' decisions, apart from EventKit: what the permission allows, which list a task goes to, the alert's time
/// and whether Undo may remove the reminder.
@Suite struct RemindersAccessTests {
    typealias Access = RemindersAccess

    // MARK: the permission

    @Test func notDeterminedExplainsFirstThenAsksTheCallOfThatMacOS() {
        #expect(Access.step(status: .notDetermined, os: 14) == .explain(.fullAccess))
        #expect(Access.step(status: .notDetermined, os: 26) == .explain(.fullAccess))
        // macOS 13 has no full-access call: it asks the older way, never naming the newer one.
        #expect(Access.step(status: .notDetermined, os: 13) == .explain(.legacy))
    }

    @Test func fullAccessOrAuthorizedIsReady() {
        for os in [13, 14, 26] {
            #expect(Access.step(status: .fullAccess, os: os) == .ready)
            #expect(Access.step(status: .authorized, os: os) == .ready)
        }
    }

    @Test func deniedOrWriteOnlyPointsToPrivacySettings() {
        for os in [13, 14] {
            for status in [Access.Status.denied, .writeOnly] {
                #expect(Access.step(status: status, os: os) == .blocked(Access.deniedLine, settings: true))
            }
        }
        #expect(Access.deniedLine == "Next Term can’t reach Reminders. Turn it on in System Settings › Privacy & "
            + "Security › Reminders.")
        #expect(Access.privacySettings.absoluteString == "x-apple.systempreferences:com.apple.preference.security")
    }

    @Test func restrictedSaysTheAdministratorTurnedItOff() {
        for os in [13, 14] {
            #expect(Access.step(status: .restricted, os: os) == .blocked(Access.restrictedLine, settings: false))
        }
        #expect(Access.restrictedLine == "Reminders is turned off on this Mac by its administrator.")
    }

    @Test func theExplanationSaysWhatIsReadAndThatTabsShareIt() {
        let text = Access.explanation
        #expect(text.contains("only the names of your lists"))
        #expect(text.contains("the reminders it added, for Undo"))
        #expect(text.contains("commands running in its tabs share it"))
    }

    // MARK: the list

    let lists = [
        Access.List(id: "L1", title: "Home"),
        Access.List(id: "L2", title: "Next Term"),
        Access.List(id: "L3", title: "Next Term"),
    ]

    @Test func theSavedIdentifierWins() {
        #expect(Access.chooseList(listID: "L3", listName: "Next Term", in: lists) == .existing(id: "L3", saveID: false))
        // The id wins over a name that no longer matches: the user renamed the list in Reminders.
        #expect(Access.chooseList(listID: "L1", listName: "Next Term", in: lists) == .existing(id: "L1", saveID: false))
    }

    @Test func aGoneIdentifierFallsBackToTheFirstListOfThatNameAndSavesIt() {
        #expect(Access.chooseList(listID: "gone", listName: "Next Term", in: lists) == .existing(id: "L2", saveID: true))
        #expect(Access.chooseList(listID: nil, listName: "Next Term", in: lists) == .existing(id: "L2", saveID: true))
    }

    @Test func theNameMatchesExactly() {
        #expect(Access.chooseList(listID: nil, listName: "next term", in: lists) == .create(title: "next term"))
        #expect(Access.chooseList(listID: nil, listName: "Next Term ", in: lists) == .create(title: "Next Term "))
    }

    @Test func noMatchCreatesTheList() {
        #expect(Access.chooseList(listID: nil, listName: "Work", in: []) == .create(title: "Work"))
        #expect(Access.chooseList(listID: "gone", listName: "Work", in: lists) == .create(title: "Work"))
    }

    @Test func aListThatCantBeMadeSaysSoAndOffersTheDefault() {
        #expect(Access.couldntMake("Next Term") == "Couldn’t make the list “Next Term”.")
        #expect(Access.addToDefault("Home") == "Add to “Home” instead")
    }

    @Test func theFoundIdentifierIsKeptWithTheName() {
        let saved = Access.withList(.reminders(listID: nil, listName: "Next Term"), id: "L2")
        #expect(saved == .reminders(listID: "L2", listName: "Next Term"))
        let renamed = Access.withList(.reminders(listID: "gone", listName: "Work"), id: "L9")
        #expect(renamed == .reminders(listID: "L9", listName: "Work"))
        #expect(Access.withList(.todoFolder, id: "L2") == nil)
    }

    // MARK: the alert

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka") ?? .current
        return calendar
    }

    @Test func theAlertIsAtNineOnTheDayInLocalTime() throws {
        let due = DateComponents(year: 2026, month: 10, day: 19)
        let date = try #require(Access.alarm(due: due, enabled: true, calendar: calendar))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts == DateComponents(year: 2026, month: 10, day: 19, hour: 9, minute: 0))
    }

    @Test func noDayOrTheSwitchOffMeansNoAlert() {
        #expect(Access.alarm(due: nil, enabled: true, calendar: calendar) == nil)
        let due = DateComponents(year: 2026, month: 10, day: 19)
        #expect(Access.alarm(due: due, enabled: false, calendar: calendar) == nil)
    }

    // MARK: Undo

    let saved = Access.Saved(title: "Fix login", notes: "- [ ] write test", due: DateComponents(year: 2026, month: 10, day: 19))

    func now(title: String = "Fix login", notes: String? = "- [ ] write test",
             due: DateComponents? = DateComponents(year: 2026, month: 10, day: 19), completed: Bool = false) -> Access.Found {
        Access.Found(title: title, notes: notes, due: due, completed: completed)
    }

    @Test func anUnchangedReminderIsRemoved() {
        #expect(Access.undo(saved, now: now()) == .remove)
        // Reminders reads back the same day with its calendar and time zone filled in: still the same day.
        var filled = DateComponents(year: 2026, month: 10, day: 19)
        filled.calendar = calendar
        filled.timeZone = calendar.timeZone
        #expect(Access.undo(saved, now: now(due: filled)) == .remove)
        // Empty notes read back as none.
        let bare = Access.Saved(title: "Fix login", notes: "", due: nil)
        #expect(Access.undo(bare, now: now(notes: nil, due: nil)) == .remove)
    }

    @Test func anEditedOrCompletedReminderStays() {
        let line = Access.changedLine
        #expect(line == "You changed it in Reminders, so it stays.")
        #expect(Access.undo(saved, now: now(title: "Fix login now")) == .keep(line))
        #expect(Access.undo(saved, now: now(notes: "- [x] write test")) == .keep(line))
        #expect(Access.undo(saved, now: now(due: DateComponents(year: 2026, month: 10, day: 20))) == .keep(line))
        #expect(Access.undo(saved, now: now(due: nil)) == .keep(line))
        var timed = DateComponents(year: 2026, month: 10, day: 19)
        timed.hour = 14
        #expect(Access.undo(saved, now: now(due: timed)) == .keep(line))
        #expect(Access.undo(saved, now: now(completed: true)) == .keep(line))
    }

    @Test func aReminderAlreadyGoneLeavesNothingToRemove() {
        #expect(Access.undo(saved, now: nil) == .gone)
    }
}
