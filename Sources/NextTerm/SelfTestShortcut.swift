import AppKit
import NextTermCore

#if DEBUG
/// Run a Shortcut with the fake runner only, so no command starts and none of the user's shortcuts runs: the list
/// parsed into the picker's names, the input byte-equal to the rendered text and the shortcut named by its id, one
/// posted-record line keyed by that id, a failed run and a run out of time that record nothing and quote nothing, Cancel,
/// and a shortcut no longer listed. Called from `tasksChecks`, which puts the Tasks settings back after.
extension SelfTest {
    static func shortcutChecks() async {
        let inbox = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
        let gone = "11111111-2222-4333-8444-555555555555"
        let fake = FakeShortcutRunner(list: "Add to Inbox (\(inbox))\nPlan (Q3) (9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A)\n")
        TaskShortcut.fake = fake
        TaskShortcut.fakeLimit = 0.5
        defer {
            TaskShortcut.fake = nil
            TaskShortcut.fakeLimit = nil
        }
        let names = await shortcutList()?.map(\.name)
        check(names == ["Add to Inbox", "Plan (Q3)"], "shortcut: the picker lists the shortcuts by name", "\(names ?? [])")
        let listed = await shortcutListed(inbox)
        let missing = await shortcutListed(gone)
        check(listed == true && missing == false, "shortcut: a shortcut no longer listed is told apart")

        let destination = TaskDestination.shortcut(id: inbox, name: "Add to Inbox")
        let title = "Check the shortcut path \(UUID().uuidString.prefix(8))"
        let draft = TaskDraft(title: title, steps: [.init(text: "read the input")], notes: "Made up for the self-test.")
        let today = TaskDay(Date(), calendar: .current)
        let payload = TaskPayload.render(draft, to: destination, project: nil, today: today)
        guard let payload, case .stdin(let text) = payload.form,
              let task = TaskShortcut.Task(payload, to: destination, project: nil) else {
            return check(false, "shortcut: a draft renders as a shortcut’s input")
        }
        let before = await shortcutRecords(inbox)
        let sent = await shortcutSend(task)
        check(sent == .sent("Sent to the shortcut “Add to Inbox”."), "shortcut: a finished run says it was sent", "\(sent)")
        let run = TaskShortcut.quiet { fake.runs.last }
        check(run?.arguments == ["run", inbox, "--input-path", "-"], "shortcut: the shortcut is named by its id")
        check(run?.input == Data(text.utf8), "shortcut: its input is the rendered text, byte for byte")
        let recorded = await shortcutRecords(inbox)
        check(recorded == before + 1, "shortcut: one record line keyed by the shortcut’s id", "\(recorded)")

        await shortcutFailureChecks(task, fake: fake, id: inbox, before: recorded)
    }

    /// A failed run, one out of time and one stopped by Cancel say so, quote nothing of the task and record nothing.
    private static func shortcutFailureChecks(_ task: TaskShortcut.Task, fake: FakeShortcutRunner, id: String,
                                              before: Int) async {
        let failedLine = "The shortcut “Add to Inbox” didn’t finish. Nothing more was sent."
        fake.answer(exit: 1)
        let failed = await shortcutSend(task)
        check(failed == .failed(failedLine), "shortcut: a non-zero exit shows the failure line", "\(failed)")
        fake.answer(hangs: true)
        let late = await shortcutSend(task)
        check(late == .failed(failedLine), "shortcut: a run past its time limit is stopped with the same line", "\(late)")
        let stopped: TaskShortcut.Outcome = await withCheckedContinuation { continuation in
            TaskShortcut.send(task) { continuation.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { TaskShortcut.stop() } }
        }
        check(stopped == .stopped(ShortcutList.stoppedLine), "shortcut: Cancel stops the run", "\(stopped)")
        fake.answer()
        let lines = [failed, late, stopped].map { "\($0)" }
        let title = ShortcutList.title(ofInput: task.input)
        check(!lines.contains { $0.contains(title) }, "shortcut: no line quotes the task")
        let recorded = await shortcutRecords(id)
        check(recorded == before, "shortcut: a run that didn’t finish records nothing", "\(recorded)")
    }

    private static func shortcutList() async -> [ShortcutList.Shortcut]? {
        await withCheckedContinuation { continuation in
            TaskShortcut.list { continuation.resume(returning: $0) }
        }
    }

    private static func shortcutListed(_ id: String) async -> Bool? {
        await withCheckedContinuation { continuation in
            TaskShortcut.isListed(id) { continuation.resume(returning: $0) }
        }
    }

    private static func shortcutSend(_ task: TaskShortcut.Task) async -> TaskShortcut.Outcome {
        await withCheckedContinuation { continuation in
            TaskShortcut.send(task) { continuation.resume(returning: $0) }
        }
    }

    /// How many of today's record lines are keyed by `id`, read off the main thread as the record asks.
    private static func shortcutRecords(_ id: String) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let entries = TaskRecordStore.shared.today(project: nil)
                continuation.resume(returning: entries.filter { $0.kind == .shortcut && $0.key == id }.count)
            }
        }
    }
}
#endif
