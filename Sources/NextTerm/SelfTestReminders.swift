import AppKit
import NextTermCore

/// Reminders with the in-memory store only, so no check reaches EventKit or the user's own reminders: the explanation
/// before macOS asks, the list found or made and its id saved back, one all-day reminder with its alert, the posted
/// record, Undo while unchanged and not after an edit, a refusal that saves nothing, Not Now, and the default list
/// offered when the list can't be made. Called from `tasksChecks`, which puts the Tasks settings back after.
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
        let first = await add(task, window)
        guard case .added(let id, let list) = first else {
            return check(false, "reminders: Add saves a reminder after the explanation", "\(first)")
        }
        check(RemindersSheets.shown == [RemindersAccess.explanation] && fake.asked == [.fullAccess],
              "reminders: Next Term explains first, then macOS is asked once for full access", "\(fake.asked)")
        let made = fake.allLists.first { $0.id == list }
        check(made?.title == "Next Term" && fake.allLists.count == 2, "reminders: the list “Next Term” is made on first Add")
        let item = fake.items[id]
        let due = DateComponents(year: tomorrow.year, month: tomorrow.month, day: tomorrow.day)
        check(item?.title == task.title && item?.notes == task.notes && item?.due == due,
              "reminders: one all-day reminder with the rendered title, notes and day", "\(String(describing: item))")
        let nine = RemindersAccess.alarm(due: due, enabled: true, calendar: .current)
        check(item?.alarm != nil && item?.alarm == nine, "reminders: the alert is at 9:00 on its day when the switch is on")
        let savedBack = TaskSettings(defaults: defaults).defaultDestination
        check(savedBack == .reminders(listID: list, listName: "Next Term"), "reminders: the made list’s id is saved back")
        check(GitToast.text == "Added to Reminders", "reminders: a notice says it was added, with Undo", GitToast.text ?? "")
        let recorded = await recordHolds(id)
        check(recorded, "reminders: the posted record holds the reminder’s id")

        await undoChecks(id: id, task: task, fake: fake, window: window)
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
        let removed = await wait(3) { fake.items[id] == nil }
        check(removed, "reminders: Undo removes the unchanged reminder")
        let forgotten = await !recordHolds(id)
        check(forgotten, "reminders: and the record forgets it")

        let second = await add(task, window)
        guard case .added(let next, _) = second else { return check(false, "reminders: a second Add saves", "\(second)") }
        check(fake.asked.count == 1 && fake.allLists.count == 2, "reminders: no second question and no second list")
        fake.items[next]?.title = task.title + " (edited)"
        TaskReminders.undo(next, saved: saved, in: window)
        let kept = await wait(3) { GitToast.text == RemindersAccess.changedLine }
        check(kept && fake.items[next] != nil, "reminders: an edited reminder stays after Undo, and the notice says so")
        fake.items[next]?.title = task.title
        fake.items[next]?.completed = true
        GitToast.dismiss()
        TaskReminders.undo(next, saved: saved, in: window)
        let done = await wait(3) { GitToast.text == RemindersAccess.changedLine }
        check(done && fake.items[next] != nil, "reminders: a completed reminder stays after Undo")
    }

    /// A refusal or Not Now saves nothing and records nothing; a list that can't be made offers the default one.
    private static func refusalChecks(task: TaskReminders.Task, fake: FakeRemindersStore, window: NSWindow?) async {
        let before = fake.items.count
        fake.currentStatus = .denied
        RemindersSheets.shown = []
        let denied = await add(task, window)
        check(denied == .failed(RemindersAccess.deniedLine) && fake.items.count == before
              && RemindersSheets.shown == [RemindersAccess.deniedLine],
              "reminders: denied saves nothing and shows where to turn it on", "\(denied)")

        fake.currentStatus = .notDetermined
        RemindersSheets.fakeAnswer = false
        let notNow = await add(task, window)
        check(notNow == .notNow && fake.items.count == before && fake.currentStatus == .notDetermined,
              "reminders: Not Now changes nothing and macOS isn’t asked")

        RemindersSheets.fakeAnswer = true
        fake.currentStatus = .fullAccess
        fake.canMakeLists = false
        RemindersSheets.shown = []
        let other = TaskDestination.reminders(listID: nil, listName: "Made Up List")
        let plain = TaskDraft(title: task.title, steps: [])
        guard let elsewhere = remindersTask(plain, other) else {
            return check(false, "reminders: a second list renders")
        }
        let fallback = await add(elsewhere, window)
        let offered = RemindersSheets.shown == [RemindersAccess.couldntMake("Made Up List")]
        var onHome = false
        if case .added(let id, let list) = fallback { onHome = list == "home" && fake.items[id]?.list == "home" }
        check(offered && onHome && !fake.allLists.contains { $0.title == "Made Up List" },
              "reminders: a list that can’t be made offers the default list, and Add goes there", "\(fallback)")
    }
}
