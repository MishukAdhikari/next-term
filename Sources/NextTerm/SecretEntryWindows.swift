import AppKit

/// The windows a key's value is typed or pasted in: request_secret's window, Window › Secrets and Settings (Settings ›
/// Secrets' add and edit sheet, and the other fields there), with any sheet on them. While the user is in one, a
/// window an agent opens never becomes the key window (Arrival's raise): a ⌘V or a Return meant for the value would
/// land in that window's editor or in the user's own prompt, where nothing masks a key not stored yet.
@MainActor
enum SecretEntryWindows {
    /// The entry window the user is in: Next Term's key window, or, with another app in front, Next Term's front
    /// window (the one they come back to). A sheet counts as the window it is on. Nil when they are elsewhere.
    static var current: NSWindow? {
        let window = NSApp.keyWindow ?? (NSApp.isActive ? nil : NSApp.orderedWindows.first { $0.isVisible && !$0.isMiniaturized })
        guard var top = window else { return nil }
        while let parent = top.sheetParent { top = parent }
        return isEntry(top) ? top : nil
    }

    static func isEntry(_ window: NSWindow) -> Bool {
        let controller = window.windowController
        return controller is SecretRequestWindow || controller is SecretsWindowController || controller is SettingsWindowController
    }
}
