import AppKit
import NextTermCore

/// The windows open as an update's quit began (BeforeUpdate), kept in the sessions folder until the relaunch has shown them
/// all back. After a relaunch: every one back, the copy goes 5 minutes later; some missing, a notice says how many and
/// offers to reopen them, as File › Reopen Windows from Before the Update and the reopen_before_update tool do.
@MainActor
enum BeforeUpdateControl {
    /// Posted when what can be reopened changed (the menu item follows it).
    nonisolated static let changed = Notification.Name("NextTermBeforeUpdateChanged")
    /// The saved windows not open now, as last checked.
    private(set) static var missing: [SessionSnapshot.Window] = []
    private static var cleanup: DispatchWorkItem?

    /// The update's quit: the windows as they are now, beside the session's own file, which later saves overwrite.
    static func save(_ windows: [SessionSnapshot.Window], in files: SessionFiles) {
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 0, clean: false, savedAt: Date())
        guard let data = try? SessionSnapshot(header: header, windows: windows).encoded() else { return }
        try? files.replace(BeforeUpdate.fileName, with: data)
    }

    /// After a launch's restore has shown its windows: a day-old copy goes; otherwise the windows not back are found, and
    /// either the copy goes in 5 minutes or a notice offers to reopen them.
    static func launchCheck() {
        guard !SelfTest.isRequested, let files = SessionRestore.shared.files, let snapshot = read(files) else { return }
        if BeforeUpdate.isStale(savedAt: snapshot.header.savedAt, now: Date()) { return forget(files) }
        recheck(snapshot)
        if missing.isEmpty {
            let work = DispatchWorkItem { forget(files) }
            cleanup = work
            DispatchQueue.main.asyncAfter(deadline: .now() + BeforeUpdate.keptFor, execute: work)
            return
        }
        let count = missing.count
        GitToast.whenFree {
            guard let window = TerminalWindow.front ?? NSApp.keyWindow else { return }
            GitToast.show("\(count) window\(count == 1 ? "" : "s") from before the update didn’t reopen.", in: window,
                          button: "Reopen", action: { _ = reopen() })
        }
    }

    /// Reopens the windows not back, each with a tab for each of its tabs on this Mac, in their folders and with the titles
    /// given them; windows that were merged into one are merged again. Returns how many windows opened. Once none is
    /// missing, the copy goes 5 minutes later.
    @discardableResult
    static func reopen() -> Int {
        guard let files = SessionRestore.shared.files, let snapshot = read(files) else { return 0 }
        recheck(snapshot)
        let app: AppDelegate = AppDelegate.shared
        var opened: [(controller: TerminalWindowController, group: Int?)] = []
        for window in missing {
            let panes: [SessionSnapshot.Pane] = window.groups.compactMap { $0.root.panes.first }.filter { $0.remote == nil }
            let first: String = window.project ?? panes.first?.folder ?? NSHomeDirectory()
            let controller: TerminalWindowController = window.project != nil
                ? app.openFolder(first, newWindow: true) : app.openWindow(directory: first)
            for (index, pane) in panes.enumerated() {
                let tab: TerminalTab = index == 0 ? (controller.tabs.first ?? controller.addTab(directory: pane.folder, select: false))
                    : controller.addTab(directory: pane.folder ?? first, select: false)
                if let title = pane.userTitle { tab.userTitle = title }
            }
            controller.refresh()
            opened.append((controller, window.windowTab?.group))
        }
        // Merged before the update, merged again.
        for group in Set(opened.compactMap(\.group)) {
            let members: [NSWindow] = opened.filter { $0.group == group }.compactMap { $0.controller.window }
            guard let host = members.first else { continue }
            for member in members.dropFirst() { host.addTabbedWindow(member, ordered: .above) }
        }
        recheck(snapshot)
        if missing.isEmpty {
            let work = DispatchWorkItem { forget(files) }
            cleanup?.cancel()
            cleanup = work
            DispatchQueue.main.asyncAfter(deadline: .now() + BeforeUpdate.keptFor, execute: work)
        }
        return opened.count
    }

    /// The saved windows not open now, read again (the reopen tool and the menu item).
    static func missingNow() -> [SessionSnapshot.Window] {
        guard let files = SessionRestore.shared.files, let snapshot = read(files) else { return [] }
        recheck(snapshot)
        return missing
    }

    private static func read(_ files: SessionFiles) -> SessionSnapshot? {
        guard let data = try? files.read(BeforeUpdate.fileName, maxSize: SessionSnapshot.Limits.standard.bytes) else { return nil }
        return try? SessionSnapshot.decode(data)
    }

    private static func recheck(_ snapshot: SessionSnapshot) {
        let open: [BeforeUpdate.Open] = AppDelegate.shared.controllers.filter { !$0.hasClosed }.map { controller in
            BeforeUpdate.Open(project: controller.project, folders: controller.tabs.filter { $0.remote == nil }.map(\.directory))
        }
        missing = BeforeUpdate.missing(saved: snapshot.windows, open: open).map { snapshot.windows[$0] }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func forget(_ files: SessionFiles) {
        try? files.remove(BeforeUpdate.fileName)
        missing = []
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
