import Foundation

// The one mark an agent tab gets when its work and the window disagree: its agent works in another
// checkout of the repository than the window shows (Elsewhere), or the branch its chat was on was switched
// under it. One glyph for both; the words say which. What the tab, the sidebar header, VoiceOver and
// list_tabs say about it. Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R7–R10, R30).

public struct PlaceMark: Equatable, Sendable {
    /// Where the tab's agent works.
    public let place: AgentPlace
    /// The checkout the window shows, when it is one of the same repository.
    public let shown: Checkout?

    /// The agent works in another checkout of the repository than the window shows.
    public var elsewhere: Bool { shown.map { $0.path != place.checkout.path } ?? false }
    /// The branch its chat was on was switched under it.
    public var switched: BranchSwitch? { place.switched }

    /// The mark for `place` in a window that shows `shown` of `shownRepository` (nil: no repository);
    /// nil when there is nothing to mark.
    public static func of(_ place: AgentPlace, shownRepository: String?, shown: Checkout?) -> PlaceMark? {
        let mark = PlaceMark(place: place, shown: shownRepository == place.repository ? shown : nil)
        return mark.elsewhere || mark.switched != nil ? mark : nil
    }

    /// What list_tabs says: "elsewhere", "switched_under", "same" (the window shows its checkout), or
    /// "other_repository" (the window shows another repository, or none).
    public static func sync(_ place: AgentPlace, shownRepository: String?, shown: Checkout?) -> String {
        if let mark = of(place, shownRepository: shownRepository, shown: shown) { return mark.elsewhere ? "elsewhere" : "switched_under" }
        return shownRepository == place.repository && shown != nil ? "same" : "other_repository"
    }

    /// The sidebar header's label when the tab is focused: "this tab: fix/7027-sso", or "chat was on
    /// fix/7611-3ds" after a switch under it.
    public var label: String {
        if elsewhere { return "this tab: " + place.checkout.head.name }
        return "chat was on " + (switched?.from.name ?? "")
    }

    /// The facts, for the tooltip and VoiceOver: the agent, its checkout and branch, what the window shows,
    /// and for a switch, the branch the chat was on, the one now checked out, when and who made it.
    /// `when` says when ("2 min ago").
    public func facts(agent: String, when: (Date) -> String) -> String {
        var lines: [String] = []
        if elsewhere, let shown {
            lines.append("\(agent) works in \(place.checkout.title), \(Self.on(place.checkout.head)). This window shows \(shown.title), \(Self.on(shown.head)).")
        }
        if let switched {
            let now = "The chat was on \(switched.from.name); \(place.checkout.title) is now \(Self.on(switched.to))"
            lines.append(now + ": " + Self.who(switched.by, when: when(switched.at)) + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// "on fix/7027-sso", or "detached at abc1234".
    static func on(_ head: CheckoutHead) -> String {
        if case let .branch(name) = head { return "on " + name }
        return head.name
    }

    /// "you switched it just now", "the agent in the tab “7” switched it 2 min ago".
    static func who(_ author: SwitchAuthor, when: String) -> String {
        switch author {
        case .you: return "you switched it " + when
        case let .tab(_, title): return "the tab “\(title)” switched it " + when
        case let .agent(_, title): return "the agent in the tab “\(title)” switched it " + when
        case let .unknown(working) where working > 1: return "it was switched \(when), while \(working) agents were working there"
        case .unknown: return "it was switched \(when); Next Term can’t tell by whom"
        }
    }
}
