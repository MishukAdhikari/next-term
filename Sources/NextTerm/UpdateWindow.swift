import AppKit
import NextTermCore

/// "Next Term 0.6.0 is available": what changed in every release since this one, with Skip This
/// Version, Remind Me Later and Install and Relaunch.
///
/// Opened by the automatic check, it sits over the front window without taking the keyboard: someone
/// typing to an agent keeps typing, and a Return meant for the terminal never installs anything. A
/// click on it (or opening it from the Update button or the menu) gives it the keyboard.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    enum Choice { case install, later, skip }

    let release: ReleaseInfo
    private var onChoice: ((Choice) -> Void)?
    private weak var parentWindow: NSWindow?
    private(set) var notesView: NSTextView!
    private(set) var installButton: NSButton!
    private(set) var laterButton: NSButton!
    private(set) var skipButton: NSButton!

    init(release: ReleaseInfo, notes: [ReleaseInfo], current: AppVersion, canInstall: Bool, choice: @escaping (Choice) -> Void) {
        self.release = release
        onChoice = choice
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500), styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        window.title = "Software Update"
        window.minSize = NSSize(width: 460, height: 340)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .alertPanel
        super.init(window: window)
        window.delegate = self
        build(notes: notes, current: current, canInstall: canInstall)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var preferred: NSLayoutConstraint!

    private func build(notes: [ReleaseInfo], current: AppVersion, canInstall: Bool) {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "Next Term \(release.version) is available")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        Typography.singleLine(title, truncation: .byTruncatingTail)
        var detail = "You have \(current)."
        if let published = release.published {
            detail += " Released " + published.formatted(date: .long, time: .omitted) + "."
        }
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        Typography.singleLine(subtitle, truncation: .byTruncatingTail)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        let header = NSStackView(views: [icon, titles])
        header.alignment = .centerY
        header.spacing = 14

        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textStorage?.setAttributedString(ReleaseNotesRenderer.render(notes, fallbackPage: release.pageURL))
        text.setAccessibilityLabel("Release notes")
        notesView = text
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        // As tall as the notes, up to a point; longer notes scroll. Resizing the window still works.
        preferred = scroll.heightAnchor.constraint(equalToConstant: Self.notesHeight(text, width: 520))
        preferred.priority = .init(999) // for sizing the window below; then the window's size wins
        preferred.isActive = true

        let page = NSButton(title: notes.count > 1 ? "All release notes on GitHub" : "Release notes on GitHub",
                            target: self, action: #selector(openPage))
        page.isBordered = false
        page.contentTintColor = .linkColor
        page.font = .systemFont(ofSize: 12)
        page.toolTip = release.pageURL.absoluteString

        skipButton = NSButton(title: "Skip This Version", target: self, action: #selector(skip))
        skipButton.toolTip = "Don’t show \(release.version) again. A newer version will still be offered."
        laterButton = NSButton(title: "Remind Me Later", target: self, action: #selector(later))
        laterButton.keyEquivalent = "\u{1b}"
        laterButton.toolTip = "Ask again tomorrow. The Update button stays at the top right."
        installButton = NSButton(title: canInstall ? "Install and Relaunch" : "Download", target: self, action: #selector(install))
        installButton.keyEquivalent = "\r"
        installButton.toolTip = canInstall
            ? "Downloads \(release.version), checks it against its published checksum, and swaps it in when Next Term quits."
            : "Opens the release page to download \(release.version)."
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [skipButton, spacer, laterButton, installButton])
        buttons.spacing = 10

        let stack = NSStackView(views: [header, scroll, page, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(6, after: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window?.contentView = stack
        window?.setContentSize(NSSize(width: 560, height: stack.fittingSize.height))
        preferred.priority = .defaultLow
    }

    /// The notes' height at `width` (the text view's insets and line padding included), between 120 and
    /// 400 points. Measured on the text itself: asking the view for its layout manager would switch it
    /// to TextKit 1.
    private static func notesHeight(_ text: NSTextView, width: CGFloat) -> CGFloat {
        guard let notes = text.textStorage else { return 300 }
        let padding = 2 * (text.textContainer?.lineFragmentPadding ?? 5)
        let size = NSSize(width: width - 2 * text.textContainerInset.width - padding, height: .greatestFiniteMagnitude)
        let height = notes.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            + 2 * text.textContainerInset.height + 4
        return min(400, max(120, height.rounded(.up)))
    }

    /// Over `parent` (it moves with it and stays above it until answered), or centred on its own.
    /// `takingFocus` false leaves the keyboard where it is.
    func present(over parent: NSWindow?, takingFocus: Bool) {
        guard let window else { return }
        if window.isVisible {
            if takingFocus { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            return
        }
        if let parent, parent.isVisible, !parent.isMiniaturized {
            let size = window.frame.size
            var origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.maxY - size.height - 64)
            if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
                origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
                origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
            }
            window.setFrameOrigin(origin)
            parent.addChildWindow(window, ordered: .above)
            parentWindow = parent
            NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose(_:)), name: NSWindow.willCloseNotification, object: parent)
        } else {
            window.center()
        }
        if takingFocus {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// Its window closing would take this one with it: stay, on its own.
    @objc private func parentWillClose(_ note: Notification) {
        guard let window, let parent = note.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent)
        parent.removeChildWindow(window)
        parentWindow = nil
    }

    @objc private func openPage() { NSWorkspace.shared.open(release.pageURL) }
    @objc func install() { finish(.install) }
    @objc func later() { finish(.later) }
    @objc func skip() { finish(.skip) }

    private func finish(_ choice: Choice) {
        let callback = onChoice
        onChoice = nil
        dismiss()
        callback?(choice)
    }

    /// Closes without answering (a newer check replaced it).
    func dismiss() {
        onChoice = nil
        if let parent = parentWindow, let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent)
            parent.removeChildWindow(window)
        }
        parentWindow = nil
        window?.orderOut(nil)
        window?.close()
    }

    /// The close button means "not now", as Remind Me Later does.
    func windowWillClose(_ notification: Notification) {
        guard let callback = onChoice else { return }
        onChoice = nil
        if let parent = parentWindow, let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent)
            parent.removeChildWindow(window)
        }
        parentWindow = nil
        callback(.later)
    }
}

/// Release notes (GitHub Markdown) as text for the update window: headings, nested lists, code, bold,
/// italics and links. One release shows its notes; several get a heading each, newest first.
enum ReleaseNotesRenderer {
    static let bodySize: CGFloat = 13
    static let indentStep: CGFloat = 18

    static func render(_ releases: [ReleaseInfo], fallbackPage: URL) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let several = releases.count > 1
        for (index, release) in releases.enumerated() {
            if several {
                var title = "Next Term \(release.version)"
                if let date = release.published { title += "  ·  " + date.formatted(date: .abbreviated, time: .omitted) }
                append(out, title, font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor,
                       style: style(before: index == 0 ? 0 : 18, after: 6))
            }
            let blocks = ReleaseNotes.blocks(release.notes)
            if blocks.isEmpty {
                append(out, "The notes for \(release.version) are on its [release page](\(release.pageURL.absoluteString)).",
                       font: .systemFont(ofSize: bodySize), color: .secondaryLabelColor, style: style(before: 0, after: 6), markdown: true)
            }
            for block in blocks { render(block, into: out, nested: several) }
        }
        if releases.isEmpty {
            append(out, "The notes are on the [release page](\(fallbackPage.absoluteString)).",
                   font: .systemFont(ofSize: bodySize), color: .secondaryLabelColor, style: style(before: 0, after: 6), markdown: true)
        }
        // No trailing paragraph break after the last block.
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    private static func render(_ block: ReleaseNotes.Block, into out: NSMutableAttributedString, nested: Bool) {
        let body = NSFont.systemFont(ofSize: bodySize)
        switch block {
        case let .heading(level, text):
            // Under a version's own heading, the notes' headings sit one step lower.
            let size: CGFloat = level + (nested ? 1 : 0) <= 2 ? 15 : 13
            append(out, text, font: .systemFont(ofSize: size, weight: .semibold), color: .labelColor,
                   style: style(before: out.length == 0 ? 0 : 12, after: 4), markdown: true)
        case let .bullet(depth, text):
            append(out, (depth == 0 ? "•" : "◦") + "\t" + text, font: body, color: .labelColor, style: listStyle(depth), markdown: true)
        case let .numbered(depth, number, text):
            append(out, number + ".\t" + text, font: body, color: .labelColor, style: listStyle(depth), markdown: true)
        case let .paragraph(depth, text):
            let style = style(before: 0, after: 6)
            style.firstLineHeadIndent = CGFloat(depth) * indentStep
            style.headIndent = style.firstLineHeadIndent
            append(out, text, font: body, color: .labelColor, style: style, markdown: true)
        case let .code(text):
            let style = style(before: 2, after: 8)
            style.firstLineHeadIndent = 8
            style.headIndent = 8
            append(out, text, font: .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular), color: .labelColor, style: style)
        }
    }

    private static func style(before: CGFloat, after: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = 2
        return style
    }

    /// The marker hangs in the margin; wrapped lines line up with the text after it.
    private static func listStyle(_ depth: Int) -> NSMutableParagraphStyle {
        let style = style(before: 0, after: 4)
        let start = CGFloat(depth) * indentStep
        style.firstLineHeadIndent = start
        style.headIndent = start + indentStep
        style.tabStops = [NSTextTab(textAlignment: .left, location: start + indentStep)]
        style.defaultTabInterval = indentStep
        return style
    }

    private static func append(_ out: NSMutableAttributedString, _ text: String, font: NSFont, color: NSColor,
                               style: NSParagraphStyle, markdown: Bool = false) {
        let line = markdown ? inline(text, font: font, color: color) : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let piece = NSMutableAttributedString(attributedString: line)
        piece.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
        out.append(piece)
    }

    /// Bold, italics, code and links inside one block. Only web links are followed.
    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
                }
            }
            if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
                attributes[.toolTip] = link.absoluteString
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }
}

/// The blue Update button at the right of the tab bar at the window's top-right corner: shows the
/// update window again after Remind Me Later, or relaunches into an update that is ready.
final class UpdatePill: NSButton {
    static let height: CGFloat = 22
    private var symbol = "arrow.down.circle.fill"
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(title: String, symbol: String, toolTip: String) {
        self.title = title
        self.symbol = symbol
        self.toolTip = toolTip
        setAccessibilityLabel(title)
        setAccessibilityHelp(toolTip)
        needsDisplay = true
    }

    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white])
    }

    var width: CGFloat { (label.size().width + 12 + 5 + 2 * 10).rounded(.up) }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: 0, y: ((bounds.height - Self.height) / 2).rounded(), width: bounds.width, height: Self.height)
        let fill = isHighlighted ? Theme.accent.blended(withFraction: 0.25, of: .black) ?? Theme.accent : Theme.accent
        fill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
        var x: CGFloat = 10
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [Theme.accent, .white]))) {
            let size = image.size
            image.draw(in: NSRect(x: x, y: pill.midY - size.height / 2, width: size.width, height: size.height))
            x += size.width + 5
        }
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: pill.midY - size.height / 2))
    }
}
