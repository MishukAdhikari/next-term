import Foundation

/// Tab completion's switch. Hidden and off by default while only the line report ships: the self-test
/// turns it on (`defaults write` too). A shell loads the hook only when it is on as the shell starts.
enum CompletionPreferences {
    static let previewKey = "tabCompletionPreview"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: previewKey) }
        set { UserDefaults.standard.set(newValue, forKey: previewKey) }
    }
}
