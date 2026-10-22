import Foundation

/// May Next Term type into this agent tab now, and if not, why. One answer for every feature that hands an agent
/// text: a doubtful tab is skipped, never typed into, so nothing lands in a shell, in a busy agent, or on top of text
/// the user left in the prompt.
///
/// It also keeps each agent tab's `PromptLine`, fed by every write into a tab. Only tabs running an agent are watched:
/// a write into any other tab returns after one dictionary lookup and a flag, with no allocation, no copy and no
/// decoding, so shells pay nothing. Main thread only, as the tabs that feed it.
public final class AgentReadiness {
    public static let shared = AgentReadiness()

    public enum Verdict: Equatable, Sendable {
        case ready
        case notReady(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case working, asking, hasText, remote, notAgent, locked, exited, unseenPrompt

        /// How a tab list says it, after the tab's name.
        public var text: String {
            switch self {
            case .working: return "working"
            case .asking: return "asking"
            case .hasText: return "has your text in its prompt"
            case .remote: return "on a server"
            case .notAgent: return "not an agent"
            case .locked: return "locked"
            case .exited: return "exited"
            case .unseenPrompt: return "can’t see its prompt"
            }
        }
    }

    /// What is known of a tab, as plain values.
    public struct Tab: Equatable, Sendable {
        public var state: TabState
        /// The agent's question, when it waits on a decision.
        public var question: String?
        /// The agent running in a local tab; nil for a shell or a plain command.
        public var agent: AgentKind?
        /// Whether the prompt holds text; nil when that can't be seen.
        public var lineHasText: Bool?
        public var remote = false
        /// herdr on a server reports the agent's state itself.
        public var herdr = false
        public var exited = false
        /// Busy as send_to_tab sees it.
        public var busy = false
        /// Input went in moments ago and its work has not shown yet.
        public var starting = false
        /// A rule says the tab's input line is not the user's own.
        public var locked = false

        public init(state: TabState, question: String? = nil, agent: AgentKind?, lineHasText: Bool?) {
            self.state = state
            self.question = question
            self.agent = agent
            self.lineHasText = lineHasText
        }
    }

    /// Done counts as ready: it is only the mark of work not yet looked at.
    public static func check(_ tab: Tab) -> Verdict {
        if tab.exited { return .notReady(.exited) }
        if tab.herdr { return herdr(tab) }
        if tab.remote { return .notReady(.remote) }
        if tab.agent == nil { return .notReady(.notAgent) }
        if tab.state == .working || tab.busy || tab.starting { return .notReady(.working) }
        if tab.question != nil || tab.state == .attention { return .notReady(.asking) }
        if tab.locked { return .notReady(.locked) }
        guard let hasText = tab.lineHasText else { return .notReady(.unseenPrompt) }
        return hasText ? .notReady(.hasText) : .ready
    }

    /// herdr's own state decides working and asking; its prompt is seen only when a line is known empty.
    private static func herdr(_ tab: Tab) -> Verdict {
        if tab.state == .working || tab.busy || tab.starting { return .notReady(.working) }
        if tab.question != nil || tab.state == .attention { return .notReady(.asking) }
        guard tab.state == .idle || tab.state == .done else { return .notReady(.unseenPrompt) }
        if tab.locked { return .notReady(.locked) }
        guard let hasText = tab.lineHasText else { return .notReady(.unseenPrompt) }
        return hasText ? .notReady(.hasText) : .ready
    }

    // MARK: the watch

    private struct Watch {
        var line = PromptLine()
        var working = false

        /// The agent took the line when it went from working to not working.
        mutating func observe(working now: Bool) {
            if working && !now { line.reset() }
            working = now
        }

        mutating func take(_ data: ArraySlice<UInt8>, working now: Bool) {
            observe(working: now)
            line.feed(data)
        }
    }

    private var watches: [UUID: Watch] = [:]

    public init() {}

    /// Tabs whose line is kept.
    public var watchedCount: Int { watches.count }

    /// A write into a tab. A tab not running an agent returns at once; one that stopped running its agent is dropped.
    public func written(_ data: ArraySlice<UInt8>, id: UUID, agentRunning: Bool, working: Bool) {
        guard agentRunning else {
            if !watches.isEmpty, watches[id] != nil { watches[id] = nil }
            return
        }
        // An agent's input starts empty: the line that started it ended with Return, so a first write starts the count.
        watches[id, default: Watch()].take(data, working: working)
    }

    /// Whether the agent's prompt holds text: false for an agent tab nothing was typed into since it started, nil for a
    /// tab not running an agent.
    public func lineHasText(_ id: UUID, agentRunning: Bool, working: Bool) -> Bool? {
        guard agentRunning else { return nil }
        guard watches[id] != nil else { return false }
        watches[id]?.observe(working: working)
        return watches[id]?.line.hasText
    }

    /// The tab closed.
    public func forget(_ id: UUID) {
        watches[id] = nil
    }
}
