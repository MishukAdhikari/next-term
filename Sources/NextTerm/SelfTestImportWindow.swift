import AppKit
import NextTermCore

/// The import window's chooser as one list grouped by kind of app: editors, then terminals, each app with its version
/// or "app removed", when it was last used and what it can bring; then keeping Next Term's shortcuts; then, folded,
/// the apps not used lately (open when they are all there is). The apps are made up (the detectors are swapped for a
/// list, so nothing on this Mac is read); no key is typed, so these run whether or not the app is in front. The
/// detectors are put back as they were.
extension SelfTest {
    static func importWindowChecks() async {
        guard AppDelegate.shared != nil else { return note("import window grouped by kind of app: skipped, no app") }
        let detectors = ImportSources.detectors
        let window = ImportWindowController.shared
        defer {
            window.window?.close()
            ImportSources.detectors = detectors
        }
        let day: TimeInterval = 86400
        let now = Date()
        let fork = DetectedApp(kind: .vsCodeFork, name: "NT Removed Fork", configPath: "/nonexistent/fork/User",
                               lastUsed: now.addingTimeInterval(-3 * day))
        let zed = DetectedApp(kind: .zed, name: "Zed", configPath: "/nonexistent/zed", lastUsed: now.addingTimeInterval(-2 * day),
                              appPath: "/nonexistent/Zed.app", version: "0.205.1")
        let kitty = DetectedApp(kind: .kitty, name: "kitty", configPath: "/nonexistent/kitty.conf", lastUsed: now.addingTimeInterval(-1 * day),
                                appPath: "/nonexistent/kitty.app", version: "0.43.1")
        let stale = DetectedApp(kind: .jetBrains, name: "NT Stale IDE 2024.1", configPath: "/nonexistent/ide",
                                lastUsed: now.addingTimeInterval(-300 * day), appPath: "/nonexistent/IDE.app", version: "2024.1.4")
        ImportSources.detectors = [{ [fork, zed, kitty, stale] }]

        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        let texts = importWindowTexts(window)
        let shown = texts.joined(separator: " | ")
        func position(_ prefix: String) -> Int { texts.firstIndex { $0.hasPrefix(prefix) } ?? -1 }
        let order = ["EDITORS", "Zed", "NT Removed Fork", "TERMINALS", "kitty", "Keep Next Term’s shortcuts", "NOT USED LATELY (1)",
                     "NT Stale IDE 2024.1"].map(position)
        check(!order.contains(-1) && order == order.sorted(),
              "the chooser lists editors, then terminals, then keeping Next Term's, then the apps not used lately", shown)
        check(texts.contains { $0.hasPrefix("app removed  ·  used 3 days ago  ·  brings shortcuts, settings") },
              "an editor whose app was removed is tagged app removed", shown)
        check(texts.contains("0.205.1  ·  used 2 days ago  ·  brings shortcuts, settings, fonts and projects"),
              "each app shows its version, when it was used and what it can bring", shown)
        check(window.chosenTitle == "kitty" && !window.staleListIsOpen,
              "the app used last is chosen, and the apps not used lately start folded", window.chosenTitle ?? "none")
        if let disclosure = Self.disclosure(in: window) {
            disclosure.performClick(nil)
            check(window.staleListIsOpen, "the disclosure shows the apps not used lately")
        } else {
            check(false, "the apps not used lately have a disclosure", shown)
        }
        window.window?.close()

        // Every app not used lately: the folded list starts open, its newest chosen.
        ImportSources.detectors = [{ [stale] }]
        window.showChooser(firstRun: false, completion: nil)
        await pause(0.3)
        check(window.chosenTitle == "NT Stale IDE 2024.1" && window.staleListIsOpen,
              "with only apps not used lately, their list is open and the newest chosen", window.chosenTitle ?? "none")
    }

    /// The chooser's disclosure button (the apps not used lately).
    private static func disclosure(in window: ImportWindowController) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.bezelStyle == .disclosure { return button }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.window?.contentView.flatMap(find)
    }
}
