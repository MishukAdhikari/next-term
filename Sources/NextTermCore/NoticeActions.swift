import Foundation

/// The buttons an agent's notice carries: a decision's choices, four at most ("1 Yes", "2 No"), and Reply on a finish,
/// which sends a line. Each button is the user's own click on a question the notice shows in full, and answers the way
/// answer_agent does (HerdrAnswer), reading the screen again first: a changed question types nothing. A decision with
/// more choices than fit carries none, and a click opens the agent as before.
public enum NoticeActions {
    /// One button: its id (`choice.<n>`, or `reply`) and its title.
    public struct Action: Equatable, Sendable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// The most choices a notice carries as buttons.
    public static let maxChoices = 4
    /// The longest a button's title gets.
    public static let titleLength = 40
    /// The most categories Next Term registers at once: the oldest give way.
    public static let maxCategories = 64
    /// Reply's id, and the shared category of finish notices, which carries it.
    public static let reply = "reply"
    public static let finishCategory = "agent.finish"

    /// The buttons for a decision whose choices were read: "1 Yes", "2 No", masked and cut; nil with no choices, or more
    /// than `maxChoices`.
    public static func plan(choices: [String], mask: SecretMask = .current) -> [Action]? {
        guard !choices.isEmpty, choices.count <= maxChoices else { return nil }
        return choices.enumerated().map { index, choice in
            let words = mask.mask(choice)
            let cut = words.count > titleLength ? String(words.prefix(titleLength - 1)) + "…" : words
            return Action(id: "choice.\(index + 1)", title: "\(index + 1) \(cut)")
        }
    }

    /// The choice a button's id names, 1-based; nil for any other id.
    public static func choice(_ id: String) -> Int? {
        guard id.hasPrefix("choice.") else { return nil }
        return Int(id.dropFirst("choice.".count)).flatMap { (1...maxChoices).contains($0) ? $0 : nil }
    }

    /// A decision notice's own category, by the notice's id.
    public static func category(for notice: String) -> String { "agent." + notice }

    /// The categories to keep registered after adding `added`: each once, the newest last, `maxCategories` at most, the
    /// finish category always among them.
    public static func kept(_ categories: [String], adding added: String) -> [String] {
        var all = categories.filter { $0 != added && $0 != finishCategory } + [added]
        if added == finishCategory { all.removeLast() }
        let room = maxCategories - 1
        if all.count > room { all.removeFirst(all.count - room) }
        return [finishCategory] + all
    }
}
