import Foundation
import NextTermCore

/// Who answers Tab at a shell prompt (Settings › Terminal › Tab completion).
enum TabCompletionMode: String, CaseIterable {
    /// Next Term's popup, unless a plugin owns Tab; then Next Term asks once.
    case auto
    /// Next Term's popup wherever the hook is, with no question.
    case nextTerm
    /// The shell's own Tab, as before.
    case off

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .nextTerm: return "Next Term"
        case .off: return "Off"
        }
    }
}

/// Tab completion's settings, for this Mac. A shell loads the hook only when Tab completion is on as it starts:
/// turning it on reaches new tabs; turning it off works at once everywhere (the window stops converting Tab).
enum CompletionPreferences {
    static let modeKey = "tabCompletion"

    /// An unknown stored value reads as Auto.
    static var mode: TabCompletionMode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(TabCompletionMode.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var isOn: Bool { mode != .off }
}

/// What the user chose where a plugin owns Tab (CompletionOwner), remembered on this Mac by plugin.
enum PluginChoice: String {
    /// Next Term's list answers Tab (and zsh-autocomplete's list as you type is off in Next Term's tabs).
    case nextTerm
    /// The plugin keeps Tab.
    case plugin
}

extension CompletionPreferences {
    static let choicesKey = "tabCompletionPluginChoices"
    static let dismissalsKey = "tabCompletionPluginDismissals"
    /// A choice made, or the question asked again, here or in Settings.
    static let changed = Notification.Name("NextTermTabCompletionChanged")
    /// Plugins whose question was closed with Not Now since launch: they keep Tab until the next launch.
    nonisolated(unsafe) static var dismissedThisLaunch: Set<String> = []

    /// Who answers a real Tab in a shell where `plugin` owns it.
    enum Answer {
        case nextTerm
        case plugin
        case ask
    }

    static func answer(for plugin: CompletionOwner.Plugin) -> Answer {
        if mode == .nextTerm { return .nextTerm }
        switch choice(for: plugin) {
        case .nextTerm: return .nextTerm
        case .plugin: return .plugin
        case nil: return dismissedThisLaunch.contains(plugin.id) ? .plugin : .ask
        }
    }

    static func choice(for plugin: CompletionOwner.Plugin) -> PluginChoice? {
        (UserDefaults.standard.dictionary(forKey: choicesKey)?[plugin.id] as? String).flatMap(PluginChoice.init(rawValue:))
    }

    /// Remembers `choice` for `plugin`; nil asks again (Settings' Ask Again), dismissals forgotten too.
    static func choose(_ choice: PluginChoice?, for plugin: CompletionOwner.Plugin) {
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

    /// Not Now, or Esc: the plugin keeps Tab until Next Term starts again; the second time, for good.
    static func dismissed(_ plugin: CompletionOwner.Plugin) {
        var dismissals = UserDefaults.standard.dictionary(forKey: dismissalsKey) ?? [:]
        let count = (dismissals[plugin.id] as? Int ?? 0) + 1
        dismissals[plugin.id] = count
        UserDefaults.standard.set(dismissals, forKey: dismissalsKey)
        if count >= 2 {
            choose(.plugin, for: plugin)
        } else {
            dismissedThisLaunch.insert(plugin.id)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The choices remembered, for Settings: by plugin, and whether two dismissals made it.
    static var remembered: [(plugin: CompletionOwner.Plugin, choice: PluginChoice, byDismissal: Bool)] {
        let choices = UserDefaults.standard.dictionary(forKey: choicesKey) ?? [:]
        let dismissals = UserDefaults.standard.dictionary(forKey: dismissalsKey) ?? [:]
        return choices.keys.sorted().compactMap { id in
            guard let choice = (choices[id] as? String).flatMap(PluginChoice.init(rawValue:)) else { return nil }
            let byDismissal = choice == .plugin && (dismissals[id] as? Int ?? 0) >= 2
            return (CompletionOwner.Plugin(id: id), choice, byDismissal)
        }
    }

    /// zsh-autocomplete's list as you type is off in Next Term's tabs: Next Term's list answers Tab there.
    static var quietsAutocomplete: Bool {
        mode != .off && answer(for: .autocomplete) == .nextTerm
    }
}

/// Suggest a Command (Settings › Terminal): off by default; on, it asks an agent of the user's own (by its adapter's
/// id) or Apple's on-device model, and only when the user submits a sentence. Next Term has no AI of its own: this
/// only says whose to ask.
extension CompletionPreferences {
    static let suggestionKey = "commandSuggestion"
    static let onDevice = "on-device"

    /// nil: off. An unknown stored value is off too.
    static var suggestion: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: suggestionKey) else { return nil }
            return value == onDevice || CommandSuggestion.adapter(value) != nil ? value : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: suggestionKey) } else { UserDefaults.standard.removeObject(forKey: suggestionKey) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Who answers, for a person: "Claude Code", "Apple’s on-device model".
    static func suggestionName(_ choice: String) -> String {
        choice == onDevice ? "Apple’s on-device model" : CommandSuggestion.adapter(choice)?.name ?? choice
    }
}
