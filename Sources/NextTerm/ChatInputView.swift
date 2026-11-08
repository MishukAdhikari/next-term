import AppKit
import NextTermCore

/// A chat tab's input box (plan 037 R4, KTD6): a native multi-line text view in a rounded field that grows from one
/// line to eight, then scrolls. Return sends; ⇧Return and ⌥Return add a line; Esc and ⌘. stop a running turn; ↑ in an
/// empty box recalls the last prompt; "/" offers the agent's commands; Tab moves to the card or the transcript. The
/// draft is kept while a turn runs and across restarts. The placeholder says what the session waits on.
final class ChatInputView: NSView, NSTextViewDelegate {
    let textView = ChatInputTextView()
    private let scroll = NSScrollView()
    private let send = NSButton()
    private var heightConstraint: NSLayoutConstraint?
    private var sizes = ChatTextSizes(base: ChatTextSizes.standard)
    private(set) var canSend = false
    /// What the box was last shown with, and the text it held then: a refresh that brings nothing new (a streamed
    /// chunk) sets nothing.
    private var shown: Shown?

    private struct Shown: Equatable {
        let state: ChatInputState
        let draft: String
        let sizes: ChatTextSizes
        let text: String
    }

    /// Return pressed with `text` in the box.
    var onSend: ((String) -> Void)?
    /// Esc or ⌘. with a turn running.
    var onStop: (() -> Void)?
    /// The draft changed (typed, pasted, recalled).
    var onDraft: ((String) -> Void)?
    /// The last prompt, for ↑ in an empty box.
    var lastPrompt: (() -> String?)?
    /// The agent's commands, for "/".
    var commands: (() -> [String])?
    /// Whether Esc stops something now.
    var turnRuns: (() -> Bool)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.owner = self
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityRoleDescription("message box")

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// What the box shows: `state`'s placeholder and whether Return sends; `draft` when the box differs from it and
    /// isn't mid-composition (a draft set over MCP, or restored).
    func show(_ state: ChatInputState, draft: String, sizes: ChatTextSizes) {
        guard Shown(state: state, draft: draft, sizes: sizes, text: textView.string) != shown else { return }
        defer { shown = Shown(state: state, draft: draft, sizes: sizes, text: textView.string) }
        canSend = state.canSend
        if self.sizes != sizes || textView.font == nil {
            self.sizes = sizes
            textView.font = .systemFont(ofSize: CGFloat(sizes.body))
            textView.typingAttributes[.font] = textView.font
            fitHeight()
        }
        textView.textColor = .textColor
        textView.placeholder = state.placeholder
        textView.setAccessibilityHelp(state.placeholder)
        if textView.string != draft, !textView.hasMarkedText() {
            textView.string = draft
            fitHeight()
        }
        updateSend()
        textView.needsDisplay = true
    }

    private func updateSend() {
        let ready = canSend && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = ready
        send.contentTintColor = ready ? .controlAccentColor : .tertiaryLabelColor
    }

    @objc private func sendClicked() { submit() }

    /// Return: the text goes to the host, which says whether it was sent.
    func submit() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend?(text)
    }

    /// The prompt went: the box empties.
    func clear() {
        textView.string = ""
        textChanged()
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
        textView.offerCommandsIfTyping()
    }

    private func textChanged() {
        onDraft?(textView.string)
        fitHeight()
        updateSend()
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
}

/// The input box's text view: Return, Esc, ↑ and Tab as `ChatInputView` describes, the placeholder drawn while empty,
/// and the agent's commands as the completion list while the box holds only a "/" word.
final class ChatInputTextView: NSTextView {
    weak var owner: ChatInputView?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    private var completing = false

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
    }

    override func becomeFirstResponder() -> Bool {
        let made = super.becomeFirstResponder()
        owner?.needsDisplay = true
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
            stop()
        case #selector(moveUp(_:)):
            if string.isEmpty, let last = owner?.lastPrompt?(), !last.isEmpty {
                string = last
                setSelectedRange(NSRange(location: (last as NSString).length, length: 0))
                didChangeText()
            } else {
                super.doCommand(by: selector)
            }
        case #selector(insertTab(_:)):
            window?.selectNextKeyView(nil)
        case #selector(insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
        case #selector(insertTabIgnoringFieldEditor(_:)):
            insertText("\t", replacementRange: selectedRange())
        default:
            super.doCommand(by: selector)
        }
    }

    /// ⌘. reaches here as `cancelOperation` too (KTD6).
    override func cancelOperation(_ sender: Any?) { stop() }

    private func stop() {
        if owner?.turnRuns?() == true { owner?.onStop?() }
    }

    // MARK: the "/" list

    /// While the box holds only a "/" word, the agent's matching commands show as the completion list.
    func offerCommandsIfTyping() {
        guard !completing, !hasMarkedText(), string.hasPrefix("/"), !string.contains(where: \.isWhitespace),
              let commands = owner?.commands?(), !ChatInputState.slashMatches(string, commands: commands).isEmpty,
              NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode != 51 /* delete */ else { return }
        completing = true
        complete(nil)
        completing = false
    }

    override var rangeForUserCompletion: NSRange {
        guard string.hasPrefix("/") else { return super.rangeForUserCompletion }
        return NSRange(location: 0, length: selectedRange().location)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard string.hasPrefix("/"), let commands = owner?.commands?() else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        index.pointee = -1
        return ChatInputState.slashMatches((string as NSString).substring(with: charRange), commands: commands)
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
