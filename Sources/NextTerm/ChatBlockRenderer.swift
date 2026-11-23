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
    /// A tool title longer than this (in characters) is shown whole above its unfolded output.
    static let wholeCommandAfter = 60
    /// Tools whose whole output is drawn, past the cap.
    var showAll: Set<String> = []
    /// The handoff exists for this chat (Claude Code or Codex): a terminal-only note links to it.
    var offersTerminal = false


    private var body: CGFloat { CGFloat(sizes.body) }
    private var secondary: CGFloat { CGFloat(sizes.secondary) }
    private var mono: CGFloat { CGFloat(sizes.monospaced) }

    /// The space a block keeps above itself, by what comes before it.
    func gap(_ block: ChatBlock, after previous: ChatBlock?) -> CGFloat {
        guard let previous else { return 2 }
        let before = Spacing(previous)
        switch block.content {
        case .prompt: return 26
        case .message: return before == .prompt ? 20 : (before == .row ? 10 : 8)
        case .turnEnded: return 12
        case .plan: return 12
        case .note: return before == .row || before == .note ? 4 : 10
        default:
            if Spacing(block) == .row { return before == .row ? 4 : (before == .prompt ? 18 : 10) }
            return 8
        }
    }

    /// A block's kind, for spacing: thoughts, tools, file changes and answers are all compact rows.
    private enum Spacing {
        case prompt, message, row, plan, turnEnd, note

        init(_ block: ChatBlock) {
            switch block.content {
            case .prompt: self = .prompt
            case .message: self = .message
            case .thought, .tool, .group, .change, .answered: self = .row
            case .plan: self = .plan
            case .turnEnded: self = .turnEnd
            case .note: self = .note
            }
        }
    }

    /// Where a row's text starts after its status symbol, and where its wrapped lines line up.
    private var rowIndent: CGFloat { secondary + 8 }

    /// A row's height: one line, at about 1.45 times the row's own size (Practical Typography's 120–145%), so a run of
    /// tool rows reads as a calm list rather than a wall.
    private var rowLine: CGFloat { (max(mono, secondary) * 1.45).rounded() }

    /// A row's paragraph: no space of its own, the text after the symbol at one tab stop so every row's text starts on
    /// the same edge, whatever its symbol's width.
    private func rowParagraph(after: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = paragraph(before: 0, after: after, lineSpacing: 0)
        style.headIndent = rowIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: rowIndent)]
        style.defaultTabInterval = rowIndent
        return style
    }

    /// A compact row's paragraph: one line, cut with an ellipsis at the column's edge (the whole text is the row's
    /// tooltip, and an unfolded tool shows its whole command above the output).
    private func singleLineRow() -> NSMutableParagraphStyle {
        let style = rowParagraph()
        style.minimumLineHeight = rowLine
        style.maximumLineHeight = rowLine
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    func render(_ block: ChatBlock, after previous: ChatBlock?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch block.content {
        case .prompt(let text): prompt(text, into: out)
        case .message(let markdown, _): message(markdown, into: out)
        case .thought(let thought): self.thought(thought, id: block.id, into: out)
        case .tool(let tool): self.tool(tool, id: block.id, into: out)
        case .group(let group): self.group(group, id: block.id, into: out)
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
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: Theme.system(.label),
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
        // Code wraps by character: a long command or path breaks at the column's edge, never past it.
        text.enumerateAttribute(.chatPanel, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard (value as? ChatPanel)?.kind == .code else { return }
            Self.charWrap(text, in: range)
        }
        // Web links read as links; Next Term's own rows set their own colours.
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            text.addAttribute(.foregroundColor, value: Theme.system(.link), range: range)
        }
        out.append(text)
        if out.length == 0 { out.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: body)])) }
    }

    private func thought(_ thought: ChatThought, id: String, into out: NSMutableAttributedString) {
        let font = NSFontManager.shared.convert(.systemFont(ofSize: secondary), toHaveTrait: .italicFontMask)
        let row = NSMutableAttributedString()
        row.append(symbol(thought.folded ? "chevron.right" : "chevron.down", size: secondary - 2, color: Theme.system(.tertiaryLabel),
                          label: thought.folded ? "Folded" : "Unfolded", weight: .semibold, on: font))
        row.append(NSAttributedString(string: "\t" + thought.title, attributes: [.font: font, .foregroundColor: Theme.system(.secondaryLabel)]))
        row.addAttribute(.link, value: ChatLink.toggle(id).url, range: NSRange(location: 0, length: row.length))
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        row.addAttribute(.paragraphStyle, value: singleLineRow(), range: NSRange(location: 0, length: row.length))
        out.append(row)
        guard !thought.folded, !thought.text.isEmpty else { return }
        let text = NSFont.systemFont(ofSize: secondary)
        let lines = thought.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let panel = ChatPanel(.quote)
        for (index, line) in lines.enumerated() {
            let style = paragraph(before: index == 0 ? 6 : 0, after: index == lines.count - 1 ? 4 : 0, lineSpacing: 2)
            style.firstLineHeadIndent = rowIndent
            style.headIndent = rowIndent
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: text, .foregroundColor: Theme.system(.secondaryLabel),
                                                                           .paragraphStyle: style, .chatPanel: panel]))
        }
    }

    /// Finished look-ups as one row; unfolded, its members follow as their own rows, set in by one more slot.
    private func group(_ group: ChatToolGroup, id: String, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        let row = NSMutableAttributedString()
        row.append(symbol(group.expanded ? "chevron.down" : "chevron.right", size: secondary - 2, color: Theme.system(.tertiaryLabel),
                          label: group.expanded ? "Unfolded," : "Folded,", weight: .semibold, on: font))
        row.append(NSAttributedString(string: "\t" + group.title, attributes: [.font: font, .foregroundColor: Theme.system(.secondaryLabel)]))
        let whole = NSRange(location: 0, length: row.length)
        row.addAttribute(.link, value: ChatLink.toggle(id).url, range: whole)
        let files = group.tools.map(\.shownTitle).joined(separator: "\n")
        row.addAttribute(.toolTip, value: files + "\n\n" + (group.expanded ? "Click to fold" : "Click to show each one"), range: whole)
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        let style = singleLineRow()
        style.lineBreakMode = .byTruncatingTail
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        out.append(row)
        guard group.expanded else { return }
        for member in group.members {
            guard case .tool(let tool) = member.content else { continue }
            let text = NSMutableAttributedString()
            self.tool(tool, id: member.id, into: text)
            // One slot further in: the members read as the group's.
            text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.firstLineHeadIndent += rowIndent
                style.headIndent += rowIndent
                style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + rowIndent) }
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
            out.append(text)
        }
    }

    private func tool(_ tool: ChatTool, id: String, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        let row = NSMutableAttributedString()
        let color: NSColor
        switch tool.status {
        case .pending: color = Theme.system(.tertiaryLabel)
        case .inProgress: color = Theme.system(.accent)
        case .completed: color = Theme.system(.secondaryLabel)
        case .failed: color = Theme.system(.red)
        }
        // VoiceOver reads the symbol's description first: "Done, Bash(npm test)".
        row.append(symbol(tool.symbolName, size: secondary, color: color, label: tool.statusWord.capitalized + ",", on: font))
        let title = ChatTool.withoutStyleCodes(tool.shownTitle).replacingOccurrences(of: "\n", with: " ")
        row.append(NSAttributedString(string: "\t" + title, attributes: [.font: font,
                                                                        .foregroundColor: tool.status == .failed ? Theme.system(.red) : Theme.system(.label)]))
        // One line, the whole command in the tooltip; a click unfolds the output (with the whole command above it).
        let opens = !tool.output.isEmpty
        let whole = NSRange(location: 0, length: row.length)
        if opens {
            row.addAttribute(.link, value: ChatLink.toggle(id).url, range: whole)
            row.addAttribute(.toolTip, value: title + "\n\n" + (tool.expanded ? "Click to hide the output" : "Click to show the output"), range: whole)
        } else {
            row.addAttribute(.toolTip, value: title, range: whole)
        }
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        // A command is known by its start; a file by its name, at the end: cut in the middle so the name stays.
        let rowStyle = singleLineRow()
        if tool.kind != "execute" { rowStyle.lineBreakMode = .byTruncatingMiddle }
        row.addAttribute(.paragraphStyle, value: rowStyle, range: NSRange(location: 0, length: row.length))
        out.append(row)
        guard tool.expanded, opens else { return }
        // Lines, line length and characters are all capped before Show all (ChatTool.shownOutput).
        let shown = tool.shownOutput(all: showAll.contains(id))
        let lines = shown.lines
        let total = shown.totalLines
        let capped = shown.capped
        let panel = ChatPanel(.detail)
        let detail = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        // The row shows one line of the command: the panel opens with all of it, in secondary text.
        if title.count > Self.wholeCommandAfter {
            let style = paragraph(before: 10, after: 6, lineSpacing: 1)
            style.firstLineHeadIndent = rowIndent + 10
            style.headIndent = style.firstLineHeadIndent
            style.tailIndent = -10
            style.lineBreakMode = .byCharWrapping
            out.append(NSAttributedString(string: title + "\n", attributes: [.font: detail, .foregroundColor: Theme.system(.secondaryLabel),
                                                                              .paragraphStyle: style, .chatPanel: panel]))
        }
        let opened = title.count > Self.wholeCommandAfter
        for (index, line) in lines.enumerated() {
            let last = index == lines.count - 1 && !capped
            let style = paragraph(before: index == 0 && !opened ? 10 : 0, after: last ? 10 : 0, lineSpacing: 1)
            style.firstLineHeadIndent = rowIndent + 10
            style.headIndent = style.firstLineHeadIndent
            style.tailIndent = -10
            style.lineBreakMode = .byCharWrapping
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: detail, .foregroundColor: Theme.system(.label),
                                                                           .paragraphStyle: style, .chatPanel: panel]))
        }
        if capped {
            let style = paragraph(before: 4, after: 10)
            style.firstLineHeadIndent = rowIndent + 10
            style.headIndent = style.firstLineHeadIndent
            let words = shown.linesLeftOut ? "Show all \(total) lines" : "Show the whole output"
            out.append(NSAttributedString(string: words + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: secondary), .foregroundColor: Theme.system(.link), .paragraphStyle: style,
                .link: ChatLink.showAll(id).url, .chatPanel: panel,
            ]))
        }
    }

    private func change(_ change: ChatChange, id: String, into out: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
        let small = NSFont.systemFont(ofSize: secondary)
        let row = NSMutableAttributedString()
        row.append(symbol(change.created ? "doc.badge.plus" : "pencil", size: secondary, color: Theme.system(.secondaryLabel),
                          label: change.created ? "Created" : "Edited", on: font))
        row.append(NSAttributedString(string: "\t" + change.path, attributes: [.font: font, .foregroundColor: Theme.system(.label)]))
        row.append(NSAttributedString(string: "  +\(change.added)", attributes: [.font: font, .foregroundColor: Theme.system(.green)]))
        row.append(NSAttributedString(string: " \u{2212}\(change.removed)", attributes: [.font: font, .foregroundColor: Theme.system(.red)]))
        row.append(NSAttributedString(string: "   ", attributes: [.font: small]))
        row.append(NSAttributedString(string: "Open Diff", attributes: [.font: small, .foregroundColor: Theme.system(.link),
                                                                       .link: ChatLink.diff(id).url,
                                                                       .toolTip: "Show this file\u{2019}s changes in the editor"]))
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        let style = rowParagraph()
        style.minimumLineHeight = rowLine
        style.lineBreakMode = .byCharWrapping
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        out.append(row)
    }

    private func plan(_ entries: [ACPSession.PlanEntry], into out: NSMutableAttributedString) {
        let head = paragraph(before: 0, after: 4)
        out.append(NSAttributedString(string: "Plan\n", attributes: [.font: NSFont.systemFont(ofSize: secondary, weight: .semibold),
                                                                    .foregroundColor: Theme.system(.secondaryLabel), .paragraphStyle: head]))
        let font = NSFont.systemFont(ofSize: body)
        for (index, entry) in entries.enumerated() {
            let row = NSMutableAttributedString()
            let name: String
            let color: NSColor
            let word: String
            switch entry.status {
            case .pending: name = "circle"; color = Theme.system(.tertiaryLabel); word = "To do,"
            case .inProgress: name = "circle.lefthalf.filled"; color = Theme.system(.accent); word = "In progress,"
            case .completed: name = "checkmark.circle.fill"; color = Theme.system(.secondaryLabel); word = "Done,"
            }
            row.append(symbol(name, size: secondary, color: color, label: word))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.system(.label)]
            if entry.status == .completed {
                attributes[.foregroundColor] = Theme.system(.secondaryLabel)
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = Theme.system(.tertiaryLabel)
            }
            row.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            row.append(NSAttributedString(string: entry.content, attributes: attributes))
            row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            row.addAttribute(.paragraphStyle, value: rowParagraph(after: index == entries.count - 1 ? 0 : 3),
                             range: NSRange(location: 0, length: row.length))
            out.append(row)
        }
    }

    private func answered(_ action: String, answer: String, outcome: ChatTranscript.Outcome, into out: NSMutableAttributedString) {
        let name: String
        let color: NSColor
        switch outcome {
        case .allowed: name = "checkmark.shield"; color = Theme.system(.secondaryLabel)
        case .rejected: name = "xmark.shield"; color = Theme.system(.red)
        case .cancelled: name = "minus.circle"; color = Theme.system(.tertiaryLabel)
        case .answered: name = "text.bubble"; color = Theme.system(.secondaryLabel)
        }
        let row = NSMutableAttributedString()
        row.append(symbol(name, size: secondary, color: color, label: nil, on: NSFont.systemFont(ofSize: secondary)))
        row.append(NSAttributedString(string: "\t" + ChatTranscript.answerLine(action: action, answer: answer) + "\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: secondary), .foregroundColor: Theme.system(.secondaryLabel)]))
        row.addAttribute(.paragraphStyle, value: rowParagraph(), range: NSRange(location: 0, length: row.length))
        out.append(row)
    }

    private func note(_ text: String, tone: ChatTranscript.Tone, into out: NSMutableAttributedString) {
        let name: String
        let color: NSColor
        switch tone {
        case .info: name = "info.circle"; color = Theme.system(.tertiaryLabel)
        case .warning: name = "exclamationmark.triangle"; color = Theme.system(.orange)
        case .error: name = "xmark.octagon"; color = Theme.system(.red)
        }
        let font = NSFont.systemFont(ofSize: secondary)
        let row = NSMutableAttributedString()
        row.append(symbol(name, size: secondary, color: color, label: tone == .info ? nil : (tone == .error ? "Error:" : "Warning:")))
        let words = NSMutableAttributedString(string: "  " + text + "\n", attributes: [.font: font, .foregroundColor: Theme.system(.secondaryLabel)])
        // A terminal-only command's note links its Open in Terminal (R4).
        let offer = (words.string as NSString).range(of: "Open in Terminal")
        if offersTerminal, offer.location != NSNotFound {
            words.addAttributes([.link: ChatLink.openInTerminal.url, .foregroundColor: Theme.system(.link)], range: offer)
        }
        row.append(words)
        row.addAttribute(.paragraphStyle, value: rowParagraph(), range: NSRange(location: 0, length: row.length))
        out.append(row)
    }

    private func turnEnded(_ words: String, usage: String?, reason: ACPSession.StopReason, into out: NSMutableAttributedString) {
        let font = NSFont.systemFont(ofSize: secondary)
        let color: NSColor = reason == .endTurn ? Theme.system(.tertiaryLabel) : Theme.system(.secondaryLabel)
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
    func symbol(_ name: String, size: CGFloat, color: NSColor, label: String?, weight: NSFont.Weight = .regular,
                on rowFont: NSFont? = nil) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration) else {
            return NSAttributedString(string: "")
        }
        image.accessibilityDescription = label
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centred on the capitals of the text it sits beside (the row's own font), so a symbol lines up with its text.
        let font = rowFont ?? NSFont.systemFont(ofSize: body)
        let imageSize = image.size
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
        return NSAttributedString(attachment: attachment)
    }

    /// The paragraphs in `range` wrap by character (code, paths, tool output).
    static func charWrap(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, part, _ in
            let current = value as? NSParagraphStyle ?? NSParagraphStyle.default
            guard current.lineBreakMode != .byCharWrapping, let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.lineBreakMode = .byCharWrapping
            text.addAttribute(.paragraphStyle, value: style, range: part)
        }
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
