import AppKit
import CryptoKit
import NextTermCore

#if DEBUG
/// The Add Task sheet's Destination, its line and What's sent, with every opener recorded and nothing opened: a page
/// leaves one recorded link and one line in the self-test's own posted record, and the project's saved destination
/// stays as it was; six list items to Trello turn Add off and five open five; a cut opens What's sent by itself; a
/// stored key is ••• in the link, the line and What's sent; Reminders with the in-memory store, and its "Added a
/// minute ago" question; and the one-time offer. Called from `tasksChecks`, which puts the Tasks settings back after.
extension SelfTest {
    static func destinationSheetChecks(_ c: TerminalWindowController) async {
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        TaskOpen.fakeInstalled = [.things]
        AddTaskDestinationViews.sentOpen = false
        defer {
            TaskOpen.recordsOnly = false
            TaskOpen.opened = []
            TaskOpen.fakeInstalled = nil
            AddTaskOffer.fakeChoice = nil
            AddTaskSheet.current?.pressCancel()
            GitToast.dismiss()
        }
        // The offer is answered first, so the other parts see no offer row.
        await offerChecks(c)
        await pageChecks(c)
        await pageCountChecks(c)
        await cutChecks(c)
        await maskedPageChecks(c)
        await reminderSheetChecks(c)
        await agentSheetChecks(c)
    }

    /// A fresh sheet with `prompt` typed in it.
    static func destinationSheet(_ c: TerminalWindowController, _ prompt: String) async -> AddTaskSheet? {
        AddTaskSheet.current?.pressCancel()
        AddTaskSheet.present(over: c)
        guard await wait(5, { AddTaskSheet.current != nil }), let sheet = AddTaskSheet.current else {
            check(false, "destinations: the sheet opens for “\(prompt)”")
            return nil
        }
        sheet.type(prompt)
        return sheet
    }

    static func postedToday() -> Int { TaskRecordStore.shared.today(project: nil).count }

    /// GitHub chosen in the popup: one recorded link, nothing opened, one posted line, and the project unchanged.
    private static func pageChecks(_ c: TerminalWindowController) async {
        guard let sheet = await destinationSheet(c, "Open the login page") else { return }
        let before = postedToday()
        let github = TaskDestination.github(owner: "example-org", repo: "web")
        sheet.pickDestination(github)
        check(sheet.addTitle == "Open Page" && sheet.placeText.hasPrefix("Opens a new issue in example-org/web on github.com"),
              "destinations: GitHub says where the page opens, and Add says Open Page", sheet.placeText)
        check(sheet.sentText.hasPrefix("github.com/example-org/web/issues/new\n\ntitle\nOpen the login page"),
              "destinations: What's sent shows the page and each value", sheet.sentText)
        sheet.pressAdd()
        let opened = await wait(5) { TaskOpen.opened.count == 1 && AddTaskSheet.current == nil }
        check(opened && TaskOpen.opened.first?.host == "github.com", "destinations: Add records one link and opens nothing",
              TaskOpen.opened.map(\.absoluteString).joined(separator: " "))
        check(await wait(3) { postedToday() == before + 1 }, "destinations: one line goes in the posted record")
        let key = c.project.map(TaskSettings.projectKey)
        check(TaskSettings(defaults: .standard).destination(for: key) == .todoFolder,
              "destinations: the popup changed this Add only, not where the project's tasks go")
        TaskOpen.opened = []
    }

    /// Six list items to Trello turn Add off; five open five pages.
    private static func pageCountChecks(_ c: TerminalWindowController) async {
        let six = (1...6).map { "- card \($0)" }.joined(separator: "\n")
        guard let sheet = await destinationSheet(c, six) else { return }
        sheet.pickDestination(.trello)
        check(!sheet.canAdd && sheet.placeText == "Trello opens one page per task: add at most 5 at once.",
              "destinations: six pages at once are refused", sheet.placeText)
        sheet.type((1...5).map { "- card \($0)" }.joined(separator: "\n"))
        sheet.pressAdd()
        check(await wait(5) { TaskOpen.opened.count == 5 }, "destinations: five list items open five recorded pages",
              "\(TaskOpen.opened.count)")
        TaskOpen.opened = []
        GitToast.dismiss()
    }

    /// A body cut to fit opens What's sent by itself; for the todo folder, What's sent is the file's text.
    private static func cutChecks(_ c: TerminalWindowController) async {
        AddTaskDestinationViews.sentOpen = false
        let notes = (1...900).map { "line \($0) of a long note" }.joined(separator: "\n")
        guard let sheet = await destinationSheet(c, "Read the long note\n\n" + notes) else { return }
        sheet.pickDestination(.github(owner: "example-org", repo: "web"))
        check(sheet.whatsSentOpen && sheet.sentText.contains("(Cut by Next Term") && sheet.placeText.hasSuffix("· cut to fit"),
              "destinations: a cut text opens What's sent by itself, and the line says so", sheet.placeText)
        sheet.pickDestination(.todoFolder)
        let withoutTime = { (text: String) in
            text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("created: ") }
        }
        let file = sheet.texts(at: Date()).first ?? ""
        check(withoutTime(sheet.sentText) == withoutTime(file), "destinations: the todo folder's What's sent is its file")
        sheet.pressCancel()
        AddTaskDestinationViews.sentOpen = false
    }

    /// A stored key in the prompt: ••• in the recorded link, the line and What's sent.
    private static func maskedPageChecks(_ c: TerminalWindowController) async {
        let savedMask = SecretMask.current
        defer { SecretMask.current = savedMask }
        let value = "nt-sheet-key-" + UUID().uuidString.prefix(12)
        let key = SymmetricKey(size: .bits256)
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        guard let sheet = await destinationSheet(c, "Rotate \(value) today") else { return }
        sheet.pickDestination(.github(owner: "example-org", repo: "web"))
        let shown = sheet.placeText + sheet.sentText
        check(!shown.contains(value) && sheet.sentText.contains("Rotate ••• today"),
              "destinations: a stored key is ••• in the line and What's sent", sheet.sentText)
        sheet.pressAdd()
        _ = await wait(5) { TaskOpen.opened.count == 1 }
        let link = TaskOpen.opened.first?.absoluteString ?? ""
        check(!link.isEmpty && !link.contains(value) && link.contains("%E2%80%A2%E2%80%A2%E2%80%A2"),
              "destinations: and in the link", link)
        // Nothing of the task is written down: this run's own report holds neither its text nor its link.
        let report = reportSoFar()
        check(!link.isEmpty && !report.contains(value) && !report.contains(link),
              "destinations: the run's report holds neither the task's text nor its link")
        TaskOpen.opened = []
        GitToast.dismiss()
    }
}

extension SelfTest {
    /// Reminders from the popup with the in-memory store: the line for No Date, one reminder, and a second Add within
    /// a minute asks first.
    private static func reminderSheetChecks(_ c: TerminalWindowController) async {
        let list = RemindersAccess.List(id: "nt-list", title: "Next Term")
        let fake = FakeRemindersStore(status: .fullAccess, lists: [list])
        TaskReminders.fake = fake
        TaskReminders.fakeOS = 14
        RemindersSheets.fakeAnswer = true
        let defaults = UserDefaults.standard
        let reminders = TaskDestination.reminders(listID: "nt-list", listName: "Next Term")
        defaults.set(TaskDestination.json(reminders), forKey: TaskSettings.Key.defaultDestination)
        defer {
            TaskReminders.fake = nil
            TaskReminders.fakeOS = nil
            RemindersSheets.fakeAnswer = nil
            RemindersSheets.shown = []
            defaults.removeObject(forKey: TaskSettings.Key.defaultDestination)
            GitToast.dismiss()
        }
        guard let sheet = await destinationSheet(c, "Water the plants") else { return }
        sheet.choose(.noDate)
        let line = "Adds to Reminders, list “Next Term”, no due date"
        check(await wait(3) { sheet.placeText == line }, "destinations: Reminders with No Date says list and no due date",
              sheet.placeText)
        sheet.pressAdd()
        let added = await wait(5) { TaskReminders.quiet { fake.items.count } == 1 && AddTaskSheet.current == nil }
        check(added, "destinations: Add saves one reminder and the sheet closes")
        guard let again = await destinationSheet(c, "Water the plants") else { return }
        again.choose(.noDate)
        again.pressAdd()
        let asked = await wait(5) { again.askingAgain?.contains("Added a minute ago. Add again?") == true }
        check(asked, "destinations: a second Add within a minute asks first", again.askingAgain ?? "no question")
        again.answerAgain(false)
        check(TaskReminders.quiet { fake.items.count } == 1, "destinations: Cancel there adds nothing")
        again.pressCancel()
    }

    /// The one-time offer: × keeps the todo folder and never asks again; Choose… Things makes it the default.
    private static func offerChecks(_ c: TerminalWindowController) async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: TaskSettings.Key.destinationOffer)
        defaults.removeObject(forKey: TaskSettings.Key.defaultDestination)
        guard let sheet = await destinationSheet(c, "Try the offer") else { return }
        check(sheet.offerShown, "destinations: with no destination set, the sheet offers another")
        sheet.pressDismissOffer()
        check(TaskSettings(defaults: defaults).destinationOffer == .done && !sheet.offerShown,
              "destinations: × answers the offer and changes nothing")
        guard let second = await destinationSheet(c, "Try the offer") else { return }
        check(!second.offerShown, "destinations: the offer never shows again")
        defaults.removeObject(forKey: TaskSettings.Key.destinationOffer)
        guard let third = await destinationSheet(c, "Try the offer") else { return }
        AddTaskOffer.fakeChoice = .things
        third.pressChooseOffer()
        let settings = TaskSettings(defaults: defaults)
        check(settings.defaultDestination == .things(list: nil) && third.chosenDestination == .things(list: nil)
                && settings.destinationOffer == .done,
              "destinations: choosing Things makes it the default and this Add's destination")
        third.pressCancel()
        defaults.removeObject(forKey: TaskSettings.Key.defaultDestination)
        AddTaskOffer.fakeChoice = nil
    }
}
#endif
