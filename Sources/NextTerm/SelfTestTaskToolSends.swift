import AppKit
import NextTermCore

#if DEBUG
/// add_task to a shortcut, to Reminders once allowed, from a remote connection that skips asking, and with a saved value
/// that fails its check. The shortcut runner and the Reminders store are fakes: no command starts and the user's
/// Reminders are never read. Called from `addTaskDestinationChecks`, which puts the Tasks settings back after.
extension SelfTest {
    static let toolShortcutID = "8F1C2D3E-0000-4000-8000-000000000001"

    static func addTaskSendChecks(_ client: TaskClient, proj: URL, key: String) async {
        await toolShortcutChecks(client, proj: proj, key: key)
        await toolRemindersChecks(client, proj: proj, key: key)
        await toolGrantChecks(proj: proj, key: key)
        toolBrokenChecks(proj: proj, key: key)
        TasksMenu.save(nil, key: key)
    }

    /// A shortcut still listed runs once, only after Approve, with the text the window showed; one no longer listed is
    /// refused with no window and nothing runs.
    private static func toolShortcutChecks(_ client: TaskClient, proj: URL, key: String) async {
        let fake = FakeShortcutRunner(list: "Inbox (\(toolShortcutID))\n")
        TaskShortcut.fake = fake
        TaskShortcut.fakeLimit = 0.5
        defer {
            TaskShortcut.fake = nil
            TaskShortcut.fakeLimit = nil
        }
        TasksMenu.save(.shortcut(id: toolShortcutID, name: "Inbox"), key: key)
        let before = postedToday()
        var runsBefore = -1
        let ran = await client.asked(["title": "Run the tool shortcut", "project": proj.path], approve: true) {
            runsBefore = fake.runs.count
        }
        let runs = fake.runs
        let input = runs.first.map { String(decoding: $0.input, as: UTF8.self) } ?? "(none)"
        let shownInput = ran.shown.contains(input.trimmingCharacters(in: .newlines))
        check(!ran.isError && taskJSON(ran.text)["destination"] as? String == "shortcut" && runsBefore == 0 && runs.count == 1,
              "add_task destinations: a listed shortcut runs once, only after Approve", ran.text)
        check(ran.shown.contains("To: Run “Inbox”: runs the shortcut “Inbox”") && shownInput,
              "add_task destinations: the shortcut gets exactly the text the window showed", ran.shown + "\n--\n" + input)
        check(await wait(3) { postedToday() == before + 1 }, "add_task destinations: the shortcut's run is in the posted record")

        fake.answer(list: "Plan (9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A)\n")
        let gone = await client.call(["title": "Run a gone shortcut", "project": proj.path])
        check(gone.isError && gone.text.hasPrefix("The shortcut is gone;") && MCPWriteControl.pending == nil
                && fake.runs.count == 1,
              "add_task destinations: a shortcut no longer listed is refused with no window, and nothing runs", gone.text)
    }

    /// Reminders allowed: the window says the list is new, Approve adds one reminder to it, the answer names the list,
    /// the record has one line, and Undo removes it. A list id saved meanwhile is no change.
    private static func toolRemindersChecks(_ client: TaskClient, proj: URL, key: String) async {
        let store = FakeRemindersStore(status: .fullAccess, lists: [])
        TaskReminders.fake = store
        TaskReminders.fakeOS = 14
        let name = "Tool Check List"
        TasksMenu.save(.reminders(listID: nil, listName: name), key: key)
        let before = postedToday()
        let added = await client.asked(["title": "Remind from the tool", "project": proj.path], approve: true)
        let answer = taskJSON(added.text)
        let items = TaskReminders.quiet { store.items }
        check(!added.isError && answer["destination"] as? String == "reminders" && answer["list"] as? String == name
                && items.count == 1,
              "add_task destinations: Reminders, once allowed, gets one reminder and the answer names its list", added.text)
        check(added.shown.contains("new list “\(name)”"), "add_task destinations: the window says the list is new", added.shown)
        check(await wait(3) { postedToday() == before + 1 }, "add_task destinations: the reminder is in the posted record")
        check(GitToast.text == "Added to Reminders", "add_task destinations: the reminder is offered with Undo", GitToast.text ?? "")
        if let first = items.first {
            let item = first.value
            let saved = RemindersAccess.Saved(title: item.title, notes: item.notes, due: item.due)
            TaskReminders.undo(first.key, saved: saved, in: nil)
            check(await wait(3) { TaskReminders.quiet { store.items.isEmpty } }, "add_task destinations: Undo removes the reminder")
        }
        GitToast.dismiss()

        // The sheet's Add saves the list's id while the window waits: the user changed nothing, so it is added.
        let listID = TaskReminders.quiet { store.allLists.first { $0.title == name }?.id } ?? "none"
        TasksMenu.save(.reminders(listID: nil, listName: name), key: key)
        let kept = await client.asked(["title": "Remind once more", "project": proj.path], approve: true) {
            TasksMenu.save(.reminders(listID: listID, listName: name), key: key)
        }
        check(!kept.isError && TaskReminders.quiet { store.items.count } == 1,
              "add_task destinations: a list id saved while the window waits is no change", kept.text)
        GitToast.dismiss()
    }

    /// A remote connection whose “Ask on this Mac before changes” is off still sees the window for a task that leaves
    /// Next Term, and nothing opens before Approve.
    private static func toolGrantChecks(proj: URL, key: String) async {
        TasksMenu.save(.github(owner: "example-org", repo: "web"), key: key)
        TaskOpen.opened = []
        var result: MCPServer.CallResult?
        TasksMCP.addTask(["title": "From the remote door", "project": proj.path], caller: nil,
                         approval: .preApprovedByGrant("selftest-grant"), requester: "the connection “Self-test”",
                         connection: "selftest-grant") { result = $0 }
        let asked = await wait(10) { MCPWriteControl.pending?.window != nil }
        check(asked && result == nil && TaskOpen.opened.isEmpty,
              "add_task destinations: a remote grant still shows the window for a page", result?.text ?? "")
        MCPWriteControl.pending?.window?.declineButton.performClick(nil)
        let declined = await wait(5) { result != nil }
        check(declined && result?.isError == true && TaskOpen.opened.isEmpty,
              "add_task destinations: declining it opens nothing", result?.text ?? "")
    }

    /// A saved value that fails its check is refused with no window, never read as another place.
    private static func toolBrokenChecks(proj: URL, key: String) {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: TaskSettings.Key.projects)
        let good = TaskSettings.json(saved: saved, setting: .shortcut(id: toolShortcutID, name: "Inbox"), for: key) ?? ""
        defaults.set(good.replacingOccurrences(of: toolShortcutID, with: "not-an-identifier"), forKey: TaskSettings.Key.projects)
        var result: MCPServer.CallResult?
        TasksMCP.addTask(["title": "Into a broken place", "project": proj.path], caller: nil, approval: .askOnMac,
                         requester: nil, connection: nil) { result = $0 }
        let text = result?.text ?? "(no answer yet)"
        check(result?.isError == true && text.hasPrefix("The shortcut needs its identifier and name;")
                && MCPWriteControl.pending == nil,
              "add_task destinations: a saved value that fails its check is refused with no window", text)
    }
}
#endif
