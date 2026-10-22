import AppKit
import NextTermCore

#if DEBUG
/// Reminders with the in-memory store only, so no check reaches EventKit or the user's own reminders: the explanation
/// before macOS asks, the list found or made and its id saved back, one all-day reminder with its alert, the posted
/// record, Undo while unchanged and not after an edit, a refusal that saves nothing, Not Now, and the default list
/// offered when the list can't be made. The fake store is read and changed only through `TaskReminders.quiet`, so no
/// check races a step still running on the store's queue. Called from `tasksChecks`, which puts the Tasks settings
/// back after.
extension SelfTest {
    static func remindersChecks(_ c: TerminalWindowController) async {
        let fake = FakeRemindersStore(status: .notDetermined, lists: [RemindersAccess.List(id: "home", title: "Home")])
        TaskReminders.fake = fake
        TaskReminders.fakeOS = 14
        RemindersSheets.fakeAnswer = true
        RemindersSheets.shown = []
        defer {
            TaskReminders.fake = nil
            TaskReminders.fakeOS = nil
            RemindersSheets.fakeAnswer = nil
            RemindersSheets.shown = []
            GitToast.dismiss()
        }
        let defaults = UserDefaults.standard
        let destination = TaskDestination.reminders(listID: nil, listName: "Next Term")
        defaults.set(TaskDestination.json(destination), forKey: TaskSettings.Key.defaultDestination)
        defaults.set(true, forKey: TaskSettings.Key.remindersAlarm)
        let window = c.window

        let tomorrow = TaskDay(Date().addingTimeInterval(86_400), calendar: .current)
        let draft = TaskDraft(title: "Check the reminder path", steps: [.init(text: "read the list")],
                              notes: "Made up for the self-test.", scheduled: .day(tomorrow))
        guard let task = remindersTask(draft, destination) else {
            return check(false, "reminders: a draft renders as a reminder")
        }
        let unasked = await makesList(destination)
        check(unasked == nil && fake.asked.isEmpty, "reminders: nothing is read before access is given")
        let first = await add(task, window)
        guard case .added(let id, let list) = first else {
            return check(false, "reminders: Add saves a reminder after the explanation", "\(first)")
        }
        let (asked, refreshed) = TaskReminders.quiet { (fake.asked, fake.refreshed) }
        let (allLists, item) = TaskReminders.quiet { (fake.allLists, fake.items[id]) }
        check(RemindersSheets.shown == [RemindersAccess.explanation] && asked == [.fullAccess],
              "reminders: Next Term explains first, then macOS is asked once for full access", "\(asked)")
        check(refreshed == 1, "reminders: the store starts afresh once access is given, before it reads a list")
        let made = allLists.first { $0.id == list }
        check(made?.title == "Next Term" && allLists.count == 2, "reminders: the list “Next Term” is made on first Add")
        let due = DateComponents(year: tomorrow.year, month: tomorrow.month, day: tomorrow.day)
        check(item?.title == task.title && item?.notes == task.notes && item?.due == due,
              "reminders: one all-day reminder with the rendered title, notes and day", "\(String(describing: item))")
        let nine = RemindersAccess.alarm(due: due, enabled: true, calendar: .current)
        check(item?.alarm != nil && item?.alarm == nine, "reminders: the alert is at 9:00 on its day when the switch is on")
        let savedBack = TaskSettings(defaults: defaults).defaultDestination
        check(savedBack == .reminders(listID: list, listName: "Next Term"), "reminders: the made list’s id is saved back")
        check(GitToast.text == "Added to Reminders", "reminders: a notice says it was added, with Undo", GitToast.text ?? "")
        let named = await makesList(destination)
        let missing = await makesList(.reminders(listID: nil, listName: "Made Up List"))
        check(named == false && missing == true, "reminders: the sheet can tell a list found from one Add would make")
        let recorded = await recordHolds(id)
        check(recorded, "reminders: the posted record holds the reminder’s id")

        await undoChecks(id: id, task: task, fake: fake, window: window)
        await failureChecks(task: task, fake: fake, window: window)
        await refusalChecks(task: task, fake: fake, window: window)
    }

    /// The task as the sheet would send it.
    private static func remindersTask(_ draft: TaskDraft, _ destination: TaskDestination) -> TaskReminders.Task? {
        let today = TaskDay(Date(), calendar: .current)
        let payload = TaskPayload.render(draft, to: destination, project: nil, today: today)
        return payload.flatMap { TaskReminders.Task($0, to: destination, project: nil) }
    }

    private static func add(_ task: TaskReminders.Task, _ window: NSWindow?) async -> TaskReminders.Outcome {
        await withCheckedContinuation { continuation in
            TaskReminders.add(task, from: window) { continuation.resume(returning: $0) }
        }
    }

    private static func lists() async -> [RemindersAccess.List] {
        await withCheckedContinuation { continuation in
            TaskReminders.lists { continuation.resume(returning: $0) }
        }
    }

    private static func makesList(_ destination: TaskDestination) async -> Bool? {
        await withCheckedContinuation { continuation in
            TaskReminders.makesList(destination) { continuation.resume(returning: $0) }
        }
    }

    /// Whether today's record holds `id`, read off the main thread as the record asks.
    private static func recordHolds(_ id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let entries = TaskRecordStore.shared.today(project: nil)
                continuation.resume(returning: entries.contains { $0.itemID == id && $0.kind == .reminders })
            }
        }
    }
}

extension SelfTest {
    /// Undo removes an unchanged reminder and forgets it; an edited one stays, with the line that says so.
    private static func undoChecks(id: String, task: TaskReminders.Task, fake: FakeRemindersStore,
                                   window: NSWindow?) async {
        let saved = RemindersAccess.Saved(title: task.title, notes: task.notes, due: task.due)
        TaskReminders.undo(id, saved: saved, in: window)
        let removed = await wait(3) { TaskReminders.quiet { fake.items[id] == nil } }
        check(removed, "reminders: Undo removes the unchanged reminder")
        let forgotten = await !recordHolds(id)
        check(forgotten, "reminders: and the record forgets it")

        let second = await add(task, window)
        guard case .added(let next, _) = second else { return check(false, "reminders: a second Add saves", "\(second)") }
        let once = TaskReminders.quiet { fake.asked.count == 1 && fake.allLists.count == 2 }
        check(once, "reminders: no second question and no second list")
        TaskReminders.quiet { fake.items[next]?.title = task.title + " (edited)" }
        TaskReminders.undo(next, saved: saved, in: window)
        let kept = await wait(3) { GitToast.text == RemindersAccess.changedLine }
        let stays = TaskReminders.quiet { fake.items[next] != nil }
        check(kept && stays, "reminders: an edited reminder stays after Undo, and the notice says so")
        TaskReminders.quiet {
            fake.items[next]?.title = task.title
            fake.items[next]?.completed = true
        }
        GitToast.dismiss()
        TaskReminders.undo(next, saved: saved, in: window)
        let done = await wait(3) { GitToast.text == RemindersAccess.changedLine }
        let still = TaskReminders.quiet { fake.items[next] != nil }
        check(done && still, "reminders: a completed reminder stays after Undo")
    }

    /// A refusal or Not Now saves nothing and records nothing; a list that can't be made offers the default one.
    private static func refusalChecks(task: TaskReminders.Task, fake: FakeRemindersStore, window: NSWindow?) async {
        let (before, readsBefore) = TaskReminders.quiet {
            fake.currentStatus = .denied
            return (fake.items.count, fake.reads)
        }
        let deniedMakes = await makesList(.reminders(listID: nil, listName: "Made Up List"))
        let deniedLists = await lists()
        let unread = TaskReminders.quiet { fake.reads == readsBefore }
        check(deniedMakes == nil && deniedLists.isEmpty && unread, "reminders: nothing is read while access is denied")
        RemindersSheets.shown = []
        let denied = await add(task, window)
        let deniedCount = TaskReminders.quiet { fake.items.count }
        check(denied == .failed(RemindersAccess.deniedLine) && deniedCount == before
              && RemindersSheets.shown == [RemindersAccess.deniedLine],
              "reminders: denied saves nothing and shows where to turn it on", "\(denied)")

        TaskReminders.quiet { fake.currentStatus = .notDetermined }
        RemindersSheets.fakeAnswer = false
        let notNow = await add(task, window)
        let unchanged = TaskReminders.quiet { fake.items.count == before && fake.currentStatus == .notDetermined }
        check(notNow == .notNow && unchanged, "reminders: Not Now changes nothing and macOS isn’t asked")

        RemindersSheets.fakeAnswer = true
        TaskReminders.quiet {
            fake.currentStatus = .fullAccess
            fake.canMakeLists = false
        }
        RemindersSheets.shown = []
        let other = TaskDestination.reminders(listID: nil, listName: "Made Up List")
        let plain = TaskDraft(title: task.title, steps: [])
        guard let elsewhere = remindersTask(plain, other) else {
            return check(false, "reminders: a second list renders")
        }
        let fallback = await add(elsewhere, window)
        let offered = RemindersSheets.shown == [RemindersAccess.couldntMake("Made Up List")]
        let (onHome, notMade) = TaskReminders.quiet {
            var home = false
            if case .added(let id, let list) = fallback { home = list == "home" && fake.items[id]?.list == "home" }
            return (home, !fake.allLists.contains { $0.title == "Made Up List" })
        }
        check(offered && onHome && notMade,
              "reminders: a list that can’t be made offers the default list, and Add goes there", "\(fallback)")
    }
}

extension SelfTest {
    /// A save that fails after the list was found saves and records nothing; a removal that fails says so and keeps
    /// the reminder; Undo of a reminder already deleted in Reminders forgets it quietly.
    private static func failureChecks(task: TaskReminders.Task, fake: FakeRemindersStore, window: NSWindow?) async {
        let before = TaskReminders.quiet {
            fake.canAdd = false
            return fake.items.count
        }
        let failed = await add(task, window)
        let none = TaskReminders.quiet {
            fake.canAdd = true
            return fake.items.count == before
        }
        check(failed == .failed(TaskReminders.couldntAdd) && none,
              "reminders: a save that fails after the list was found adds nothing and says so", "\(failed)")

        let added = await add(task, window)
        guard case .added(let id, _) = added else { return check(false, "reminders: Add saves again", "\(added)") }
        let saved = RemindersAccess.Saved(title: task.title, notes: task.notes, due: task.due)
        TaskReminders.quiet { fake.canRemove = false }
        GitToast.dismiss()
        TaskReminders.undo(id, saved: saved, in: window)
        let said = await wait(3) { GitToast.text == TaskReminders.couldntRemove }
        let kept = TaskReminders.quiet {
            fake.canRemove = true
            return fake.items[id] != nil
        }
        let recorded = await recordHolds(id)
        check(said && kept && recorded, "reminders: a removal that fails says so, and the reminder and its line stay")

        TaskReminders.quiet { fake.items[id] = nil }
        GitToast.dismiss()
        TaskReminders.undo(id, saved: saved, in: window)
        // The queue is idle once Undo's step there is done, record line and all.
        TaskReminders.quiet {}
        let forgotten = await !recordHolds(id)
        check(forgotten && GitToast.text == nil, "reminders: Undo of a reminder already deleted forgets it, with no notice")
    }
}
#endif
