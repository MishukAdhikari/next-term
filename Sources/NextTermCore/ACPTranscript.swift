import Foundation

/// An agent session drawn as terminal lines, in the terminal's own font and colours (ANSI's, which the theme sets):
/// the prompts, the agent's words, a line per tool call and its status, the plan as a checklist, file changes, a
/// permission request as a numbered menu, and a closing line per turn (R8). The menu is drawn as the agents' own
/// TUIs draw theirs ("Do you want to …?", "❯ 1. …", "Enter to select"), so Next Term reads it the same way: the tab's
/// attention mark, the notification's buttons and `answer_agent` work on it as on any agent's question. Plan 030.
public enum ACPTranscript {
    /// A drawn line: its text with its style's ANSI codes, and the text alone (for tests and widths).
    public struct Line: Equatable, Sendable {
        public let text: String
        public let style: Style

        public enum Style: Equatable, Sendable {
            case plain, bold, dim, green, red, yellow, cyan
        }

        public init(_ text: String, _ style: Style = .plain) {
            self.text = text
            self.style = style
        }

        /// The line as the terminal gets it.
        public var ansi: String {
            switch style {
            case .plain: return text
            case .bold: return "\u{1b}[1m" + text + "\u{1b}[0m"
            case .dim: return "\u{1b}[2m" + text + "\u{1b}[0m"
            case .green: return "\u{1b}[32m" + text + "\u{1b}[0m"
            case .red: return "\u{1b}[31m" + text + "\u{1b}[0m"
            case .yellow: return "\u{1b}[33m" + text + "\u{1b}[0m"
            case .cyan: return "\u{1b}[36m" + text + "\u{1b}[0m"
            }
        }
    }

    /// The words the menu's question starts with: AgentScreen's question pattern takes "Do you want to …?".
    public static let questionLead = "Do you want to allow: "
    /// The menu's question line, and the words the tab reports for it: a permission's starts with `questionLead`, a
    /// question the agent asks is its own words.
    public static func question(_ permission: ACPSession.Permission) -> String {
        (permission.isQuestion ? "" : questionLead) + permission.action + "?"
    }

    /// The lead of the menu question's later rows, when it wraps.
    public static let questionIndent = "  "

    /// The hint under the menu, which tells AgentScreen the choices are a question's.
    public static let menuHint = "Enter to select \u{00B7} \u{2191}\u{2193} to move \u{00B7} Esc to stop"

    /// Items `from` to the end of `session`, at `width` columns, a blank line before each prompt but the first.
    public static func lines(_ session: ACPSession, from start: Int, width: Int) -> [Line] {
        let width = max(width, 20)
        var lines: [Line] = []
        for index in start..<session.items.count {
            let item = session.items[index]
            if case .prompt = item, index > 0 { lines.append(Line("")) }
            lines += draw(item, in: session, width: width)
        }
        return lines
    }

    static func draw(_ item: ACPSession.Item, in session: ACPSession, width: Int) -> [Line] {
        switch item {
        case .prompt(let text):
            return wrap(text, width: width, first: "\u{203A} ", rest: "  ").map { Line($0, .bold) }
        case .message(let text):
            return wrap(text, width: width, first: "", rest: "").map { Line($0) }
        case .thought(let text):
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return [Line(fit("\u{2234} " + ACPSession.oneLine(first, limit: 400), width), .dim)]
        case .tool(let id):
            guard let call = session.tools[id] else { return [] }
            return tool(call, width: width)
        case .plan:
            return session.plan.map { entry in
                let mark: String
                switch entry.status {
                case .pending: mark = "\u{2610}"
                case .inProgress: mark = "\u{25D0}"
                case .completed: mark = "\u{2611}"
                }
                return Line(fit("  " + mark + " " + entry.content, width), entry.status == .completed ? .dim : .plain)
            }
        case .permission(let action, let answer):
            if let answer { return [Line(fit("  \u{21B3} " + action + ": " + answer, width), .dim)] }
            return menu(session.pending, width: width)
        case .turnEnded(let reason):
            let style: Line.Style = reason == .endTurn ? .dim : (reason == .cancelled ? .yellow : .red)
            let usage = session.usage.map { " \u{00B7} " + $0 } ?? ""
            return [Line(fit(reason.words + usage, width), style)]
        case .note(let text):
            return wrap(text, width: width, first: "! ", rest: "  ").map { Line($0, .yellow) }
        }
    }

    static func tool(_ call: ACPSession.ToolCall, width: Int) -> [Line] {
        let (mark, style, word): (String, Line.Style, String)
        switch call.status {
        case .pending: (mark, style, word) = ("\u{25CB}", .dim, "waiting")
        case .inProgress: (mark, style, word) = ("\u{25D0}", .cyan, "running")
        case .completed: (mark, style, word) = ("\u{2713}", .green, "done")
        case .failed: (mark, style, word) = ("\u{2717}", .red, "failed")
        }
        let title = call.title.isEmpty ? call.kind : call.title
        var lines = [Line(fit(mark + " " + title + " \u{00B7} " + word, width), style)]
        for change in call.changes {
            let verb = change.created ? "Created" : "Edited"
            lines.append(Line(fit("    " + verb + " " + change.path + " (+\(change.added) \u{2212}\(change.removed))", width), .dim))
        }
        if call.status == .failed, let first = call.output.split(whereSeparator: \.isNewline).first {
            lines.append(Line(fit("    " + ACPSession.oneLine(String(first), limit: 300), width), .red))
        }
        return lines
    }

    /// The open permission request as AgentScreen reads an agent's menu.
    static func menu(_ permission: ACPSession.Permission?, width: Int) -> [Line] {
        guard let permission else { return [] }
        // The question whole, wrapped (R5, plan 035): its later rows are indented, which tells AgentScreen where it starts.
        var lines = wrap(question(permission), width: width, first: "", rest: questionIndent).map { Line($0, .bold) }
        for (index, option) in permission.options.enumerated() {
            let cursor = index == permission.highlighted ? "\u{276F} " : "  "
            lines.append(Line(fit(cursor + "\(index + 1). " + option.name, width), index == permission.highlighted ? .cyan : .plain))
        }
        lines.append(Line(fit("  " + menuHint, width), .dim))
        return lines
    }

    /// The input line under the transcript: the prompt being typed, or what the session waits for.
    public static func inputLine(_ session: ACPSession, typed: String, width: Int) -> Line {
        if session.pending != nil { return Line(fit("Answer above: 1\u{2013}\(session.pending!.options.count), or Esc to stop", width), .dim) }
        if session.working { return Line(fit("Working \u{2014} \u{2303}C to stop", width), .dim) }
        // The end of a long prompt shows, as a shell's line does.
        let room = max(width - 3, 1)
        let shown = typed.count > room ? "\u{2026}" + String(typed.suffix(room - 1)) : typed
        return Line("\u{203A} " + shown)
    }

    /// `text` broken at `width` columns, at spaces where it can, its own line breaks kept.
    static func wrap(_ text: String, width: Int, first: String, rest: String) -> [String] {
        var out: [String] = []
        var lead = first
        for paragraph in text.components(separatedBy: "\n") {
            let clean = String(paragraph.unicodeScalars.map { $0 == "\t" ? " " : ($0.value < 0x20 || (0x7F...0x9F).contains($0.value) ? " " : Character($0)) })
            // The room is the current lead's: the first line's and the rest's can differ (the menu's question).
            var room: Int { max(width - lead.count, 1) }
            var line = ""
            for word in clean.split(separator: " ", omittingEmptySubsequences: false) {
                var word = String(word)
                while word.count > room {
                    if !line.isEmpty {
                        out.append(lead + line)
                        lead = rest
                        line = ""
                    }
                    let cut = room
                    out.append(lead + String(word.prefix(cut)))
                    lead = rest
                    word = String(word.dropFirst(cut))
                }
                if line.isEmpty { line = word }
                else if line.count + 1 + word.count <= room { line += " " + word }
                else {
                    out.append(lead + line)
                    lead = rest
                    line = word
                }
            }
            out.append(lead + line)
            lead = rest
        }
        // Trailing blank lines of a message still streaming aren't drawn.
        while out.count > 1, out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out
    }

    /// One line cut to `width` columns.
    static func fit(_ text: String, _ width: Int) -> String {
        text.count > width ? String(text.prefix(width - 1)) + "\u{2026}" : text
    }
}
