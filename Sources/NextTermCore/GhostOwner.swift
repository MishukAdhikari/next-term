import Foundation

/// Who draws suggestions while typing in a zsh, from the ghost hook's `ghost` mark and the line it reports: never two at
/// once. Where zsh-autosuggestions draws its own (Atuin's suggestions come through it), Next Term draws none until the user
/// chooses, and asks once; where something Next Term doesn't know sets POSTDISPLAY, it draws none and asks nothing.
public enum GhostOwner {
    public struct Plugin: Equatable, Hashable, Sendable {
        /// What the choice is remembered by.
        public let id: String
        /// What the question calls it: "zsh-autosuggestions", "Atuin’s suggestions".
        public let name: String
        /// What the tab's tooltip and Settings call it.
        public let label: String

        public init(id: String, name: String, label: String) {
            self.id = id
            self.name = name
            self.label = label
        }

        public static let autosuggestions = Plugin(id: "zsh-autosuggestions", name: "zsh-autosuggestions", label: "zsh-autosuggestions")
        public static let atuin = Plugin(id: "atuin", name: "Atuin’s suggestions", label: "Atuin")
        /// A ghost on the line from a plugin Next Term doesn't know: left alone.
        public static let unknown = Plugin(id: "unknown", name: "a plugin", label: "a plugin")

        /// A remembered id back as a plugin, for Settings; nil for one this version doesn't know.
        public init?(id: String) {
            guard let known = [Self.autosuggestions, Self.atuin].first(where: { $0.id == id }) else { return nil }
            self = known
        }

        /// Next Term can turn its suggestions off in its own tabs, and back on (zsh-autosuggestions' own widgets).
        public var canTakeOver: Bool { self != .unknown }
    }

    /// The plugin a shell has that Next Term can stand in for, drawing now or not: zsh-autosuggestions, or Atuin's
    /// suggestions where ZSH_AUTOSUGGEST_STRATEGY names atuin and the plugin is loaded (Atuin sets the variable without it).
    public static func loaded(_ hook: GhostProtocol.Hook) -> Plugin? {
        guard hook.plugin == Plugin.autosuggestions.id else { return nil }
        return hook.strategies.contains("atuin") ? .atuin : .autosuggestions
    }

    /// Who draws suggestions now: the plugin, loaded and on; an unknown one, when the line has a ghost (POSTDISPLAY, or
    /// one too long to send) while none is on; nil, nobody.
    public static func owner(hook: GhostProtocol.Hook?, report: GhostProtocol.BufferReport?) -> Plugin? {
        if let hook, hook.enabled, let plugin = loaded(hook) { return plugin }
        guard let report, report.postdisplay?.isEmpty != true else { return nil }
        return .unknown
    }

    // MARK: the choice

    public enum Answer: Equatable, Sendable {
        case nextTerm
        case plugin
        case ask
    }

    /// Who shows suggestions where `plugin` draws its own: the choice remembered (`nextTermChosen`); else the plugin's,
    /// until the next launch, after a Not Now; else ask. A plugin Next Term doesn't know keeps them, with no question.
    public static func answer(for plugin: Plugin, nextTermChosen: Bool?, dismissedThisLaunch: Bool) -> Answer {
        guard plugin.canTakeOver else { return .plugin }
        if let nextTermChosen { return nextTermChosen ? .nextTerm : .plugin }
        return dismissedThisLaunch ? .plugin : .ask
    }

    /// Not Now for the `count`th time: the second is for good (the plugin's, remembered).
    public static func notNowIsForGood(count: Int) -> Bool { count >= 2 }

    /// How long after a key the question waits: never while you type.
    public static let quietAfterKey: TimeInterval = 1

    /// Whether the question may come now: once a launch in a tab, at an idle prompt (an empty line, after a command ended
    /// there), no key for `quietAfterKey`, and only while the answer is still to ask.
    public static func mayAsk(answer: Answer, askedBefore: Bool, lineEmpty: Bool, afterCommand: Bool, sinceKey: TimeInterval) -> Bool {
        answer == .ask && !askedBefore && lineEmpty && afterCommand && sinceKey >= quietAfterKey
    }

    /// What a new tab's shell is told (the integration's NEXTTERM_GHOST), from the answers for each plugin: `t`,
    /// zsh-autosuggestions' own suggestions go off at its first line; `a`, the same where they are Atuin's. nil: neither.
    public static func startValue(autosuggestions: Answer, atuin: Answer) -> String? {
        let value = (autosuggestions == .nextTerm ? "t" : "") + (atuin == .nextTerm ? "a" : "")
        return value.isEmpty ? nil : value
    }
}
