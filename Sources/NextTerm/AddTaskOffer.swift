import AppKit
import NextTermCore

/// The one-time offer in the Add Task sheet, shown while neither the project nor the default has a destination: tasks
/// go to the todo folder unless the user picks another place here. Reminders is offered first. Choosing makes it the
/// default; the × keeps the todo folder. Either way it never shows again, and add_task never shows it.
@MainActor
enum AddTaskOffer {
    enum Choice: Equatable {
        case reminders, things, shortcut, todoFolder, more
    }

    /// Whether the offer shows for a sheet in the project with this key.
    static func shows(project: String?) -> Bool {
        let settings = TaskSettings(defaults: .standard)
        guard settings.destinationOffer == .pending, settings.defaultDestination == nil else { return false }
        guard let project else { return true }
        return settings.projects[TaskSettings.projectKey(project)]?.destination == nil
    }

    /// The offer is answered: it never shows again.
    static func markDone() {
        UserDefaults.standard.set(TaskSettings.DestinationOffer.done.rawValue, forKey: TaskSettings.Key.destinationOffer)
    }

    /// Makes `destination` the default for every project without one of its own.
    static func makeDefault(_ destination: TaskDestination) {
        guard let json = TaskDestination.json(destination) else { return }
        UserDefaults.standard.set(json, forKey: TaskSettings.Key.defaultDestination)
    }

    /// The small chooser over `window`: Reminders (preselected), Things when installed, A Shortcut…, the todo folder,
    /// and More…. `answer` gets the choice, or nil for Cancel.
    static func choose(over window: NSWindow, thingsInstalled: Bool, answer: @escaping (Choice?) -> Void) {
        var choices: [(String, Choice)] = [("Reminders (on this Mac)", .reminders)]
        if thingsInstalled { choices.append(("Things", .things)) }
        choices += [("A Shortcut…", .shortcut), ("The todo folder in this project", .todoFolder), ("More…", .more)]
        #if DEBUG
        if let fakeChoice {
            return answer(choices.contains { $0.1 == fakeChoice } ? fakeChoice : nil)
        }
        #endif
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for (title, _) in choices { popup.addItem(withTitle: title) }
        popup.selectItem(at: 0)
        let alert = NSAlert()
        alert.messageText = "Where should tasks go?"
        alert.informativeText = "Your choice becomes the default for every project. Settings › Tasks can change it, "
            + "or give a project its own."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return answer(nil) }
                answer(choices[safe: popup.indexOfSelectedItem]?.1)
            }
        }
    }

    #if DEBUG
    /// The self-test's answer to the chooser: no sheet opens.
    nonisolated(unsafe) static var fakeChoice: Choice?
    #endif
}
