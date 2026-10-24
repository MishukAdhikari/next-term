import EventKit
import Foundation
import NextTermCore

/// What Next Term asks of Reminders, and nothing more: the permission, the names and ids of the lists, a new list, one
/// new reminder, and the reminders it added, by id, for Undo. It never fetches other reminders. Called on
/// `TaskReminders`' serial queue, except `status`, which reads only the permission and may be called anywhere.
protocol RemindersStore: AnyObject, Sendable {
    func status() -> RemindersAccess.Status
    /// Asks macOS; `done` gets whether access was given, on any thread.
    func request(_ how: RemindersAccess.Request, done: @escaping @Sendable (Bool) -> Void)
    /// After access is given: a store made before it can see no lists and no default list until it starts afresh.
    func refresh()
    func lists() -> [RemindersAccess.List]
    /// The list new reminders go to by the user's choice in Reminders.
    func defaultList() -> RemindersAccess.List?
    func makeList(_ title: String) throws -> RemindersAccess.List
    /// Saves one reminder and returns its id.
    func add(title: String, notes: String, due: DateComponents?, alarm: Date?, list: String) throws -> String
    func find(_ id: String) -> RemindersAccess.Found?
    func remove(_ id: String) throws
}

/// The one file that speaks to EventKit. One store for the app's life, made on first use, never at launch.
final class EventKitRemindersStore: RemindersStore, @unchecked Sendable {
    struct Failed: Error {}

    private lazy var store = EKEventStore()

    /// A new store, since the one that asked was made before access was given.
    func refresh() { store = EKEventStore() }

    func status() -> RemindersAccess.Status {
        // By number, so one switch reads on macOS 13 and 14 alike: 3 is "authorized" before 14, "full access" from it.
        let raw = EKEventStore.authorizationStatus(for: .reminder).rawValue
        switch raw {
        case 0: return .notDetermined
        case 1: return .restricted
        case 3: return .fullAccess
        case 4: return .writeOnly
        default: return .denied
        }
    }

    func request(_ how: RemindersAccess.Request, done: @escaping @Sendable (Bool) -> Void) {
        if #available(macOS 14, *), how == .fullAccess {
            store.requestFullAccessToReminders { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .reminder) { granted, _ in done(granted) }
        }
    }

    func lists() -> [RemindersAccess.List] {
        store.calendars(for: .reminder).map { RemindersAccess.List(id: $0.calendarIdentifier, title: $0.title) }
    }

    func defaultList() -> RemindersAccess.List? {
        store.defaultCalendarForNewReminders().map { RemindersAccess.List(id: $0.calendarIdentifier, title: $0.title) }
    }

    func makeList(_ title: String) throws -> RemindersAccess.List {
        // A new list belongs to the account the user's default list is in.
        guard let source = store.defaultCalendarForNewReminders()?.source else { throw Failed() }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        list.source = source
        try store.saveCalendar(list, commit: true)
        return RemindersAccess.List(id: list.calendarIdentifier, title: list.title)
    }

    func add(title: String, notes: String, due: DateComponents?, alarm: Date?, list: String) throws -> String {
        guard let calendar = store.calendar(withIdentifier: list) else { throw Failed() }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
        reminder.calendar = calendar
        reminder.dueDateComponents = due
        if let alarm { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func find(_ id: String) -> RemindersAccess.Found? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return RemindersAccess.Found(title: reminder.title ?? "", notes: reminder.notes,
                                     due: reminder.dueDateComponents, completed: reminder.isCompleted)
    }

    func remove(_ id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }
}

#if DEBUG
/// The self-test's Reminders, in memory: it never touches the user's real ones. Each answer can be set.
final class FakeRemindersStore: RemindersStore, @unchecked Sendable {
    struct Failed: Error {}

    struct Item: Equatable {
        var title: String
        var notes: String
        var due: DateComponents?
        var alarm: Date?
        var list: String
        var completed = false
    }

    var currentStatus: RemindersAccess.Status
    /// What macOS answers when asked; how often it was asked, and how.
    var grants = true
    private(set) var asked: [RemindersAccess.Request] = []
    var allLists: [RemindersAccess.List]
    var canMakeLists = true
    var canAdd = true
    var canRemove = true
    var items: [String: Item] = [:]
    /// How often the store started afresh, and how often the lists were read.
    private(set) var refreshed = 0
    private(set) var reads = 0
    private var next = 0

    init(status: RemindersAccess.Status = .fullAccess, lists: [RemindersAccess.List] = []) {
        currentStatus = status
        allLists = lists
    }

    func status() -> RemindersAccess.Status { currentStatus }

    func request(_ how: RemindersAccess.Request, done: @escaping @Sendable (Bool) -> Void) {
        asked.append(how)
        currentStatus = grants ? .fullAccess : .denied
        done(grants)
    }

    func refresh() { refreshed += 1 }

    func lists() -> [RemindersAccess.List] {
        reads += 1
        return allLists
    }

    func defaultList() -> RemindersAccess.List? {
        reads += 1
        return allLists.first
    }

    func makeList(_ title: String) throws -> RemindersAccess.List {
        guard canMakeLists else { throw Failed() }
        next += 1
        let list = RemindersAccess.List(id: "fake-list-\(next)", title: title)
        allLists.append(list)
        return list
    }

    func add(title: String, notes: String, due: DateComponents?, alarm: Date?, list: String) throws -> String {
        guard canAdd, allLists.contains(where: { $0.id == list }) else { throw Failed() }
        next += 1
        let id = "fake-reminder-\(next)"
        items[id] = Item(title: title, notes: notes, due: due, alarm: alarm, list: list)
        return id
    }

    func find(_ id: String) -> RemindersAccess.Found? {
        guard let item = items[id] else { return nil }
        let notes: String? = item.notes.isEmpty ? nil : item.notes
        return RemindersAccess.Found(title: item.title, notes: notes, due: item.due, completed: item.completed)
    }

    func remove(_ id: String) throws {
        guard canRemove else { throw Failed() }
        items[id] = nil
    }
}
#endif
