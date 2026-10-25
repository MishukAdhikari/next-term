import Foundation

/// Answering a blocked herdr agent's question, the one way for every place that does it (MCP's answer_agent, Peek's
/// buttons, Go to Agent's Answer submenu, a notice's buttons): from what the agent's pane shows when read again just
/// before, the keys that move to the choice; then, from a second read after them, whether Return goes, the agent took
/// the answer already, or nothing more is typed. The question is checked by its id before any key, so an answer meant
/// for one question never lands on the next; after the moves, by its words on screen (`next`). Pure: the caller reads
/// the pane and sends the keys (through herdr's `agent send-keys`).
public enum HerdrAnswer {
    /// What a read of the agent's pane found: its question's id and words, and the choices drawn under it.
    public struct Asked: Equatable, Sendable {
        public var id: String
        public var text: String
        public var menu: AgentMenu?

        public init(id: String, text: String, menu: AgentMenu?) {
            self.id = id
            self.text = text
            self.menu = menu
        }
    }

    /// Why nothing (more) is typed.
    public enum Refusal: Error, Equatable, Sendable {
        /// The pane asks nothing now.
        case notAsking
        /// It asks another question now: its words and its id.
        case changed(question: String, id: String)
        /// Its choices cannot be read.
        case noChoices(question: String)
        /// The choice asked for is not one of them: why, in a sentence that lists them.
        case badChoice(String)
        /// A list whose cursor is not drawn, so the way to the choice is unknown.
        case noCursor(choice: String)
        /// After the arrows, before Return: the question went away, or changed.
        case wentAway, changedMeanwhile
        /// After the arrows, before Return: the cursor is not on the choice.
        case cursorElsewhere(choice: String)

        /// In a sentence, for a person (Peek, a notice): what happened, and that nothing more was typed.
        public var sentence: String {
            switch self {
            case .notAsking: return "It is not asking anything now; nothing was typed."
            case .changed(let question, _): return "The question changed: it now asks “\(question)”. Nothing was typed."
            case .noChoices(let question): return "The choices for “\(question)” cannot be read in its pane; nothing was typed."
            case .badChoice(let why): return why + " Nothing was typed."
            case .noCursor(let choice): return "Its pane does not show which choice is selected, so the way to “\(choice)” is unknown; nothing was typed."
            case .wentAway: return "Return was not pressed: the question went away meanwhile."
            case .changedMeanwhile: return "Return was not pressed: the question changed meanwhile."
            case .cursorElsewhere(let choice): return "Return was not pressed: the cursor did not reach “\(choice)”."
            }
        }
    }

    /// The keys that answer: `moves` first (the arrows to the choice in a list; the letter of a y/n prompt), then a read,
    /// then Return (`next`).
    public struct Plan: Equatable, Sendable {
        /// The choice, 0-based, and its words.
        public var index: Int
        public var label: String
        public var moves: [String]
        public var style: AgentMenu.Style
        /// The question it answers, and its words.
        public var questionID: String
        public var question: String

        public init(index: Int, label: String, moves: [String], style: AgentMenu.Style, questionID: String, question: String) {
            self.index = index
            self.label = label
            self.moves = moves
            self.style = style
            self.questionID = questionID
            self.question = question
        }
    }

    /// The plan for choice `choice` (1-based) or `answer` (a choice's words) of the question the caller saw (`expected`,
    /// its id), from `asked`, what the pane shows now.
    public static func plan(_ asked: Asked?, expected: String, choice: Int?, answer: String?) -> Result<Plan, Refusal> {
        guard let asked else { return .failure(.notAsking) }
        guard asked.id == expected else { return .failure(.changed(question: asked.text, id: asked.id)) }
        guard let menu = asked.menu, !menu.choices.isEmpty else { return .failure(.noChoices(question: asked.text)) }
        let index: Int
        switch menu.index(choice: choice, answer: answer) {
        case .failure(let error): return .failure(.badChoice(error.text))
        case .success(let found): index = found
        }
        guard let keys = menu.keys(toPick: index) else { return .failure(.noCursor(choice: menu.choices[index])) }
        return .success(Plan(index: index, label: menu.choices[index], moves: Array(keys.dropLast()), style: menu.style,
                             questionID: asked.id, question: asked.text))
    }

    /// What comes after the moves.
    public enum Step: Equatable, Sendable {
        /// Return goes now.
        case pressReturn
        /// The agent took the answer already (a y/n prompt that took its letter): nothing more.
        case answered
        case refused(Refusal)
    }

    /// From what the pane shows after the moves (`shown`: the question read from it and the choices under it, nil when it
    /// asks nothing, or herdr no longer says the agent is blocked): still the same question, and in a list the cursor on
    /// the choice, so Return goes; a y/n prompt whose question went away (or gave way to the next) took its letter;
    /// anything else types nothing more. With no moves (the cursor was on the choice), Return goes at once.
    ///
    /// The same question is the one in the same words. The moves alone answer no list, and a y/n prompt that took its
    /// letter shows another question or none, so the words tell. Not its id: the keys bring a change herdr has not
    /// counted yet, so a question read now would be filed under the count of the one being answered, and once herdr's
    /// count catches up the same question is read again under a new id.
    public static func next(_ plan: Plan, shown: (text: String, menu: AgentMenu?)?) -> Step {
        if plan.moves.isEmpty { return .pressReturn }
        let same = shown?.text == plan.question
        if plan.style == .yesNo, !same { return .answered }
        guard let shown else { return .refused(.wentAway) }
        guard same else { return .refused(.changedMeanwhile) }
        if plan.style == .list, shown.menu?.highlighted != plan.index { return .refused(.cursorElsewhere(choice: plan.label)) }
        return .pressReturn
    }
}
