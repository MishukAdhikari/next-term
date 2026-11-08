import Foundation

/// One block of a chat tab's transcript (plan 037 KTD3): what the native view draws as a tinted block or a row, in
/// order. Its id stays the same as the session grows, so the view replaces only the blocks that changed.
public struct ChatBlock: Equatable, Sendable {
    /// What the block shows. Each case is its own look: the view styles prompts as quiet tinted blocks, messages as full
    /// width Markdown, thinking as one folded row, tools as compact rows with a status, file changes with their counts,
    /// the plan as a checklist, and notes and closing lines as secondary text.
    public enum Content: Equatable, Sendable {
        /// The user's prompt, as typed.
        case prompt(text: String)
        /// The agent's words, as Markdown. `streaming` while chunks still arrive: an unclosed code fence is drawn as
        /// code so the text doesn't jump when it closes.
        case message(markdown: String, streaming: Bool)
        case thought(ChatThought)
        case tool(ChatTool)
        /// A file a tool changed, right after its tool's row.
        case change(ChatChange)
        /// The plan as it stands, updated in place.
        case plan([ACPSession.PlanEntry])
        /// A permission request or question once answered (an open one is the docked card, not a block).
        case answered(action: String, answer: String, outcome: ChatTranscript.Outcome)
        /// A line of Next Term's own: the version, a drift note, an error.
        case note(text: String, tone: ChatTranscript.Tone)
        /// How a turn ended, and the usage on the last one.
        case turnEnded(words: String, usage: String?, reason: ACPSession.StopReason)
    }

    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }
}

/// The agent's thinking: one folded row ("Thought for 12 s") that opens to its text.
public struct ChatThought: Equatable, Sendable {
    public let text: String
    public let folded: Bool
    /// Whole seconds from its first chunk to its last, when the host timed it.
    public let seconds: Int?
    /// Chunks still arrive: it is the session's last item while a turn runs.
    public let thinking: Bool

    /// The row's words: "Thinking…" while it streams, "Thought for 12 s" folded with a time, else "Thought".
    public var title: String {
        if thinking { return "Thinking\u{2026}" }
        if folded, let seconds { return "Thought for \(seconds) s" }
        return "Thought"
    }
}

/// One tool call's row: a status, the whole title, and its detail (the output) when expanded.
public struct ChatTool: Equatable, Sendable {
    public let callID: String
    /// The whole command or path (Claude's `Bash(npm test)`), or empty when the agent gave none.
    public let title: String
    /// ACP's tool kind: execute, edit, read, search, fetch, think, other.
    public let kind: String
    public let status: ACPSession.ToolCall.Status
    /// The tool's output, whole: the view caps what it draws, MCP gets it all.
    public let output: String
    public let expanded: Bool

    /// The title the row shows: the kind when the agent sent no title.
    public var shownTitle: String { title.isEmpty ? kind : title }

    /// What the native view draws of an expanded output before Show all: at most `lineCap` lines, each at most
    /// `lineCharacters` long, and `characterCap` in all, so one huge line (minified JSON, base64) isn't laid out whole on
    /// the main thread. MCP still reads `output` whole.
    public struct ShownOutput: Equatable, Sendable {
        public var lines: [String]
        /// The output's lines, trailing empty ones left out.
        public var totalLines: Int
        /// Something was left out: Show all draws it whole.
        public var capped: Bool
        /// Lines were left out, not only cut short.
        public var linesLeftOut: Bool { lines.count < totalLines }
    }

    public static let lineCap = 400
    public static let lineCharacters = 2_000
    public static let characterCap = 200_000

    /// The output's lines as the view draws them; `all` (Show all) gives them whole.
    public func shownOutput(all: Bool) -> ShownOutput {
        var lines = output.components(separatedBy: "\n")
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        let total = lines.count
        guard !all else { return ShownOutput(lines: lines, totalLines: total, capped: false) }
        var shown: [String] = []
        var budget = Self.characterCap
        var capped = total > Self.lineCap
        for line in lines.prefix(Self.lineCap) {
            guard budget > 0 else {
                capped = true
                break
            }
            let limit = min(Self.lineCharacters, budget)
            if let end = line.index(line.startIndex, offsetBy: limit, limitedBy: line.endIndex), end < line.endIndex {
                shown.append(String(line[..<end]) + "\u{2026}")
                capped = true
                budget -= limit
            } else {
                shown.append(line)
                budget -= line.count
            }
        }
        return ShownOutput(lines: shown, totalLines: total, capped: capped)
    }

    /// The status in words, as the session tab's transcript and VoiceOver say it.
    public var statusWord: String {
        switch status {
        case .pending: return "waiting"
        case .inProgress: return "running"
        case .completed: return "done"
        case .failed: return "failed"
        }
    }

    /// The status glyph of the session tab's transcript (`ACPTranscript`).
    public var glyph: String {
        switch status {
        case .pending: return "\u{25CB}"
        case .inProgress: return "\u{25D0}"
        case .completed: return "\u{2713}"
        case .failed: return "\u{2717}"
        }
    }

    /// The SF Symbol the native row draws for the status.
    public var symbolName: String {
        switch status {
        case .pending: return "circle.dotted"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        }
    }
}

/// A file a tool changed: its path, the lines added and removed, and whether it is new. Open Diff shows it.
public struct ChatChange: Equatable, Sendable {
    public let toolID: String
    public let path: String
    public let added: Int
    public let removed: Int
    public let created: Bool

    public init(toolID: String, path: String, added: Int, removed: Int, created: Bool) {
        self.toolID = toolID
        self.path = path
        self.added = added
        self.removed = removed
        self.created = created
    }
}

/// The chat tab's transcript as blocks, the change between two of them, and the plain text MCP reads (plan 037 KTD3).
public enum ChatTranscript {
    /// How an answered request went, for its row's tint.
    public enum Outcome: String, Sendable {
        case allowed, rejected, cancelled, answered
    }

    /// A note's weight, for its colour.
    public enum Tone: String, Sendable {
        case info, warning, error
    }

    /// The blocks `session` holds, in order. Ids: `item:<index>` for prompts, messages, thoughts, answers, notes and
    /// closing lines; `tool:<call id>` for a tool and `change:<call id>:<n>` for its file changes; `plan` for the plan,
    /// at the place of the latest plan update (the session keeps only the latest entries).
    ///
    /// A message streams while it is the session's last item and a turn runs. A thought is folded unless its id is in
    /// `expanded`, as a tool's detail opens only when its id is. `thoughtTimes` holds each thought's length in seconds,
    /// by item index, as the host timed it.
    public static func blocks(from session: ACPSession, expanded: Set<String>, thoughtTimes: [Int: TimeInterval]) -> [ChatBlock] {
        let items = session.items
        let lastPlan = items.lastIndex(of: .plan)
        let lastTurnEnd = items.lastIndex { if case .turnEnded = $0 { return true } else { return false } }
        var blocks: [ChatBlock] = []
        blocks.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let id = "item:\(index)"
            let isLast = index == items.count - 1
            switch item {
            case .prompt(let text):
                blocks.append(ChatBlock(id: id, content: .prompt(text: text)))
            case .message(let text):
                blocks.append(ChatBlock(id: id, content: .message(markdown: text, streaming: isLast && session.working)))
            case .thought(let text):
                let thought = ChatThought(text: text, folded: !expanded.contains(id), seconds: seconds(thoughtTimes[index]),
                                          thinking: isLast && session.working)
                blocks.append(ChatBlock(id: id, content: .thought(thought)))
            case .tool(let callID):
                guard let call = session.tools[callID] else { continue }
                let toolID = "tool:" + callID
                let tool = ChatTool(callID: callID, title: call.title, kind: call.kind, status: call.status, output: call.output,
                                    expanded: expanded.contains(toolID))
                blocks.append(ChatBlock(id: toolID, content: .tool(tool)))
                for (number, change) in call.changes.enumerated() {
                    let row = ChatChange(toolID: callID, path: change.path, added: change.added, removed: change.removed,
                                         created: change.created)
                    blocks.append(ChatBlock(id: "change:\(callID):\(number)", content: .change(row)))
                }
            case .plan:
                guard index == lastPlan else { continue }
                blocks.append(ChatBlock(id: "plan", content: .plan(session.plan)))
            case .permission(let action, let answer):
                guard let answer else { continue }
                blocks.append(ChatBlock(id: id, content: .answered(action: action, answer: answer, outcome: outcome(of: answer))))
            case .turnEnded(let reason):
                let usage = index == lastTurnEnd ? session.usage : nil
                blocks.append(ChatBlock(id: id, content: .turnEnded(words: reason.words, usage: usage, reason: reason)))
            case .note(let text):
                blocks.append(ChatBlock(id: id, content: .note(text: text, tone: tone(of: text))))
            }
        }
        return blocks
    }

    /// Whole seconds, or nil for a time that is no length.
    static func seconds(_ time: TimeInterval?) -> Int? {
        guard let time, time.isFinite, time >= 0, time < Double(Int32.max) else { return nil }
        return Int(time.rounded(.down))
    }

    /// How an answer went, by the option's name: the names the drivers give (Allow once, Allow always, Reject) and the
    /// session's own Cancelled. Anything else is a question's answer.
    public static func outcome(of answer: String) -> Outcome {
        let word = answer.lowercased()
        if word == "cancelled" { return .cancelled }
        if word.hasPrefix("allow") || word.hasPrefix("always allow") { return .allowed }
        if word.hasPrefix("reject") || word.hasPrefix("deny") || word.hasPrefix("decline") { return .rejected }
        return .answered
    }

    /// An answered request's row: "Allowed once: Bash(rm -rf build)", "Rejected: …", or a question's
    /// "Which database: Postgres".
    public static func answerLine(action: String, answer: String) -> String {
        switch answer.lowercased() {
        case "allow once", "allow": return "Allowed once: " + action
        case "allow always", "always allow": return "Allowed always: " + action
        case "reject", "deny", "decline": return "Rejected: " + action
        case "cancelled": return "Cancelled: " + action
        default: return action + ": " + answer
        }
    }

    /// A note's weight: an agent's error, a protocol change that ends the session, or anything else.
    public static func tone(of note: String) -> Tone {
        if note.hasPrefix("The agent answered with an error") { return .error }
        if note.hasPrefix(ClaudeStream.driftLead) || note.hasPrefix(CodexAppServer.driftLead) { return .warning }
        return .info
    }

    /// What changed from `old` to `new`, by id and value: blocks new to the list, blocks whose value changed in place,
    /// and blocks gone. A block that moved (the plan, when a later turn updates it) is removed and inserted again.
    public struct Change: Equatable, Sendable {
        public var inserted: [String]
        public var updated: [String]
        public var removed: [String]

        public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && removed.isEmpty }
    }

    public static func diff(old: [ChatBlock], new: [ChatBlock]) -> Change {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        var inserted: [String] = []
        var removed: [String] = []
        for step in newIDs.difference(from: oldIDs) {
            switch step {
            case .insert(_, let id, _): inserted.append(id)
            case .remove(_, let id, _): removed.append(id)
            }
        }
        let touched = Set(inserted).union(removed)
        var before: [String: ChatBlock.Content] = [:]
        for block in old where !touched.contains(block.id) { before[block.id] = block.content }
        var updated: [String] = []
        for block in new where !touched.contains(block.id) {
            if let was = before[block.id], was != block.content { updated.append(block.id) }
        }
        return Change(inserted: inserted, updated: updated, removed: removed.reversed())
    }

    /// The transcript as plain text, worded as the session tab's transcript (`ACPTranscript`) words it, so an agent reads
    /// the same lines in either kind: `› prompt`, the message's Markdown as written, `∴ Thought for 12 s`, a tool row as
    /// `✓ Bash(ls) · done`, its changes, the plan's checklist, answers, notes and closing lines. Nothing is cut to a width.
    /// The last `lastLines` lines.
    public static func plainText(_ blocks: [ChatBlock], lastLines: Int) -> String {
        guard lastLines > 0 else { return "" }
        var lines: [String] = []
        for block in blocks { lines += plainLines(block) }
        return lines.suffix(lastLines).joined(separator: "\n")
    }

    static func plainLines(_ block: ChatBlock) -> [String] {
        switch block.content {
        case .prompt(let text):
            return text.components(separatedBy: "\n").enumerated().map { ($0.offset == 0 ? "\u{203A} " : "  ") + $0.element }
        case .message(let markdown, _):
            var lines = markdown.components(separatedBy: "\n")
            while lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return lines
        case .thought(let thought):
            let head = "\u{2234} " + thought.title
            guard !thought.folded else { return [head] }
            return [head] + thought.text.components(separatedBy: "\n").map { "  " + $0 }
        case .tool(let tool):
            let head = tool.glyph + " " + tool.shownTitle + " \u{00B7} " + tool.statusWord
            guard tool.expanded, !tool.output.isEmpty else { return [head] }
            return [head] + tool.output.components(separatedBy: "\n").map { "    " + $0 }
        case .change(let change):
            let verb = change.created ? "Created" : "Edited"
            return ["    " + verb + " " + change.path + " (+\(change.added) \u{2212}\(change.removed))"]
        case .plan(let entries):
            return entries.map { entry in
                let mark: String
                switch entry.status {
                case .pending: mark = "\u{2610}"
                case .inProgress: mark = "\u{25D0}"
                case .completed: mark = "\u{2611}"
                }
                return "  " + mark + " " + entry.content
            }
        case .answered(let action, let answer, _):
            return ["  \u{21B3} " + action + ": " + answer]
        case .note(let text, _):
            return text.components(separatedBy: "\n").enumerated().map { ($0.offset == 0 ? "! " : "  ") + $0.element }
        case .turnEnded(let words, let usage, _):
            return [words + (usage.map { " \u{00B7} " + $0 } ?? "")]
        }
    }
}
