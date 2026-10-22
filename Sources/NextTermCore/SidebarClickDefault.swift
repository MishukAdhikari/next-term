import Foundation

/// "Open files and folders with a single click" on a new install, and what an existing install had on one that never
/// chose: decided once, at the first launch that has this code, and stored, so a later change to the default never
/// changes it for anyone.
extension SidebarClick {
    /// The setting, in the app's defaults. Never written means off.
    public static let settingKey = "sidebarSingleClickOpens"

    /// Keys an install that has been used before holds, whatever was chosen. This list must only ever grow: a key taken
    /// out would make an install that has only it look new.
    /// - `sessionProjects`: written at every clean quit (an update's relaunch too), since 0.1.0; an empty list counts.
    /// - `recentProjects`: written when a folder opens.
    /// - `lastUpdateCheck`, `lastUpdateFailure`: written about 20 seconds into a launch with automatic update checks on,
    ///   as they are unless turned off.
    /// - `importOffered`: written when "Coming from another app?" has been shown.
    static let usedInstallKeys = ["sessionProjects", "recentProjects", "lastUpdateCheck", "lastUpdateFailure", "importOffered"]

    /// What to store, if anything: nothing when a value is stored already, on for a new install, and off (what it has
    /// had) for one used before.
    public static func firstLaunchValue(stored: Bool?, usedBefore: Bool) -> Bool? {
        stored == nil ? !usedBefore : nil
    }

    /// Stores the setting's value for a new install (on) or an existing one that never chose (off), and returns what
    /// it stored; nil when a value was there already, which it never touches. Runs before the launch writes any of
    /// `usedInstallKeys`.
    @discardableResult
    public static func settleDefault(in defaults: UserDefaults) -> Bool? {
        let stored = defaults.object(forKey: settingKey) == nil ? nil : defaults.bool(forKey: settingKey)
        let usedBefore = usedInstallKeys.contains { defaults.object(forKey: $0) != nil }
        guard let value = firstLaunchValue(stored: stored, usedBefore: usedBefore) else { return nil }
        defaults.set(value, forKey: settingKey)
        return value
    }
}
