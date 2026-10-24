import AppKit
import CryptoKit
import NextTermCore

#if DEBUG
/// Every destination once from the Add Task sheet, with a stored key in the task and every fake on: app links and pages
/// are recorded and never opened, Reminders is an in-memory store, and a shortcut runs in a fake runner. Each one gets
/// the key as ••• and never its value, each app or page leaves exactly one recorded link, and the posted record gains
/// one line per destination. An app not installed can't be chosen and opens nothing. Afterwards every fake is back to
/// the real thing. Through Your Agent is driven by `agentSheetChecks`, with its agent tabs. Called from `tasksChecks`.
extension SelfTest {
    static func destinationChecks(_ c: TerminalWindowController, folder: URL) async {
        let savedMask = SecretMask.current
        let filesBefore = todoFiles(folder)
        await sweep(c, folder: folder)
        // Read after the sweep has returned, so this checks what its own cleanup left behind.
        let real = !TaskOpen.recordsOnly && TaskOpen.opened.isEmpty && TaskOpen.fakeInstalled == nil
        let fakesGone = TaskReminders.fake == nil && TaskShortcut.fake == nil && TaskShortcut.fakeLimit == nil
        let sheetsReal = RemindersSheets.fakeAnswer == nil && RemindersSheets.shown.isEmpty
        let closed = AddTaskSheet.current == nil && !AddTaskDestinationViews.sentOpen
        check(real && fakesGone && sheetsReal && closed,
              "destinations: after the part, the openers, Reminders and the shortcut runner are the real ones again")
        check(SecretMask.current === savedMask,
              "destinations: after the part, the stored keys' mask is the one it found")
        let left = todoFiles(folder).subtracting(filesBefore)
        check(left.isEmpty, "destinations: after the part, the todo folder holds no file of its own",
              left.sorted().joined(separator: ", "))
    }

    /// The fakes on, every destination once, then every fake off and the mask put back, even when a step returns early.
    private static func sweep(_ c: TerminalWindowController, folder: URL) async {
        let savedMask = SecretMask.current
        let value = "nt-sweep-key-" + UUID().uuidString.prefix(12)
        let key = SymmetricKey(size: .bits256)
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let list = RemindersAccess.List(id: "nt-sweep-list", title: "Next Term")
        let store = FakeRemindersStore(status: .fullAccess, lists: [list])
        let runner = FakeShortcutRunner(list: "Sweep (\(sweepShortcut))\n")
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        TaskOpen.fakeInstalled = [.things, .todoist, .omnifocus]
        TaskReminders.fake = store
        TaskReminders.fakeOS = 14
        RemindersSheets.fakeAnswer = true
        TaskShortcut.fake = runner
        TaskShortcut.fakeLimit = 1
        AddTaskDestinationViews.sentOpen = false
        defer {
            endSweep()
            SecretMask.current = savedMask
        }
        let tag = String(UUID().uuidString.prefix(8))
        await sweepChecks(c, folder: folder, value: value, tag: tag, store: store, runner: runner)
        await notInstalledChecks(c)
    }

    /// The shortcut the fake runner lists, by a made-up identifier.
    private static let sweepShortcut = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"

    /// Every fake off, the sheet closed and the notice gone.
    private static func endSweep() {
        AddTaskSheet.current?.pressCancel()
        TaskOpen.recordsOnly = false
        TaskOpen.opened = []
        TaskOpen.fakeInstalled = nil
        TaskReminders.fake = nil
        TaskReminders.fakeOS = nil
        RemindersSheets.fakeAnswer = nil
        RemindersSheets.shown = []
        TaskShortcut.fake = nil
        TaskShortcut.fakeLimit = nil
        AddTaskDestinationViews.sentOpen = false
        GitToast.dismiss()
    }

    /// The destinations a sweep adds to, each by its made-up details.
    private static var sweepDestinations: [TaskDestination] {
        [
            .todoFolder, .reminders(listID: "nt-sweep-list", listName: "Next Term"), .things(list: nil),
            .shortcut(id: sweepShortcut, name: "Sweep"), .todoist, .omnifocus,
            .github(owner: "example-org", repo: "web"), .gitlab(path: "example-org/web"), .linear(team: "ENG"), .trello,
            .azureBoards(org: "example-org", project: "web", type: "Task"),
        ]
    }

    /// The `.md` files in `folder`.
    private static func todoFiles(_ folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".md") })
    }
}

extension SelfTest {
    /// Each destination once, the same task with the key in it: what each one got, and one record line each.
    private static func sweepChecks(_ c: TerminalWindowController, folder: URL, value: String, tag: String,
                                    store: FakeRemindersStore, runner: FakeShortcutRunner) async {
        let filesBefore = todoFiles(folder)
        let remindersBefore = TaskReminders.quiet { store.items.count }
        var added: [TaskDestination.Kind] = []
        for destination in sweepDestinations {
            let name = destination.kind.rawValue
            guard let sheet = await destinationSheet(c, "Sweep \(tag) to \(name) token=\(value)") else { continue }
            sheet.pickDestination(destination)
            let ready = await wait(5) { sheet.canAdd }
            let shown = sheet.placeText + "\n" + sheet.sentText
            check(ready && !shown.contains(value) && sheet.sentText.contains("token=•••"),
                  "destinations: \(name) can be added, and its line and What's sent hold the key as •••", sheet.placeText)
            sheet.pressAdd()
            let closed = await wait(8) { AddTaskSheet.current == nil }
            check(closed, "destinations: Add to \(name) closes the sheet", sheet.placeText)
            if closed { added.append(destination.kind) }
            GitToast.dismiss()
        }
        check(added.count == sweepDestinations.count, "destinations: every destination took the task",
              added.map(\.rawValue).joined(separator: ", "))
        // The todo folder: one file, with the key as •••.
        let made = todoFiles(folder).subtracting(filesBefore)
        let texts: [String] = made.compactMap { (name: String) -> String? in
            let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path)
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }
        check(texts.count == 1 && texts[0].contains("token=•••") && !texts[0].contains(value),
              "destinations: the todo folder gets one file, with the key as •••", made.sorted().joined(separator: ", "))
        for name in made { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        sweepReminderChecks(store, before: remindersBefore, value: value)
        sweepShortcutChecks(runner, value: value)
        sweepLinkChecks(value: value)
        await sweepRecordChecks(tag: tag, value: value)
    }

    private static func sweepReminderChecks(_ store: FakeRemindersStore, before: Int, value: String) {
        let items = TaskReminders.quiet { Array(store.items.values) }
        let item = items.first { $0.title.contains("to reminders") }
        let masked = item.map { $0.title.contains("token=•••") && !($0.title + $0.notes).contains(value) } ?? false
        check(items.count == before + 1 && masked && item?.list == "nt-sweep-list",
              "destinations: Reminders saves one reminder in its list, with the key as •••", "\(items.count)")
    }

    private static func sweepShortcutChecks(_ runner: FakeShortcutRunner, value: String) {
        let runs = TaskShortcut.quiet { runner.runs }
        let input = runs.last.flatMap { String(data: $0.input, encoding: .utf8) } ?? ""
        check(runs.count == 1 && runs.last?.arguments == ["run", sweepShortcut, "--input-path", "-"],
              "destinations: the shortcut runs once, named by its id", "\(runs.count)")
        check(input.contains("token=•••") && !input.contains(value), "destinations: the shortcut's input holds the key as •••")
    }
}

extension SelfTest {
    /// One recorded link per app and page, each with the key as ••• and none with its value; nothing opened.
    private static func sweepLinkChecks(value: String) {
        let links: [URL] = TaskOpen.opened
        // Things, Todoist and OmniFocus by their scheme, and five pages by their host: eight places, each once.
        let places: [String] = links.map { (url: URL) -> String in
            let scheme: String = url.scheme ?? ""
            return scheme == "https" ? (url.host ?? "") : scheme
        }
        let expected: Set<String> = ["things", "todoist", "omnifocus", "github.com", "gitlab.com", "linear.app",
                                     "trello.com", "dev.azure.com"]
        let bullets = "%E2%80%A2%E2%80%A2%E2%80%A2"
        let masked = links.allSatisfy { (url: URL) -> Bool in
            url.absoluteString.contains(bullets) && !url.absoluteString.contains(value)
        }
        let once: Bool = links.count == expected.count && Set(places) == expected
        check(once && masked, "destinations: each app and page leaves one recorded link, with the key as •••",
              places.joined(separator: " "))
        TaskOpen.opened = []
    }

    /// One posted line per destination but the todo folder, each with the masked title.
    private static func sweepRecordChecks(tag: String, value: String) async {
        // The store reads its file on its own queue; that read stays off the main thread.
        let read = Task.detached { () -> [TaskRecord.Entry] in TaskRecordStore.shared.today(project: nil) }
        let entries: [TaskRecord.Entry] = await read.value
        let mine = entries.filter { $0.title.contains(tag) }
        let kinds: [TaskDestination.Kind] = mine.map(\.kind)
        let expected: [TaskDestination.Kind] = sweepDestinations.map(\.kind).filter { $0 != .todoFolder }
        let each: Bool = kinds.count == expected.count && Set(kinds) == Set(expected)
        check(each, "destinations: the posted record holds one line per destination",
              kinds.map(\.rawValue).joined(separator: ", "))
        check(mine.allSatisfy { !$0.title.contains(value) }, "destinations: the posted record holds the key as •••")
    }

    /// No app installed: Things says so, can't be added, and nothing is recorded.
    private static func notInstalledChecks(_ c: TerminalWindowController) async {
        TaskOpen.fakeInstalled = []
        TaskOpen.opened = []
        guard let sheet = await destinationSheet(c, "Sweep with no apps") else { return }
        sheet.pickDestination(.things(list: nil))
        let refused = await wait(3) { !sheet.canAdd && sheet.placeText.contains("isn’t installed") }
        sheet.pressAdd()
        check(refused && TaskOpen.opened.isEmpty && AddTaskSheet.current === sheet,
              "destinations: Things not installed says so, Add is off, and nothing opens", sheet.placeText)
        sheet.pressCancel()
    }
}
#endif
