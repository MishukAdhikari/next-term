import AppKit
import NextTermCore

/// The blame column's fonts and where its three parts go: the author on the left, then the date, then
/// the short hash against the line numbers.
struct BlameStyle {
    let font: NSFont
    let hashFont: NSFont
    let width: CGFloat
    let author: NSRect
    let date: NSRect
    let hash: NSRect

    init(font numbers: NSFont, width: CGFloat) {
        font = .systemFont(ofSize: numbers.pointSize - 0.5)
        hashFont = .monospacedSystemFont(ofSize: numbers.pointSize - 1, weight: .regular)
        self.width = width
        let hashWidth = ceil(("0000000" as NSString).size(withAttributes: [.font: hashFont]).width)
        let dateWidth = ceil(("11mo" as NSString).size(withAttributes: [.font: font]).width)
        hash = NSRect(x: width - 12 - hashWidth, y: 0, width: hashWidth, height: 0)
        date = NSRect(x: hash.minX - 8 - dateWidth, y: 0, width: dateWidth, height: 0)
        author = NSRect(x: 8, y: 0, width: max(0, date.minX - 6 - 8), height: 0)
    }
}

/// The words the blame shows: the column, the caret line's note, the hover text.
enum BlameText {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    /// “3 days ago”, or “just now”.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// The column's text on a line, as plain text: “Ann  2d  abc1234” on the first line of a commit's
    /// run of lines, “Not committed” on new ones, and nothing on the rest.
    static func column(_ blame: EditedBlame, line: Int) -> String {
        guard let entry = blame.line(line), blame.isBlockStart(line) else { return "" }
        guard let commit = blame.blame.commit(entry) else { return "Not committed" }
        return "\(commit.shortAuthor)  \(Blame.compactAge(of: commit.authorTime))  \(commit.shortSHA)"
    }

    /// The hover text for a line's commit.
    static func toolTip(_ blame: EditedBlame, line: Int) -> String {
        guard let entry = blame.line(line) else { return "" }
        guard let commit = blame.blame.commit(entry) else { return "Not committed yet: changed since the last commit" }
        let author = commit.authorMail.isEmpty ? commit.author : "\(commit.author) <\(commit.authorMail)>"
        return """
        \(commit.summary)
        \(author)
        \(dateFormatter.string(from: commit.authorTime)) (\(relative(commit.authorTime)))
        \(commit.sha)
        Click to show the commit
        """
    }
}

extension LineNumberRuler: NSViewToolTipOwner {
    /// The blame column's width, in step with the font size.
    var blameWidth: CGFloat { ceil(numberFont.pointSize * 16) }

    /// One line's part of the column: its shade by age (newer is brighter; not committed in the change
    /// colour), and on the first line of a commit's run, who, when and which commit.
    func drawBlame(_ blame: EditedBlame, line: Int, in rect: NSRect, rowHeight: CGFloat, style: BlameStyle) {
        guard let entry = blame.line(line) else { return }
        let commit = blame.blame.commit(entry)
        let shade = commit.map { Theme.blameRecent.withAlphaComponent(0.04 + 0.16 * blame.recency(of: $0)) }
            ?? Theme.gitModified.withAlphaComponent(0.12)
        shade.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width - 1, height: rect.height).fill()
        Theme.bar.setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill() // against the numbers
        guard blame.isBlockStart(line) else { return }
        if line > 0 { NSRect(x: rect.minX, y: rect.minY, width: rect.width - 1, height: 1).fill() } // between commits

        func put(_ text: String, in slot: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .natural) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
                                                             .paragraphStyle: Typography.paragraph(.byTruncatingTail, alignment: alignment)]
            let height = ceil(font.ascender - font.descender + font.leading)
            let frame = NSRect(x: slot.minX, y: rect.minY + (rowHeight - height) / 2, width: slot.width, height: height)
            (text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
        guard let commit else {
            let all = NSRect(x: style.author.minX, y: 0, width: style.hash.maxX - style.author.minX, height: 0)
            return put("Not committed", in: all, font: style.font, color: Theme.gitModified.withAlphaComponent(0.8))
        }
        put(commit.shortAuthor, in: style.author, font: style.font, color: Theme.blameText)
        put(Blame.compactAge(of: commit.authorTime), in: style.date, font: style.font, color: Theme.blameText, alignment: .right)
        put(commit.shortSHA, in: style.hash, font: style.hashFont, color: Theme.blameHash, alignment: .right)
    }

    /// Hover areas follow what is on screen; they change only when it scrolls or the blame changes.
    func setBlameToolTips(_ rects: [NSRect]) {
        guard rects != blameToolTipRects else { return }
        blameToolTipRects = rects
        guard !blameToolTipsQueued else { return }
        blameToolTipsQueued = true
        // Not while drawing: AppKit updates its tool tips outside the draw.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.blameToolTipsQueued = false
            self.removeAllToolTips()
            for rect in self.blameToolTipRects { self.addToolTip(rect, owner: self, userData: nil) }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard showsBlame, let line = line(at: point), let blame = blameSource?() else { return "" }
        return BlameText.toolTip(blame, line: line)
    }

    /// The line beside a point in the ruler.
    func line(at point: NSPoint) -> Int? {
        guard let view = clientView as? CodeTextView, let document = view.document, let layoutManager = view.layoutManager,
              let container = view.textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let inText = view.convert(point, from: self)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: inText.y - view.textContainerOrigin.y), in: container)
        return document.lines.line(at: layoutManager.characterIndexForGlyph(at: glyph))
    }

    /// The gutter's right-click menu: blame on or off, and the commit of the lines clicked.
    func blameMenu(at point: NSPoint) -> NSMenu {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "Annotate with Git Blame", action: #selector(AppDelegate.toggleBlameAnnotations(_:)), keyEquivalent: "")
        toggle.target = AppDelegate.shared
        if showsBlame, point.x < blameWidth, let line = line(at: point), let blame = blameSource?(), let commit = blame.commit(at: line) {
            menu.addItem(.separator())
            let show = menu.addItem(withTitle: "Show Commit \(commit.shortSHA)", action: #selector(showBlameCommit(_:)), keyEquivalent: "")
            let copy = menu.addItem(withTitle: "Copy Commit Hash", action: #selector(copyBlameHash(_:)), keyEquivalent: "")
            for item in [show, copy] {
                item.target = self
                item.representedObject = [commit.sha, blame.blame.root]
            }
        }
        return menu
    }

    @objc private func showBlameCommit(_ item: NSMenuItem) {
        guard let target = item.representedObject as? [String], target.count == 2 else { return }
        onBlameClick?(target[0], target[1])
    }

    @objc private func copyBlameHash(_ item: NSMenuItem) {
        guard let sha = (item.representedObject as? [String])?.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha, forType: .string)
    }
}
