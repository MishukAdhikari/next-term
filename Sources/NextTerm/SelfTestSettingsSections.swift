import AppKit

/// Settings, section by section, as the user sees it: a screenshot of each of the eleven, the window's frame the same in
/// every one, nothing cut off; and Settings over a project window in full screen, never full screen itself.
extension SelfTest {
    static func settingsSectionsChecks(_ c: TerminalWindowController) async {
        AppDelegate.shared.showSettings(tab: "general")
        guard await wait(3, { AppDelegate.shared.openSettings?.window?.isVisible == true }),
              let shown = AppDelegate.shared.openSettings, let window = shown.window else {
            return check(false, "settings sections: Settings opens")
        }
        let steady = window.frame
        var problems: [String] = []
        for section in SettingsWindowController.sections {
            shown.showTab(section.id)
            window.layoutIfNeeded()
            if window.frame != steady { problems.append("\(section.label) moved or resized the window to \(window.frame)") }
            if let cut = settingsSectionCutOff(in: window) { problems.append("\(section.label): \(cut)") }
            await screenshot(window, suffix: "-settings-\(section.id)")
        }
        check(problems.isEmpty, "settings sections: each of the eleven at the window's one size, nothing cut off",
              problems.joined(separator: "; "))
        note("settings sections: the window is \(Int(steady.width)) × \(Int(steady.height)) pt")

        // Full screen is the project window's alone: Settings zooms at most.
        window.toggleFullScreen(nil)
        await pause(1.5)
        check(!window.styleMask.contains(.fullScreen) && window.frame.height <= (window.screen?.frame.height ?? .greatestFiniteMagnitude),
              "settings sections: Settings never enters full screen", "\(window.styleMask.rawValue)")
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            _ = await wait(4) { !window.styleMask.contains(.fullScreen) }
        }
        window.close()

        // A project window in full screen, then Settings: it opens over it, in its space, at its own size.
        guard let project = c.window else { return check(false, "settings sections: the project window is there") }
        project.makeKeyAndOrderFront(nil)
        project.toggleFullScreen(nil)
        let entered = await wait(8) { project.styleMask.contains(.fullScreen) }
        check(entered, "settings sections: the project window enters full screen", "\(project.styleMask.rawValue)")
        await pause(0.8)
        AppDelegate.shared.showSettings(tab: "general")
        _ = await wait(3) { window.isVisible }
        await pause(1)
        check(window.isVisible && window.isOnActiveSpace && project.isOnActiveSpace && project.styleMask.contains(.fullScreen)
              && !window.styleMask.contains(.fullScreen) && window.frame.size == steady.size,
              "settings sections: Settings opens over the full-screen window, in its space, at its own size",
              "on active space \(window.isOnActiveSpace), project \(project.isOnActiveSpace), frame \(window.frame)")
        window.toggleFullScreen(nil)
        await pause(1.5)
        check(!window.styleMask.contains(.fullScreen) && project.styleMask.contains(.fullScreen) && window.isOnActiveSpace,
              "settings sections: over a full-screen window, Settings still never goes full screen itself")
        await screenSnapshot(of: project, suffix: "-settings-over-full-screen")
        window.close()
        project.toggleFullScreen(nil)
        let left = await wait(8) { !project.styleMask.contains(.fullScreen) }
        check(left, "settings sections: the project window leaves full screen again")
        await pause(1)
    }

    /// The whole screen `window` is on, with every window of Next Term's in it (another app's show only with Screen
    /// Recording allowed), for a screenshot of one window over another.
    static func screenSnapshot(of window: NSWindow, suffix: String) async {
        guard let base = reportPath, let screen = window.screen else { return }
        await pause(0.4)
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let flipped = CGRect(x: screen.frame.minX, y: primary - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        guard let image = CGWindowListCreateImage(flipped, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            return note("screen snapshot failed")
        }
        let path = (base as NSString).deletingPathExtension + suffix + ".png"
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        note("screenshot: \(path)")
    }
}
