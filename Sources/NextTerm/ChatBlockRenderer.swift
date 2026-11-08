import AppKit
import NextTermCore

extension NSAttributedString.Key {
    /// A chat transcript's tinted panel or bar behind a run of paragraphs (`ChatPanel`), drawn by the transcript's text
    /// view under the text.
    static let chatPanel = NSAttributedString.Key("NextTermChatPanel")
}

/// One panel behind a run of a chat transcript's text: the user's prompt, a code block, a tool's output, a quote's bar,
/// or the hairline after a turn's closing line. Each block makes its own, so two panels side by side stay two.
final class ChatPanel: NSObject {
    enum Kind {
        case prompt, code, detail, quote, rule
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// What a click in a chat transcript asks for: links on Next Term's own `nextterm-chat:` scheme, which open nothing
/// outside the app.
enum ChatLink: Equatable {
    /// Unfold or fold a tool's output or a thought.
    case toggle(String)
    /// Show a file change in the editor.
    case diff(String)
    /// Draw a tool's whole output, past the first 400 lines.
    case showAll(String)
    /// Continue the conversation in a terminal tab (the handoff, plan 037 U8).
    case openInTerminal

    static let scheme = "nextterm-chat"

    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .toggle(let id): parts.path = "toggle"; parts.queryItems = [URLQueryItem(name: "id", value: id)]
        case .diff(let id): parts.path = "diff"; parts.queryItems = [URLQueryItem(name: "id", value: id)]
        case .showAll(let id): parts.path = "all"; parts.queryItems = [URLQueryItem(name: "id", value: id)]
        case .openInTerminal: parts.path = "terminal"
        }
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    init?(_ link: Any) {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == Self.scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = parts.queryItems?.first { $0.name == "id" }?.value
        switch (parts.path, id) {
        case ("toggle", let id?): self = .toggle(id)
        case ("diff", let id?): self = .diff(id)
        case ("all", let id?): self = .showAll(id)
        case ("terminal", _): self = .openInTerminal
        default: return nil
        }
    }
}

/// A chat transcript's blocks as attributed text (plan 037 KTD15): the user's prompts on a quiet tinted panel, the
/// agent's Markdown full width, thinking folded to one row, tools as compact rows with a status symbol, file changes
/// with their counts and Open Diff, the plan as a checklist, answers, notes and closing lines in secondary text. Each
/// block ends in a line break. Sizes follow the editor's (`ChatTextSizes`); every colour is semantic.
struct ChatBlockRenderer {
    let sizes: ChatTextSizes
    /// Tools whose whole output is drawn, past the cap.
    var showAll: Set<String> = []
    /// The handoff exists for this chat (Claude Code or Codex): a terminal-only note links to it.
    var offersTerminal = false

    /// A tool's output drawn before "Show all".
    static let outputCap = 400

    private var body: CGFloat { CGFloat(sizes.body) }
    private var secondary: CGFloat { CGFloat(sizes.secondary) }
    private var mono: CGFloat { CGFloat(sizes.monospaced) }

    /// The space a block keeps above itself, by what comes before it.
    func gap(_ block: ChatBlock, after previous: ChatBlock?) -> CGFloat {
        guard let previous else { return 2 }
        let isRow = Self.isRow(block)
        switch block.content {
        case .prompt: return 26
        case .message: return Self.kind(of: previous) == 0 ? 20 : (Self.isRow(previous) ? 10 : 8)
        case .turnEnded: return 12
        case .plan: return 12
        case .note: return Self.isRow(previous) || Self.kind(of: previous) == 5 ? 4 : 10
        default:
            if isRow { return Self.isRow(previous) ? 4 : (Self.kind(of: previous) == 0 ? 18 : 10) }
            return 8
        }
    }

    /// A rough kind number for spacing: 0 prompt, 1 message, 2 row, 3 plan, 4 turn end, 5 note.
    private static func kind(of block: ChatBlock) -> Int {
        switch block.content {
        case .prompt: return 0
        case .message: return 1
        case .thought, .tool, .change, .answered: return 2
        case .plan: return 3
        case .turnEnded: return 4
        case .note: return 5
        }
    }

    private static func isRow(_ block: ChatBlock) -> Bool { kind(of: block) == 2 }

    func render(_ block: ChatBlock, after previous: ChatBlock?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch block.content {
        case .prompt(let text): prompt(text, into: out)
        case .message(let markdown, _): message(markdown, into: out)
        case .thought(let thought): self.thought(thought, id: block.id, into: out)
        case .tool(let tool): self.tool(tool, id: block.id, into: out)
        case .change(let change): self.change(change, id: block.id, into: out)
        case .plan(let entries): plan(entries, into: out)
        case .answered(let action, let answer, let outcome): answered(action, answer: answer, outcome: outcome, into: out)
        case .note(let text, let tone): note(text, tone: tone, into: out)
        case .turnEnded(let words, let usage, let reason): turnEnded(words, usage: usage, reason: reason, into: out)
        }
        if !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: secondary)])) }
        Self.setGap(gap(block, after: previous), on: out)
        return out
    }

    // MARK: blocks

    private func prompt(_ text: String, into out: NSMutableAttributedString) {
        let font = NSFont.systemFont(ofSize: body)
        let lines = text.components(separatedBy: "\n")
        let panel = ChatPanel(.prompt)
        for line in lines {
            let style = paragraph(before: 0, after: 0, lineSpacing: 3)
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.tailIndent = -12
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor,
                                                                           .paragraphStyle: style, .chatPanel: panel]))
        }
    }

    private func message(_ markdown: String, into out: NSMutableAttributedString) {
        var style = MarkdownBlocksRenderer.Style()
        style.body = body
        style.largeHeading = CGFloat(sizes.heading)
        style.smallHeading = body
        style.code = mono
        style.lineSpacing = 3
        style.paragraphAfter = 8
        style.listAfter = 4
        style.headingBefore = 14
        style.headingAfter = 6
        style.codeBefore = 10
        style.codeAfter = 14
        style.codeInset = 12
        style.codeAttributes = [.chatPanel: ChatPanel(.code)]
        let text = MarkdownBlocksRenderer.message(markdown, style: style, quoteAttributes: [.chatPanel: ChatPanel(.quote)])
        // Web links read as links; Next Term's own rows set their own colours.
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
        out.append(text)
        if out.length == 0 { out.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: body)])) }
    }

    private func thought(_ thought: ChatThought, id: String, into out: NSMutableAttributedString) {
        let font = NSFontManager.shared.convert(.systemFont(ofSize: secondary), toHaveTrait: .italicFontMask)
        let row = NSMutableAttributedString()
        row.append(symbol(thought.folded ? "chevron.right" : "chevron.down", size: secondary - 2, color: .tertiaryLabelColor,
                          label: thought.folded ? "Folded" : "Unfolded", weight: .semibold))
        row.append(NSAttributedString(string: "  " + thought.title, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        row.addAttribute(.link, value: ChatLink.toggle(id).url, range: NSRange(location: 0, length: row.length))
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        row.addAttribute(.paragraphStyle, value: paragraph(before: 0, after: 0), range: NSRange(location: 0, length: row.length))
        out.append(row)
        guard !thought.folded, !thought.text.isEmpty else { return }
        let text = NSFont.systemFont(ofSize: secondary)
        let lines = thought.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let panel = ChatPanel(.quote)
        for (index, line) in lines.enumerated() {
            let style = paragraph(before: index == 0 ? 6 : 0, after: index == lines.count - 1 ? 4 : 0, lineSpacing: 2)
            style.firstLineHeadIndent = 16
            style.headIndent = 16
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: text, .foregroundColor: NSColor.secondaryLabelColor,
                                                                           .paragraphStyle: style, .chatPanel: panel]))
        }
    }

    private func tool(_ tool: ChatTool, id: String, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        let row = NSMutableAttributedString()
        let color: NSColor
        switch tool.status {
        case .pending: color = .tertiaryLabelColor
        case .inProgress: color = .controlAccentColor
        case .completed: color = .secondaryLabelColor
        case .failed: color = .systemRed
        }
        // VoiceOver reads the symbol's description first: "Done, Bash(npm test)".
        row.append(symbol(tool.symbolName, size: secondary, color: color, label: tool.statusWord.capitalized + ","))
        let title = tool.shownTitle.replacingOccurrences(of: "\n", with: " ")
        row.append(NSAttributedString(string: "  " + title, attributes: [.font: font,
                                                                        .foregroundColor: tool.status == .failed ? NSColor.systemRed : NSColor.labelColor]))
        let opens = !tool.output.isEmpty
        if opens {
            row.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            row.append(symbol(tool.expanded ? "chevron.down" : "chevron.right", size: secondary - 3, color: .tertiaryLabelColor,
                              label: tool.expanded ? "output shown" : "output folded", weight: .semibold))
            row.addAttribute(.link, value: ChatLink.toggle(id).url, range: NSRange(location: 0, length: row.length))
            row.addAttribute(.toolTip, value: tool.expanded ? "Hide the output" : "Show the output", range: NSRange(location: 0, length: row.length))
        }
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        let style = paragraph(before: 0, after: 0, lineSpacing: 2)
        style.headIndent = secondary + 8
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        out.append(row)
        guard tool.expanded, opens else { return }
        var lines = tool.output.components(separatedBy: "\n")
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        let total = lines.count
        let capped = !showAll.contains(id) && total > Self.outputCap
        if capped { lines = Array(lines.prefix(Self.outputCap)) }
        let panel = ChatPanel(.detail)
        let detail = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        for (index, line) in lines.enumerated() {
            let last = index == lines.count - 1 && !capped
            let style = paragraph(before: index == 0 ? 10 : 0, after: last ? 10 : 0, lineSpacing: 1)
            style.firstLineHeadIndent = secondary + 8 + 10
            style.headIndent = style.firstLineHeadIndent
            style.tailIndent = -10
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: detail, .foregroundColor: NSColor.labelColor,
                                                                           .paragraphStyle: style, .chatPanel: panel]))
        }
        if capped {
            let style = paragraph(before: 4, after: 10)
            style.firstLineHeadIndent = secondary + 8 + 10
            style.headIndent = style.firstLineHeadIndent
            out.append(NSAttributedString(string: "Show all \(total) lines\n", attributes: [
                .font: NSFont.systemFont(ofSize: secondary), .foregroundColor: NSColor.linkColor, .paragraphStyle: style,
                .link: ChatLink.showAll(id).url, .chatPanel: panel,
            ]))
        }
    }

    private func change(_ change: ChatChange, id: String, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        let small = NSFont.systemFont(ofSize: secondary)
        let row = NSMutableAttributedString()
        row.append(symbol(change.created ? "doc.badge.plus" : "pencil", size: secondary, color: .secondaryLabelColor,
                          label: change.created ? "Created" : "Edited"))
        row.append(NSAttributedString(string: "  " + change.path, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        row.append(NSAttributedString(string: "  +\(change.added)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
        row.append(NSAttributedString(string: " \u{2212}\(change.removed)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        row.append(NSAttributedString(string: "   ", attributes: [.font: small]))
        row.append(NSAttributedString(string: "Open Diff", attributes: [.font: small, .foregroundColor: NSColor.linkColor,
                                                                       .link: ChatLink.diff(id).url,
                                                                       .toolTip: "Show this file\u{2019}s changes in the editor"]))
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        let style = paragraph(before: 0, after: 0, lineSpacing: 2)
        style.firstLineHeadIndent = secondary + 8
        style.headIndent = secondary * 2 + 16
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        out.append(row)
    }

    private func plan(_ entries: [ACPSession.PlanEntry], into out: NSMutableAttributedString) {
        let head = paragraph(before: 0, after: 4)
        out.append(NSAttributedString(string: "Plan\n", attributes: [.font: NSFont.systemFont(ofSize: secondary, weight: .semibold),
                                                                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: head]))
        let font = NSFont.systemFont(ofSize: body)
        for (index, entry) in entries.enumerated() {
            let row = NSMutableAttributedString()
            let name: String
            let color: NSColor
            let word: String
            switch entry.status {
            case .pending: name = "circle"; color = .tertiaryLabelColor; word = "To do,"
            case .inProgress: name = "circle.lefthalf.filled"; color = .controlAccentColor; word = "In progress,"
            case .completed: name = "checkmark.circle.fill"; color = .secondaryLabelColor; word = "Done,"
            }
            row.append(symbol(name, size: secondary, color: color, label: word))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if entry.status == .completed {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
            }
            row.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            row.append(NSAttributedString(string: entry.content, attributes: attributes))
            row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            let style = paragraph(before: 0, after: index == entries.count - 1 ? 0 : 3, lineSpacing: 2)
            style.headIndent = secondary + 8
            row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
            out.append(row)
        }
    }

    private func answered(_ action: String, answer: String, outcome: ChatTranscript.Outcome, into out: NSMutableAttributedString) {
        let name: String
        let color: NSColor
        switch outcome {
        case .allowed: name = "checkmark.shield"; color = .secondaryLabelColor
        case .rejected: name = "xmark.shield"; color = .systemRed
        case .cancelled: name = "minus.circle"; color = .tertiaryLabelColor
        case .answered: name = "text.bubble"; color = .secondaryLabelColor
        }
        let row = NSMutableAttributedString()
        row.append(symbol(name, size: secondary, color: color, label: nil))
        row.append(NSAttributedString(string: "  " + ChatTranscript.answerLine(action: action, answer: answer) + "\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: secondary), .foregroundColor: NSColor.secondaryLabelColor]))
        let style = paragraph(before: 0, after: 0, lineSpacing: 2)
        style.headIndent = secondary + 8
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        out.append(row)
    }

    private func note(_ text: String, tone: ChatTranscript.Tone, into out: NSMutableAttributedString) {
        let name: String
        let color: NSColor
        switch tone {
        case .info: name = "info.circle"; color = .tertiaryLabelColor
        case .warning: name = "exclamationmark.triangle"; color = .systemOrange
        case .error: name = "xmark.octagon"; color = .systemRed
        }
        let font = NSFont.systemFont(ofSize: secondary)
        let row = NSMutableAttributedString()
        row.append(symbol(name, size: secondary, color: color, label: tone == .info ? nil : (tone == .error ? "Error:" : "Warning:")))
        let words = NSMutableAttributedString(string: "  " + text + "\n", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        // A terminal-only command's note links its Open in Terminal (R4).
        let offer = (words.string as NSString).range(of: "Open in Terminal")
        if offersTerminal, offer.location != NSNotFound {
            words.addAttributes([.link: ChatLink.openInTerminal.url, .foregroundColor: NSColor.linkColor], range: offer)
        }
        row.append(words)
        let style = paragraph(before: 0, after: 0, lineSpacing: 2)
        style.headIndent = secondary + 8
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        out.append(row)
    }

    private func turnEnded(_ words: String, usage: String?, reason: ACPSession.StopReason, into out: NSMutableAttributedString) {
        let font = NSFont.systemFont(ofSize: secondary)
        let color: NSColor = reason == .endTurn ? .tertiaryLabelColor : .secondaryLabelColor
        let text = words + (usage.map { "  \u{00B7}  " + $0 } ?? "")
        out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color,
                                                                       .paragraphStyle: paragraph(before: 0, after: 6),
                                                                       .chatPanel: ChatPanel(.rule)]))
    }

    // MARK: pieces

    func paragraph(before: CGFloat, after: CGFloat, lineSpacing: CGFloat = 2) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = lineSpacing
        return style
    }

    /// An SF Symbol as an inline image in `color`, centred on the text's capital letters. `label` is what VoiceOver
    /// reads for it; nil keeps it silent.
    func symbol(_ name: String, size: CGFloat, color: NSColor, label: String?, weight: NSFont.Weight = .regular) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration) else {
            return NSAttributedString(string: "")
        }
        image.accessibilityDescription = label
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = NSFont.systemFont(ofSize: body)
        let imageSize = image.size
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - imageSize.height) / 2).rounded(), width: imageSize.width, height: imageSize.height)
        return NSAttributedString(attachment: attachment)
    }

    /// The block's first paragraph keeps `gap` above itself.
    static func setGap(_ gap: CGFloat, on text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        let first = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let current = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
        guard let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacingBefore = gap
        text.addAttribute(.paragraphStyle, value: style, range: first)
    }
}
