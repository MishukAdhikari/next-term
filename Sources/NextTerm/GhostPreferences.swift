import Foundation
import NextTermCore

/// Suggestions while typing: whether they are on, and View › Private Mode.
enum GhostPreferences {
    /// Next Term suggests while you type, and keeps the record of your commands it suggests from (CommandHistoryStore).
    /// Off until it can stand down where zsh-autosuggestions draws its own, and Settings can turn it off.
    static var isOn: Bool {
        #if DEBUG
        if let testIsOn { return testIsOn }
        #endif
        return false
    }

    #if DEBUG
    /// The self-test's switch, over the setting.
    nonisolated(unsafe) static var testIsOn: Bool?
    #endif

    /// No suggestion shows and nothing is recorded, until it is turned off or Next Term quits: never stored.
    nonisolated(unsafe) static var privateMode = false

    /// Your commands are recorded now.
    static var records: Bool { isOn && !privateMode }
}
