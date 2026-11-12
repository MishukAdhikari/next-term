import AppKit
import NextTermCore

/// A native box under a tab's terminal for writing to the agent (or program) in it (plan 039 U2). It grows from one
/// line to eight, then scrolls. Return sends the text as one paste and then Return, so a prompt of many lines arrives
/// whole; ⇧Return and ⌥Return add a line. Esc in an empty box goes to the terminal (an agent stops on it). ↑ in an empty
/// box brings back what was sent last. Files dropped on it, or pasted from Finder, go in as their paths, quoted, as a
/// drop on the terminal types them; on a server they are copied there first. An image pasted alone goes to the program
/// as a ⌘V in the terminal would. "/" is the agent's own: its command list shows in the terminal once the text is sent.
/// View › Prompt Box shows it for a tab; its key moves the keyboard between it and the terminal.
final class AgentPromptBox: NSView, NSTextViewDelegate {
    let textView = PromptTextView()
    private let scroll = NSScrollView()
    private let send = NSButton()
    private var heightConstraint: NSLayoutConstraint?
    private weak var tab: TerminalTab?
    /// What was sent last, for ↑.
    private var last: String?

    init(tab: TerminalTab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.delegate = self
        textView.owner = self
        textView.registerForDraggedTypes([.fileURL])
        textView.setAccessibilityLabel("Prompt")
        textView.setAccessibilityRoleDescription("prompt box")

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        send.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        send.isBordered = false
        send.imagePosition = .imageOnly
        send.target = self
        send.action = #selector(sendClicked)
        send.toolTip = "Send (Return)"
        send.setAccessibilityLabel("Send")
        send.translatesAutoresizingMaskIntoConstraints = false
        send.refusesFirstResponder = true
        addSubview(send)

        let height = scroll.heightAnchor.constraint(equalToConstant: 18)
        heightConstraint = height
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            height,
            send.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            send.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            send.widthAnchor.constraint(equalToConstant: 22),
            send.heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(false)
        refreshPlaceholder()
        textChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// "Message Claude Code", or "Type a command" with no agent in the tab.
    func refreshPlaceholder() {
        let words = tab?.localAgent.map { "Message \($0.name)" } ?? "Type to the terminal"
        let placeholder = words + "  ·  Return sends, ⇧Return adds a line"
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.setAccessibilityHelp(placeholder)
        }
    }

    // MARK: sending

    @objc private func sendClicked() { submit() }

    /// Return: the text as one paste, then Return a moment later (as `send_to_tab` does), and the box empties.
    func submit() {
        let text = textView.string
        guard let tab, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, MCPControl.canType(tab) else { return }
        tab.view.onKeyboard?() // the user's own input, as a key in the terminal is
        tab.view.typeText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak tab] in
            guard let tab, MCPControl.canType(tab) else { return }
            tab.view.send(txt: "\r")
        }
        last = text
        textView.string = ""
        textChanged()
    }

    /// Esc in an empty box: the terminal gets it.
    fileprivate func escape() {
        guard let tab, MCPControl.canType(tab) else { return }
        tab.view.send(txt: "\u{1b}")
    }

    fileprivate func recall() -> String? { last }

    /// Moves the keyboard to the terminal.
    func giveKeyboardToTerminal() {
        guard let tab else { return }
        window?.makeFirstResponder(tab.view)
    }

    // MARK: drops and pastes

    /// Files from a drop or from Finder's copy: their paths, quoted, where the cursor is; on a server the files are
    /// copied there first and typed into the terminal (the box can't hold a path that doesn't exist yet).
    fileprivate func insert(files: [String]) -> Bool {
        guard let tab, !files.isEmpty else { return false }
        if let remote = tab.view.onRemoteDrop {
            remote(files.map { URL(fileURLWithPath: $0) })
            return true
        }
        let text = files.map(ShellQuote.quote).joined(separator: " ") + " "
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }

    /// An image pasted alone: to the program, as ⌘V in the terminal hands it on.
    fileprivate func pasteImage() {
        tab?.view.onImagePaste?()
    }

    // MARK: size

    func textDidChange(_ notification: Notification) { textChanged() }

    private func textChanged() {
        fitHeight()
        let ready = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = ready
        send.contentTintColor = ready ? .controlAccentColor : .tertiaryLabelColor
        textView.needsDisplay = true
    }

    /// One to eight lines tall, then the box scrolls.
    private func fitHeight() {
        guard let layout = textView.layoutManager, let container = textView.textContainer, let font = textView.font else { return }
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let used = max(layout.usedRect(for: container).height, line)
        let height = min(used, line * 8).rounded(.up)
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
        scroll.hasVerticalScroller = used > line * 8
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        path.fill()
        let focused = window?.firstResponder === textView && window?.isKeyWindow == true
        (focused ? NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.6) : NSColor.separatorColor).setStroke()
        path.lineWidth = focused ? 1.5 : 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    /// For the self-test.
    var text: String {
        get { textView.string }
        set { textView.string = newValue; textChanged() }
    }
}

/// The prompt box's text view: Return, Esc and ↑ as `AgentPromptBox` describes, file drops and Finder pastes as paths,
/// an image pasted alone to the program, and the placeholder drawn while empty.
final class PromptTextView: NSTextView {
    weak var owner: AgentPromptBox?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override func becomeFirstResponder() -> Bool {
        let made = super.becomeFirstResponder()
        owner?.needsDisplay = true
        owner?.refreshPlaceholder()
        return made
    }

    override func resignFirstResponder() -> Bool {
        let made = super.resignFirstResponder()
        owner?.needsDisplay = true
        return made
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { return insertNewlineIgnoringFieldEditor(nil) }
            owner?.submit()
        case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            insertNewlineIgnoringFieldEditor(nil)
        case #selector(cancelOperation(_:)):
            escapePressed()
        case #selector(moveUp(_:)):
            if string.isEmpty, let last = owner?.recall(), !last.isEmpty {
                string = last
                setSelectedRange(NSRange(location: (last as NSString).length, length: 0))
                didChangeText()
            } else {
                super.doCommand(by: selector)
            }
        default:
            super.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) { escapePressed() }

    /// Esc: an empty box sends it to the terminal (an agent stops on it); else the text's selection goes, as Esc does.
    private func escapePressed() {
        if string.isEmpty { owner?.escape() } else { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
    }

    // A drop of files: their paths.
    private func files(_ board: NSPasteboard) -> [String] {
        ((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = files(sender.draggingPasteboard)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        window?.makeFirstResponder(self)
        return owner?.insert(files: paths) ?? false
    }

    /// ⌘V: Finder's files as paths, an image alone to the program, text as text.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let paths = files(board)
        let text = board.string(forType: .string)
        switch PasteContent.choose(files: paths, text: text, image: board.availableType(from: [.png, .tiff]) != nil) {
        case .files: _ = owner?.insert(files: paths)
        case .image: owner?.pasteImage()
        case .text: pasteAsPlainText(sender)
        case .nothing: return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let text = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
        let origin = textContainerOrigin
        text.draw(with: NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: bounds.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension TerminalWindowController {
    /// The pane of the tab with the keyboard.
    private var activePane: PaneView? {
        guard let tab = activeTab, let group = groups.first(where: { $0.contains(tab) }) else { return nil }
        return group.paneView(tab)
    }

    /// View › Prompt Box (⇧⌘I): shows the box under the terminal and gives it the keyboard; with the box shown, the
    /// keyboard moves to it; from the box, it hides and the terminal takes the keyboard back.
    @objc func togglePromptBox(_ sender: Any?) {
        guard let pane = activePane else { return }
        guard let box = pane.promptBox, pane.showsPromptBox else { return pane.setPromptBox(shown: true) }
        if window?.firstResponder === box.textView { pane.setPromptBox(shown: false) } else { window?.makeFirstResponder(box.textView) }
    }

    /// Checked while the tab with the keyboard shows its prompt box.
    func promptBoxShown() -> Bool { activePane?.showsPromptBox == true }
}
