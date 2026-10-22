import Foundation
import NextTermCore

/// Hands one task to the shortcut the user picked: its rendered, masked text as the shortcut's input, the shortcut named
/// by its identifier, one run at a time on a serial queue, stopped after a minute or by Cancel. A run that finishes
/// writes one line in the posted record, keyed by the shortcut's id; there is no Undo, since Next Term can't know what
/// the shortcut did. Lines never quote the task, and nothing the command prints is shown or logged. The list of
/// shortcuts is read only when asked for, never at launch. Every answer comes back on the main thread.
@MainActor
enum TaskShortcut {
    enum Outcome: Equatable {
        case sent(String)
        case failed(String)
        /// Cancel stopped it.
        case stopped(String)
    }

    nonisolated(unsafe) private static var real: ShortcutRunner?
    nonisolated private static let queue = DispatchQueue(label: "nextterm.tasks.shortcut", qos: .userInitiated)
    /// The run in progress, for Cancel.
    private static var current: ShortcutStop?

    /// The runner, made on first use.
    static var runner: ShortcutRunner {
        #if DEBUG
        if let fake { return fake }
        #endif
        if let real { return real }
        let made = ProcessShortcutRunner()
        real = made
        return made
    }

    /// How long a run may take.
    static var limit: TimeInterval {
        #if DEBUG
        if let fakeLimit { return fakeLimit }
        #endif
        return ShortcutList.limit
    }

    /// One task to send: the shortcut's input, the shortcut, and the project's key for the record.
    struct Task {
        let input: String
        let id: String
        let name: String
        let project: String?

        /// Nil unless the payload is a shortcut's input and the destination a shortcut.
        init?(_ payload: TaskPayload, to destination: TaskDestination, project: String?) {
            guard case .stdin(let input) = payload.form, case .shortcut(let id, let name) = destination else { return nil }
            self.input = input
            self.id = id
            self.name = name
            self.project = project.map(TaskSettings.projectKey)
        }
    }

    /// The user's shortcuts, or nil when the list couldn't be read.
    static func list(done: @escaping ([ShortcutList.Shortcut]?) -> Void) {
        let runner = runner
        queue.async {
            let found = runner.list().map(ShortcutList.parse)
            DispatchQueue.main.async { done(found) }
        }
    }

    /// Whether the shortcut `id` is still listed, for the sheet's line; nil when the list couldn't be read.
    static func isListed(_ id: String, done: @escaping (Bool?) -> Void) {
        list { found in done(found.map { ShortcutList.isListed(id, in: $0) }) }
    }

    /// Runs the shortcut with the task's text as its input. The Add the user pressed is the confirmation.
    static func send(_ task: Task, done: @escaping (Outcome) -> Void) {
        guard let arguments = ShortcutList.runArguments(id: task.id) else {
            return done(outcome(ShortcutList.line(.couldntStart, name: task.name)))
        }
        let stop = ShortcutStop()
        current = stop
        let runner = runner
        let limit = limit
        queue.async {
            let result = runner.run(arguments: arguments, input: Data(task.input.utf8), limit: limit, stop: stop)
            let line = ShortcutList.line(result, name: task.name)
            if case .sent = line { record(task) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if current === stop { current = nil }
                    done(outcome(line))
                }
            }
        }
    }

    /// Cancel: stops the run in progress, if any.
    static func stop() {
        current?.set()
    }

    private static func outcome(_ line: ShortcutList.Line) -> Outcome {
        switch line {
        case .sent(let text): return .sent(text)
        case .failed(let text): return .failed(text)
        case .stopped(let text): return .stopped(text)
        }
    }

    /// On the queue. The title is the input's first line, masked again by the record.
    nonisolated private static func record(_ task: Task) {
        let title = ShortcutList.title(ofInput: task.input)
        let entry = TaskRecord.Entry(at: Date(), kind: .shortcut, key: task.id, title: title,
                                     slug: TodoFile.slug(title), project: task.project, waited: false)
        TaskRecordStore.shared.record(entry)
    }

    #if DEBUG
    /// The self-test's runner and time limit: set, no command starts and no shortcut of the user's runs.
    nonisolated(unsafe) static var fake: FakeShortcutRunner?
    nonisolated(unsafe) static var fakeLimit: TimeInterval?

    /// Runs `body` on the runner's queue once it is idle.
    nonisolated static func quiet<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
    #endif
}
