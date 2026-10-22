import Foundation

/// Reminders' decisions, kept apart from EventKit so they can be tested: what the permission allows and what the user
/// is told, which list a task goes to, when its alert rings, and whether Undo may remove what was added. Next Term reads
/// only the names and ids of the user's lists and the reminders it added itself, never any other reminder.
public enum RemindersAccess {
    /// EventKit's authorization status for reminders, by name, so no caller here needs EventKit.
    public enum Status: Sendable {
        case notDetermined, restricted, denied, authorized, fullAccess, writeOnly
    }

    /// How macOS is asked: full access from macOS 14, the older request before it.
    public enum Request: Equatable, Sendable {
        case fullAccess, legacy
    }

    public enum Step: Equatable, Sendable {
        /// Next Term's own sheet first, then macOS asks the way `Request` says.
        case explain(Request)
        case ready
        /// Nothing can be added: the line to show, and whether Open Privacy & Security is offered.
        case blocked(String, settings: Bool)
    }

    /// The sheet shown before macOS asks.
    public static let explanation = "Next Term adds your tasks to Reminders. It reads only the names of your lists, "
        + "for the picker, and the reminders it added, for Undo. macOS gives this permission to Next Term, and "
        + "commands running in its tabs share it."
    public static let deniedLine = "Next Term can’t reach Reminders. Turn it on in System Settings › Privacy & "
        + "Security › Reminders."
    public static let restrictedLine = "Reminders is turned off on this Mac by its administrator."
    /// Privacy & Security, with no anchor: the Reminders row is one click away there.
    public static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// What happens next for `status` on macOS `os` (its major version).
    public static func step(status: Status, os: Int) -> Step {
        switch status {
        case .notDetermined: return .explain(os >= 14 ? .fullAccess : .legacy)
        case .fullAccess, .authorized: return .ready
        case .denied, .writeOnly: return .blocked(deniedLine, settings: true)
        case .restricted: return .blocked(restrictedLine, settings: false)
        }
    }

    // MARK: the list

    /// A reminder list: its `calendarIdentifier` and title.
    public struct List: Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public enum ListChoice: Equatable, Sendable {
        /// Use this list; `saveID` when it was found by name, so the destination keeps its id from now on.
        case existing(id: String, saveID: Bool)
        /// No list has the name: Add makes it, as the sheet's line already said.
        case create(title: String)
    }

    /// The saved id's list while it exists, else the first list titled exactly `listName` in the store's order, else
    /// a new one.
    public static func chooseList(listID: String?, listName: String, in lists: [List]) -> ListChoice {
        if let listID, lists.contains(where: { $0.id == listID }) { return .existing(id: listID, saveID: false) }
        if let named = lists.first(where: { $0.title == listName }) { return .existing(id: named.id, saveID: true) }
        return .create(title: listName)
    }

    /// The destination with the list's id it was found or made by, its name kept; nil for any other destination.
    public static func withList(_ destination: TaskDestination, id: String) -> TaskDestination? {
        guard case .reminders(_, let listName) = destination else { return nil }
        return .reminders(listID: id, listName: listName)
    }

    /// Where a list's id, found by name or made, is saved, with the destination that holds it.
    public enum ListIDSave: Equatable, Sendable {
        /// The project's own destination, by the project's key.
        case project(String, TaskDestination)
        case defaultDestination(TaskDestination)
    }

    /// The destination the task came from gets the id, so the list is found by id from now on even when renamed: the
    /// project's own when it has one, else the default, as a task's destination is chosen. Nil when that destination
    /// has changed since the task left, or already holds the id. `project` is the project's key.
    public static func savingListID(_ id: String, replacing old: TaskDestination, project: String?,
                                    in settings: TaskSettings) -> ListIDSave? {
        guard let new = withList(old, id: id), new != old else { return nil }
        if let project, let own = settings.projects[project]?.destination {
            return own == old ? .project(project, new) : nil
        }
        return settings.defaultDestination == old ? .defaultDestination(new) : nil
    }

    public static func couldntMake(_ name: String) -> String { "Couldn’t make the list “\(name)”." }
    public static func addToDefault(_ name: String) -> String { "Add to “\(name)” instead" }

    // MARK: the alert

    /// The hour the alert rings on the reminder's day.
    public static let alarmHour = 9

    /// 9:00 in `calendar`'s time zone on the due day, when the switch is on and there is a day.
    public static func alarm(due: DateComponents?, enabled: Bool, calendar: Calendar) -> Date? {
        guard enabled, let due, let year = due.year, let month = due.month, let day = due.day else { return nil }
        let parts = DateComponents(year: year, month: month, day: day, hour: alarmHour, minute: 0)
        return calendar.date(from: parts)
    }

    // MARK: Undo

    /// What was saved, for Undo to compare with.
    public struct Saved: Equatable, Sendable {
        public let title: String
        public let notes: String
        public let due: DateComponents?

        public init(title: String, notes: String, due: DateComponents?) {
            self.title = title
            self.notes = notes
            self.due = due
        }
    }

    /// The reminder as Reminders has it now.
    public struct Found: Equatable, Sendable {
        public let title: String
        public let notes: String?
        public let due: DateComponents?
        public let completed: Bool

        public init(title: String, notes: String?, due: DateComponents?, completed: Bool) {
            self.title = title
            self.notes = notes
            self.due = due
            self.completed = completed
        }
    }

    public enum UndoDecision: Equatable, Sendable {
        case remove
        /// Left in Reminders, with the line that says why.
        case keep(String)
        /// Already removed in Reminders: nothing to do.
        case gone
    }

    public static let changedLine = "You changed it in Reminders, so it stays."

    /// Remove only a reminder still as it was saved: same title, notes and day, and not completed.
    public static func undo(_ saved: Saved, now: Found?) -> UndoDecision {
        guard let now else { return .gone }
        let notesSame = (now.notes ?? "") == saved.notes
        let unchanged = now.title == saved.title && notesSame && sameDay(saved.due, now.due) && !now.completed
        return unchanged ? .remove : .keep(changedLine)
    }

    /// The same all-day date: year, month and day equal and no time of day added, whatever calendar or time zone
    /// Reminders filled in when it read it back.
    static func sameDay(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let days = a.year == b.year && a.month == b.month && a.day == b.day
        return days && a.hour == b.hour && a.minute == b.minute
    }
}
