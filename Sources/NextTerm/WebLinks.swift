import AppKit
import NextTermCore

/// A web link ⌘-clicked in the terminal (or opened from its right-click menu): in the default browser, except
/// LangGraph Studio's, which open in Chrome, Edge, Brave or Arc when Safari is the default (StudioLink), since
/// Safari won't let Studio reach the server on this Mac. Without any of them, Safari, with a note once.
enum WebLinks {
    static let studioKey = "studioLinksInChromium"
    static let noteKey = "studioSafariNoteShown"

    /// Settings › Terminal: Studio links in a Chromium browser. On by default.
    static var studioInChromium: Bool {
        get { UserDefaults.standard.object(forKey: studioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: studioKey) }
    }

    /// What `open` would do with `url` on this Mac now.
    static func choice(for url: URL) -> StudioLink.Choice {
        let browser = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
        return StudioLink.choice(for: url, defaultBrowser: browser, installed: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                                 enabled: studioInChromium)
    }

    static func open(_ url: URL, from window: NSWindow?) {
        switch choice(for: url) {
        case .defaultBrowser:
            NSWorkspace.shared.open(url)
        case .browser(let id):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                NSWorkspace.shared.open(url)
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                // It could not start: the default browser, as any link.
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
        case .safariWithNote:
            guard !UserDefaults.standard.bool(forKey: noteKey) else {
                NSWorkspace.shared.open(url)
                return
            }
            UserDefaults.standard.set(true, forKey: noteKey)
            let alert = NSAlert()
            alert.messageText = "LangGraph Studio may not load in Safari"
            alert.informativeText = "Studio is a web page that talks to the server on your Mac, and Safari blocks that, so Studio "
                + "can say “Failed to load assistants”. With Chrome, Edge, Brave or Arc installed, Next Term opens Studio links there. "
                + "Or start the server with “langgraph dev --tunnel”. This note is shown once."
            alert.addButton(withTitle: "Open in Safari")
            let open: (NSApplication.ModalResponse) -> Void = { _ in NSWorkspace.shared.open(url) }
            if let window { alert.beginSheetModal(for: window, completionHandler: open) } else { open(alert.runModal()) }
        }
    }
}

/// Settings › Terminal's switch for Studio links (WebLinks.studioInChromium).
final class StudioLinksCheckbox: NSButton {
    static func make() -> StudioLinksCheckbox {
        let box = StudioLinksCheckbox(checkboxWithTitle: "Open LangGraph Studio links in Chrome, Edge, Brave or Arc when Safari is the default browser",
                                      target: nil, action: nil)
        box.target = box
        box.action = #selector(toggled)
        box.toolTip = "Safari won’t let Studio reach the server on your Mac (langgraph dev), so a ⌘-click on a Studio link opens it in the first of these that is installed."
        box.state = WebLinks.studioInChromium ? .on : .off
        return box
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        state = WebLinks.studioInChromium ? .on : .off
    }

    @objc private func toggled() { WebLinks.studioInChromium = state == .on }
}
