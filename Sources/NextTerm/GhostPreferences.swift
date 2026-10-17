import Foundation
import NextTermCore

/// Suggestions while typing: whether they are on, View › Private Mode, and who shows them where zsh-autosuggestions draws
/// its own (Atuin's through it), remembered on this Mac by plugin with Tab completion's rules (GhostOwner).
enum GhostPreferences {
    /// Next Term suggests while you type, and keeps the record of your commands it suggests from (CommandHistoryStore).
    /// Off until Settings can turn it off.
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

    /// A choice made, or the question asked again, here or in Settings; or suggestions turned on or off.
    static let changed = Notification.Name("NextTermGhostTextChanged")
}

// MARK: plugins that draw their own

extension GhostPreferences {
    static let choicesKey = "ghostTextPluginChoices"
    static let dismissalsKey = "ghostTextPluginDismissals"
    /// Plugins whose question was closed with Not Now since launch: they keep suggestions until the next launch.
    nonisolated(unsafe) static var dismissedThisLaunch: Set<String> = []

    static func answer(for plugin: GhostOwner.Plugin) -> GhostOwner.Answer {
        let chosen = choice(for: plugin).map { $0 == .nextTerm }
        return GhostOwner.answer(for: plugin, nextTermChosen: chosen, dismissedThisLaunch: dismissedThisLaunch.contains(plugin.id))
    }

    static func choice(for plugin: GhostOwner.Plugin) -> PluginChoice? {
        (UserDefaults.standard.dictionary(forKey: choicesKey)?[plugin.id] as? String).flatMap(PluginChoice.init(rawValue:))
    }

    /// Remembers `choice` for `plugin`; nil asks again (Settings' Ask Again), dismissals forgotten too.
    static func choose(_ choice: PluginChoice?, for plugin: GhostOwner.Plugin) {
        var choices = UserDefaults.standard.dictionary(forKey: choicesKey) ?? [:]
        choices[plugin.id] = choice?.rawValue
        UserDefaults.standard.set(choices, forKey: choicesKey)
        if choice == nil {
            var dismissals = UserDefaults.standard.dictionary(forKey: dismissalsKey) ?? [:]
            dismissals[plugin.id] = nil
            UserDefaults.standard.set(dismissals, forKey: dismissalsKey)
            dismissedThisLaunch.remove(plugin.id)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Not Now: the plugin keeps suggestions until Next Term starts again; the second time, for good.
    static func dismissed(_ plugin: GhostOwner.Plugin) {
        var dismissals = UserDefaults.standard.dictionary(forKey: dismissalsKey) ?? [:]
        let count = (dismissals[plugin.id] as? Int ?? 0) + 1
        dismissals[plugin.id] = count
        UserDefaults.standard.set(dismissals, forKey: dismissalsKey)
        if GhostOwner.notNowIsForGood(count: count) {
            choose(.plugin, for: plugin)
        } else {
            dismissedThisLaunch.insert(plugin.id)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The choices remembered, for Settings: by plugin, and whether two Not Nows made it.
    static var remembered: [(plugin: GhostOwner.Plugin, choice: PluginChoice, byDismissal: Bool)] {
        let choices = UserDefaults.standard.dictionary(forKey: choicesKey) ?? [:]
        let dismissals = UserDefaults.standard.dictionary(forKey: dismissalsKey) ?? [:]
        return choices.keys.sorted().compactMap { id in
            guard let plugin = GhostOwner.Plugin(id: id), let choice = (choices[id] as? String).flatMap(PluginChoice.init(rawValue:)) else {
                return nil
            }
            let byDismissal = choice == .plugin && GhostOwner.notNowIsForGood(count: dismissals[id] as? Int ?? 0)
            return (plugin, choice, byDismissal)
        }
    }

    /// What a new tab's zsh is told (ShellIntegration.ghostVariable): where Next Term's was chosen, its hook turns
    /// zsh-autosuggestions' suggestions off at the first line. Only while suggestions are on.
    static var startValue: String? {
        guard isOn else { return nil }
        return GhostOwner.startValue(autosuggestions: answer(for: .autosuggestions), atuin: answer(for: .atuin))
    }
}
