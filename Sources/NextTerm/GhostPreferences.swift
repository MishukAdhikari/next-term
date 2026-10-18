import Foundation
import NextTermCore

/// Suggestions while typing: whether they are on, View › Private Mode, and who shows them where zsh-autosuggestions draws
/// its own (Atuin's through it), remembered on this Mac by plugin with Tab completion's rules (GhostOwner).
enum GhostPreferences {
    static let onKey = "ghostText"

    /// Next Term suggests while you type, and keeps the record of your commands it suggests from (CommandHistoryStore).
    /// On by default (Settings › Terminal › While typing, or the first-use hint's Turn Off).
    static var isOn: Bool {
        if let testIsOn { return testIsOn }
        return UserDefaults.standard.object(forKey: onKey) as? Bool ?? true
    }

    /// The self-test's switch, over the setting: off for every part of it but suggestions' own, so a key another part
    /// presses (→, End) does what it always did. Never set outside the self-test.
    nonisolated(unsafe) static var testIsOn: Bool?

    /// Turns suggestions on or off: off, every suggestion and notice goes at once, nothing more is recorded, and a plugin's
    /// suggestions Next Term turned off come back; on, Next Term's show again. Tabs open now keep their hook, which only
    /// reports.
    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: onKey)
        if testIsOn != nil { testIsOn = on }
        GhostSession.syncAll()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// View › Private Mode: no suggestion shows and nothing is recorded, until it is turned off or Next Term quits. Never
    /// stored, so a new launch starts without it.
    nonisolated(unsafe) private(set) static var privateMode = false

    static func setPrivateMode(_ on: Bool) {
        privateMode = on
        GhostSession.syncAll()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Your commands are recorded now.
    static var records: Bool { isOn && !privateMode }

    /// A choice made, or the question asked again, here or in Settings; or suggestions turned on or off.
    static let changed = Notification.Name("NextTermGhostTextChanged")

    // MARK: VoiceOver

    static let voiceOverKey = "ghostTextVoiceOver"

    /// What VoiceOver says of a new suggestion: the whole command and "→ accepts" (the default), only "Suggestion,
    /// → accepts", or nothing.
    static var voiceOverWords: GhostAnnouncer.Words {
        get { UserDefaults.standard.string(forKey: voiceOverKey).flatMap(GhostAnnouncer.Words.init(rawValue:)) ?? .whole }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: voiceOverKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: the first-use hint

    static let hintsKey = "ghostTextHintsShown"
    /// The hint shows on the first two lines a suggestion shows on, across launches.
    static let hintLines = 2

    static var hintsShown: Int {
        get { UserDefaults.standard.integer(forKey: hintsKey) }
        set { UserDefaults.standard.set(min(newValue, hintLines), forKey: hintsKey) }
    }
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
