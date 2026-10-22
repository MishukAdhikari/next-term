import AppKit
import NextTermCore

/// Adds one task to Reminders: Next Term's own sheet before macOS ever asks, then the list (found by id, else by
/// name, else made, as the sheet's line said), one all-day reminder, one line in the posted record, and a notice with
/// Undo that removes the reminder only while it is as saved. The store is used on one serial queue and every answer
/// comes back on the main thread. A message says what failed and never quotes the task; nothing is logged.
@MainActor
enum TaskReminders {
    enum Outcome: Equatable {
        /// Saved, with its id and the id of the list it went to.
        case added(id: String, list: String)
        /// The user chose Not Now, or Cancel: nothing changed.
        case notNow
        /// Nothing was added; the line says why.
        case failed(String)
    }

    static let couldntAdd = "Couldn’t add the reminder. Nothing was saved."
    static let deniedNow = "Reminders wasn’t allowed. Nothing was saved."
    static let couldntRemove = "Couldn’t remove the reminder."

    nonisolated(unsafe) private static var real: RemindersStore?
    nonisolated private static let queue = DispatchQueue(label: "nextterm.tasks.reminders", qos: .userInitiated)

    /// The store, made on first use: never at launch, so nothing reaches EventKit before the user picks Reminders.
    static var store: RemindersStore {
        #if DEBUG
        if let fake { return fake }
        #endif
        if let real { return real }
        let made = EventKitRemindersStore()
        real = made
        return made
    }

    /// The major version of macOS, which decides how access is asked for.
    static var os: Int {
        #if DEBUG
        if let fakeOS { return fakeOS }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    // MARK: access

    /// Makes sure Reminders can be used: ready at once, or after Next Term's sheet and macOS's own question. A refusal
    /// shows its line over `window`, with Open Privacy & Security when that is where it is turned on. `done` gets
    /// nil once access is given, else what happened instead.
    static func allow(from window: NSWindow?, done: @escaping (Outcome?) -> Void) {
        let store = store
        switch step {
        case .ready:
            done(nil)
        case .blocked(let line, let settings):
            RemindersSheets.blocked(line, settings: settings, in: window)
            done(.failed(line))
        case .explain(let how):
            RemindersSheets.explain(in: window) { go in
                guard go else { return done(.notNow) }
                queue.async {
                    store.request(how) { granted in
                        queue.async {
                            // The store starts afresh before the Add that follows reads any list.
                            if granted { store.refresh() }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    if granted { return done(nil) }
                                    RemindersSheets.blocked(RemindersAccess.deniedLine, settings: true, in: window)
                                    done(.failed(deniedNow))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Where Reminders stands now, for a line or a popup row; never asks.
    static var step: RemindersAccess.Step { RemindersAccess.step(status: store.status(), os: os) }

    /// Whether Add would make the destination's list, for the sheet's "new list" line: nil unless access is given
    /// already, so nothing is read and nothing asked before the user's own Add.
    static func makesList(_ destination: TaskDestination, done: @escaping (Bool?) -> Void) {
        guard case .reminders(let listID, let listName) = destination, step == .ready else { return done(nil) }
        let store = store
        queue.async {
            let choice = RemindersAccess.chooseList(listID: listID, listName: listName, in: store.lists())
            let makes: Bool
            if case .create = choice { makes = true } else { makes = false }
            DispatchQueue.main.async { done(makes) }
        }
    }

    /// The user's lists, names and ids only, for a picker; empty unless access is given already. Never asks.
    static func lists(done: @escaping ([RemindersAccess.List]) -> Void) {
        guard step == .ready else { return done([]) }
        let store = store
        queue.async {
            let lists = store.lists()
            DispatchQueue.main.async { done(lists) }
        }
    }
}

extension TaskReminders {
    /// One task to add: the rendered reminder, its destination and the project's key, for the record and for saving
    /// the list's id back. A project's path, a worktree's too, is turned into its key here.
    struct Task {
        let title: String
        let notes: String
        let due: DateComponents?
        let destination: TaskDestination
        let project: String?

        /// Nil unless the payload is a reminder and the destination is a Reminders list.
        init?(_ payload: TaskPayload, to destination: TaskDestination, project: String?) {
            guard case .reminder(let title, let notes, let due) = payload.form,
                  case .reminders = destination else { return nil }
            self.title = title
            self.notes = notes
            self.due = due
            self.destination = destination
            self.project = project.map(TaskSettings.projectKey)
        }
    }

    /// Adds `task` after access is given, asking over `window`, then offers Undo in `undoIn` (`window` when nil): the
    /// Add Task sheet asks over itself and leaves the notice to the project window it closes into. The Add the user
    /// pressed is the confirmation Apple asks for before a change.
    static func add(_ task: Task, from window: NSWindow?, undoIn notice: NSWindow? = nil,
                    done: @escaping (Outcome) -> Void) {
        allow(from: window) { refused in
            if let refused { return done(refused) }
            let alarmOn = TaskSettings(defaults: .standard).remindersAlarm
            place(task, list: nil, alarmOn: alarmOn, from: window, undoIn: notice ?? window, done: done)
        }
    }

    /// On the queue: finds or makes the list (`list` when the user took the default instead), saves the reminder and
    /// records it.
    private static func place(_ task: Task, list: RemindersAccess.List?, alarmOn: Bool, from window: NSWindow?,
                              undoIn notice: NSWindow?, done: @escaping (Outcome) -> Void) {
        guard case .reminders(let listID, let listName) = task.destination else { return done(.failed(couldntAdd)) }
        let store = store
        queue.async {
            let chosen = chosenList(store, listID: listID, listName: listName, taken: list)
            guard case .found(let target, let saveID) = chosen else {
                let fallback = store.defaultList()
                return DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        offerDefault(task, name: listName, fallback: fallback, alarmOn: alarmOn, from: window,
                                     undoIn: notice, done: done)
                    }
                }
            }
            let alarm = RemindersAccess.alarm(due: task.due, enabled: alarmOn, calendar: .current)
            let id = try? store.add(title: task.title, notes: task.notes, due: task.due, alarm: alarm, list: target.id)
            if let id {
                let entry = TaskRecord.Entry(at: Date(), kind: .reminders, key: target.id, title: task.title,
                                             slug: TodoFile.slug(task.title), project: task.project, itemID: id,
                                             waited: false)
                TaskRecordStore.shared.record(entry)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Kept even when the reminder couldn't be saved: a list just made is then used again, not made twice.
                    if saveID && list == nil { saveListID(target.id, replacing: task.destination, project: task.project) }
                    guard let id else { return done(.failed(couldntAdd)) }
                    let saved = RemindersAccess.Saved(title: task.title, notes: task.notes, due: task.due)
                    offerUndo(id, saved: saved, in: notice)
                    done(.added(id: id, list: target.id))
                }
            }
        }
    }

    private enum Chosen {
        case found(RemindersAccess.List, saveID: Bool)
        case couldntMake
    }

    /// On the queue. A made list's id is saved back like one found by name.
    nonisolated private static func chosenList(_ store: RemindersStore, listID: String?, listName: String,
                                   taken: RemindersAccess.List?) -> Chosen {
        if let taken { return .found(taken, saveID: false) }
        let lists = store.lists()
        switch RemindersAccess.chooseList(listID: listID, listName: listName, in: lists) {
        case .existing(let id, let saveID):
            let title = lists.first { $0.id == id }?.title ?? listName
            return .found(RemindersAccess.List(id: id, title: title), saveID: saveID)
        case .create(let title):
            guard let made = try? store.makeList(title) else { return .couldntMake }
            return .found(made, saveID: true)
        }
    }

    /// The list couldn't be made: says so, and offers the user's default list instead.
    private static func offerDefault(_ task: Task, name: String, fallback: RemindersAccess.List?, alarmOn: Bool,
                                     from window: NSWindow?, undoIn notice: NSWindow?,
                                     done: @escaping (Outcome) -> Void) {
        let line = RemindersAccess.couldntMake(name)
        guard let fallback else { return done(.failed(line)) }
        RemindersSheets.offerDefault(line, button: RemindersAccess.addToDefault(fallback.title), in: window) { take in
            guard take else { return done(.failed(line)) }
            place(task, list: fallback, alarmOn: alarmOn, from: window, undoIn: notice, done: done)
        }
    }
}

extension TaskReminders {
    /// "Added to Reminders" with Undo, for as long as the notice shows.
    static func offerUndo(_ id: String, saved: RemindersAccess.Saved, in window: NSWindow?) {
        GitToast.show("Added to Reminders", in: window, button: "Undo") {
            MainActor.assumeIsolated { undo(id, saved: saved, in: window) }
        }
    }

    /// Removes the reminder only while its title, notes and day are as saved and it is not completed, and forgets it in
    /// the record; otherwise it stays and the notice says why. Only this one reminder is read, by its id.
    static func undo(_ id: String, saved: RemindersAccess.Saved, in window: NSWindow?) {
        let store = store
        queue.async {
            let decision = RemindersAccess.undo(saved, now: store.find(id))
            var removed = false
            if decision == .remove { removed = (try? store.remove(id)) != nil }
            if removed || decision == .gone { TaskRecordStore.shared.remove(itemID: id, kind: .reminders) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .keep(let line) = decision { return GitToast.show(line, in: window) }
                    if decision == .remove && !removed { GitToast.show(couldntRemove, in: window) }
                }
            }
        }
    }

    /// The list's id, found by name or made, saved into the destination it came from (the project's own, or the
    /// default), so the list is found by id from now on even when renamed. A destination changed meanwhile is left.
    /// `project` is the project's key.
    static func saveListID(_ id: String, replacing old: TaskDestination, project: String?) {
        let defaults = UserDefaults.standard
        var settings = TaskSettings(defaults: defaults)
        let save = RemindersAccess.savingListID(id, replacing: old, project: project, in: settings)
        switch save {
        case .project(let key, let new):
            settings.projects[key]?.destination = new
            if let json = TaskSettings.json(projects: settings.projects) {
                defaults.set(json, forKey: TaskSettings.Key.projects)
            }
        case .defaultDestination(let new):
            if let json = TaskDestination.json(new) { defaults.set(json, forKey: TaskSettings.Key.defaultDestination) }
        case nil:
            break
        }
    }

    #if DEBUG
    /// The self-test's store and macOS version: set, no call reaches EventKit or the user's Reminders.
    nonisolated(unsafe) static var fake: FakeRemindersStore?
    nonisolated(unsafe) static var fakeOS: Int?

    /// Runs `body` on the store's queue once it is idle, so the self-test reads and changes its fake store without
    /// racing a step still running there.
    nonisolated static func quiet<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
    #endif
}
