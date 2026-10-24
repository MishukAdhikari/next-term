import AppKit
import NextTermCore

/// The one way a task link opens: Things' add, Todoist's or OmniFocus's Quick Add in that vendor's own app, or a
/// tracker's new-issue page in the browser the user's other links use. The link is checked again (`TaskLink`): links
/// are built valid, so a refusal can only be a bug, met with a beep and nothing opened. An app link opens only in the
/// app that handles its scheme, and only when that app's bundle id is the vendor's, so another app that claims the
/// scheme never gets the task. A message never quotes the link or the task, and nothing is logged.
@MainActor
enum TaskOpen {
    enum Outcome: Equatable {
        case opened
        /// It did not open; the message says so and that nothing was sent.
        case failed(String)
    }

    /// `done` is called on the main thread once the link opened or did not.
    static func open(_ url: URL, from window: NSWindow?, done: @escaping (Outcome) -> Void) {
        guard let kind = TaskLink.check(url) else {
            NSSound.beep()
            return done(.failed("The link was refused. Nothing was sent."))
        }
        #if DEBUG
        if recordsOnly {
            opened.append(url)
            return done(.opened)
        }
        #endif
        guard kind.isApp else {
            guard SafeWebLink.isAllowed(url) else {
                NSSound.beep()
                return done(.failed("The link was refused. Nothing was sent."))
            }
            WebLinks.open(url, from: window)
            return done(.opened)
        }
        guard let app = handler(for: url, kind: kind) else {
            return done(.failed("\(kind.name) isn’t installed. Nothing was sent."))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let firstToThings = kind == .things && !TaskSettings(defaults: .standard).notesShown.contains(.thingsOpened)
        // Things saves without a window, but the first link asks whether to enable Things URLs: it comes forward once.
        configuration.activates = kind.activates || firstToThings
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            // The error can quote the URL it was given: say nothing from it.
            let failed = error != nil
            DispatchQueue.main.async {
                if failed { return done(.failed("\(kind.name) did not open. Nothing was sent.")) }
                if firstToThings { TaskSettings.markShown(.thingsOpened, in: .standard) }
                done(.opened)
            }
        }
    }

    /// A tracker's or an agent's own help page, in the browser, on the user's click. It carries no task, so it isn't a
    /// task link; it is checked as any web link is, and records only during the self-test.
    static func openPage(_ url: URL, from window: NSWindow?) {
        guard url.scheme == "https", SafeWebLink.isAllowed(url) else { return NSSound.beep() }
        #if DEBUG
        if recordsOnly { return opened.append(url) }
        #endif
        WebLinks.open(url, from: window)
    }

    /// System Settings at Privacy & Security, on the user's click: only that one fixed address, and recorded instead
    /// of opened during the self-test.
    static func openSettings(_ url: URL) {
        guard url == RemindersAccess.privacySettings else { return NSSound.beep() }
        #if DEBUG
        if recordsOnly { return opened.append(url) }
        #endif
        NSWorkspace.shared.open(url)
    }

    /// The app is installed: the app that would open its links is the vendor's own. Nothing is launched to ask. A page
    /// needs no app.
    static func installed(_ kind: TaskLink.Kind) -> Bool {
        #if DEBUG
        if let fakeInstalled { return fakeInstalled.contains(kind) }
        #endif
        guard let probe = kind.probe else { return true }
        return handler(for: probe, kind: kind) != nil
    }

    /// The app that would open `url`, when it is the vendor's; resolving it launches nothing.
    static func handler(for url: URL, kind: TaskLink.Kind) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let id = Bundle(url: app)?.bundleIdentifier, TaskLink.isVendor(id, for: kind) else { return nil }
        return app
    }

    #if DEBUG
    /// The self-test turns this on: each link that would open is recorded in `opened`, and nothing opens.
    nonisolated(unsafe) static var recordsOnly = false
    nonisolated(unsafe) static var opened: [URL] = []
    /// The self-test sets which apps count as installed, so a sheet's answer doesn't depend on this Mac; nil: ask.
    nonisolated(unsafe) static var fakeInstalled: Set<TaskLink.Kind>?
    #endif
}
