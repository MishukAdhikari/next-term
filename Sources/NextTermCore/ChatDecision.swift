import Foundation

/// The card docked above a chat tab's input while the agent waits on a permission or a question (plan 037 R3, KTD5):
/// the action in full, one choice per option the agent offers, which choice the keys have highlighted, and which one
/// only the Mac's own confirmation may answer.
public struct ChatDecision: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        /// The option's name, as the agent gave it: "Allow once", "Allow always", "Reject", or a question's answer.
        public let name: String
        /// ACP's option kind: allow_once, allow_always, reject_once, reject_always.
        public let kind: String
        /// Allow always: answered only once the user approves on the Mac, never by a key, a click on the card alone,
        /// MCP or a notification's button.
        public let needsMac: Bool
        /// Its digit (1-based): the key that picks it.
        public let number: Int
    }

    /// The action in full (the tool call's title), or the question's own words with their question mark.
    public let title: String
    /// "Claude Code asks to:" above a permission's action; nil for a question.
    public let lead: String?
    public let choices: [Choice]
    /// The choice ↑ and ↓ have moved to: Return picks it.
    public let highlighted: Int
    /// The first reject choice, which Esc picks; nil when the agent offers none (a question).
    public let rejectIndex: Int?
    /// The choice styled as the default button: the first allow_once, else the first.
    public let defaultIndex: Int
    public let isQuestion: Bool
    /// The words the tab reports for it (TabStatus.question), as the session tab's menu words them.
    public let question: String

    /// The card for `permission`, asked by `agent` (its product name).
    public static func from(_ permission: ACPSession.Permission, agent: String) -> ChatDecision {
        let choices = permission.options.enumerated().map { index, option in
            Choice(name: option.name, kind: option.kind, needsMac: option.kind == "allow_always", number: index + 1)
        }
        let reject = permission.isQuestion ? nil : choices.firstIndex { $0.kind.hasPrefix("reject") }
        let preferred = choices.firstIndex { $0.kind == "allow_once" } ?? 0
        let highlighted = choices.isEmpty ? 0 : min(max(permission.highlighted, 0), choices.count - 1)
        let title = permission.isQuestion && !permission.words.isEmpty ? permission.words : permission.action
        return ChatDecision(title: title, lead: permission.isQuestion ? nil : agent + " asks to:", choices: choices,
                            highlighted: highlighted, rejectIndex: reject, defaultIndex: permission.isQuestion ? 0 : preferred,
                            isQuestion: permission.isQuestion, question: ACPTranscript.question(permission))
    }

    /// The card as the menu MCP and notifications read (MCPControl.fieldMenu): a list, the choices' names, the
    /// highlight, and Esc's reject choice. `question` is the tab's question it answers.
    public func menu(question: String) -> AgentMenu {
        AgentMenu(question: question, style: .list, choices: choices.map(\.name), highlighted: highlighted, escape: rejectIndex)
    }
}

/// Where a chat tab's host is (plan 037's host states): the header says it, and Stop shows only in a turn.
public enum ChatHostState: String, CaseIterable, Sendable {
    /// Brought back after a crash, or in safe mode: no agent runs until Resume.
    case idle
    case starting
    /// Waiting for the user's OK on the Mac to trust the folder (Claude Code).
    case trusting
    case ready
    case working
    case asking
    case ended

    /// The header's words for the state.
    public var words: String {
        switch self {
        case .idle: return "Not running"
        case .starting: return "Starting\u{2026}"
        case .trusting: return "Waiting for your OK"
        case .ready: return "Ready"
        case .working: return "Working"
        case .asking: return "Needs your answer"
        case .ended: return "Ended"
        }
    }

    /// A turn runs: the Stop button shows, and ⌘. stops it.
    public var showsStop: Bool { self == .working || self == .asking }
}

/// The chat tab's header (plan 037 R5): the agent's name, the model, the CLI's version, the folder, the usage and the
/// state.
public struct ChatHeader: Equatable, Sendable {
    public let name: String
    public let model: String?
    public let version: String?
    /// The folder, with the home folder as `~`.
    public let folder: String?
    public let usage: String?
    public let state: ChatHostState

    /// "Claude Code · stand-in-model · 9.9.9 · ~/proj": what is missing is left out, with no doubled separators.
    public var line: String {
        ([name] + [model, version, folder].compactMap { $0 }).joined(separator: " \u{00B7} ")
    }

    public var stateWords: String { state.words }

    public static func make(agent: String, model: String?, version: String?, folder: String?, home: String, usage: String?,
                            state: ChatHostState) -> ChatHeader {
        ChatHeader(name: agent, model: present(model), version: present(version),
                   folder: present(folder).map { RecentProjects.abbreviate($0, home: home) }, usage: present(usage), state: state)
    }

    /// `text` trimmed, or nil when nothing is left.
    static func present(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// What the chat tab's input box allows and says (plan 037 R4).
public struct ChatInputState: Equatable, Sendable {
    /// Return sends the draft.
    public let canSend: Bool
    /// The words in the empty box: how to start, what the session waits on, or why it can't send.
    public let placeholder: String
    /// A turn runs: the Stop button shows, and Esc or ⌘. stops it.
    public let showsStop: Bool

    /// From the session and the host's facts. A waiting line (the folder trust asked on the Mac) wins over everything,
    /// then an ended session, then an open card, then a running turn.
    public static func make(session: ACPSession, waitingLine: String?, ended: Bool, agentName: String) -> ChatInputState {
        let turn = !ended && (session.working || session.pending != nil)
        if let waitingLine, !waitingLine.isEmpty {
            return ChatInputState(canSend: false, placeholder: waitingLine, showsStop: false)
        }
        if ended { return ChatInputState(canSend: false, placeholder: "This session ended.", showsStop: false) }
        if session.pending != nil {
            return ChatInputState(canSend: false, placeholder: agentName + " is asking you something. Answer it above.", showsStop: turn)
        }
        if session.working {
            return ChatInputState(canSend: false, placeholder: agentName + " is working. \u{2318}. stops it.", showsStop: turn)
        }
        return ChatInputState(canSend: true, placeholder: "Message " + agentName, showsStop: false)
    }

    /// The agent's commands the "/" list offers for `typed`: while the box holds only a slash word, the commands that
    /// start with it, any case, each with its slash. The agent may name them with or without one.
    public static func slashMatches(_ typed: String, commands: [String]) -> [String] {
        guard typed.hasPrefix("/"), !typed.contains(where: \.isWhitespace) else { return [] }
        let wanted = typed.dropFirst().lowercased()
        var seen: Set<String> = []
        var matches: [String] = []
        for command in commands {
            let name = command.hasPrefix("/") ? String(command.dropFirst()) : command
            guard !name.isEmpty, !name.contains(where: \.isWhitespace), name.lowercased().hasPrefix(wanted),
                  seen.insert(name).inserted else { continue }
            matches.append("/" + name)
        }
        return matches
    }
}

/// The chat tab's text sizes, which follow View › Bigger and Smaller (the editor's font size): the body at that size,
/// with secondary text, code and headings kept in the proportions of the 13-point design (11, 12 and 15 points).
public struct ChatTextSizes: Equatable, Sendable {
    /// The editor's range of sizes.
    public static let range: ClosedRange<Double> = 8...32
    public static let standard: Double = 13

    public let body: Double
    /// Metadata, notes, the thinking row and closing lines.
    public let secondary: Double
    /// Commands, tool rows and code.
    public let monospaced: Double
    /// A message's headings.
    public let heading: Double

    public init(base: Double) {
        let size = base.isFinite ? min(max(base, Self.range.lowerBound), Self.range.upperBound) : Self.standard
        body = size
        // Secondary text and code step down from the body, but not below 9 points unless the body is smaller.
        secondary = max(size - 2, min(size, 9))
        monospaced = max(size - 1, min(size, 9))
        heading = size + 2
    }
}
