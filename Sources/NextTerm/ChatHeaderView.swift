import AppKit
import NextTermCore

/// A chat tab's header (plan 037 R5): the agent's name, then the model, the CLI's version and the folder in secondary
/// text; the usage and the state on the right; a Stop button while a turn runs; Open in Terminal for Claude Code and
/// Codex. A hairline under it.
final class ChatHeaderView: NSView {
    private let name = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let usage = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    let stopButton = NSButton()
    let terminalButton = NSButton()
    private var terminalTip: ShortcutToolTip?
    private var height: NSLayoutConstraint?
    /// What the header was last shown with: a refresh that brings nothing new (a streamed chunk) sets nothing.
    private var shown: Shown?

    private struct Shown: Equatable {
        let header: ChatHeader
        let sizes: ChatTextSizes
        let offersTerminal: Bool
        /// The dot's colour is resolved for the appearance it was set in.
        let appearance: NSAppearance.Name
    }

    var onStop: (() -> Void)?
    var onOpenInTerminal: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        for label in [name, details, usage, stateLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        details.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        usage.setContentHuggingPriority(.required, for: .horizontal)
        usage.alignment = .right

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setAccessibilityElement(false)

        configure(stopButton, title: "Stop", symbol: "stop.circle", action: #selector(stop))
        stopButton.toolTip = "Stop this turn (\u{2318}.)"
        stopButton.setAccessibilityLabel("Stop the turn")
        configure(terminalButton, title: "Open in Terminal", symbol: "terminal", action: #selector(openInTerminal))
        terminalButton.setAccessibilityLabel("Open in Terminal")

        let left = NSStackView(views: [name, details])
        left.orientation = .horizontal
        left.alignment = .firstBaseline
        left.spacing = 8
        let right = NSStackView(views: [usage, dot, stateLabel, stopButton, terminalButton])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 8
        right.setCustomSpacing(5, after: dot)
        right.setCustomSpacing(12, after: stateLabel)
        right.setHuggingPriority(.required, for: .horizontal)
        for stack in [left, right] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.detachesHiddenViews = true
            addSubview(stack)
        }
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        let height = heightAnchor.constraint(equalToConstant: 36)
        self.height = height
        NSLayoutConstraint.activate([
            height,
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Chat header")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The header as `header` has it, at `sizes`. `offersTerminal`: the Open in Terminal button shows.
    func show(_ header: ChatHeader, sizes: ChatTextSizes, offersTerminal: Bool) {
        let asked = Shown(header: header, sizes: sizes, offersTerminal: offersTerminal, appearance: effectiveAppearance.name)
        guard asked != shown else { return }
        shown = asked
        name.font = .systemFont(ofSize: CGFloat(sizes.body), weight: .semibold)
        name.textColor = .labelColor
        name.stringValue = header.name
        // 36 points at the standard size, growing with the text.
        height?.constant = max(36, (CGFloat(sizes.body) * 2.6).rounded())
        let small = NSFont.systemFont(ofSize: CGFloat(sizes.secondary))
        details.font = small
        details.textColor = .secondaryLabelColor
        details.stringValue = [header.model, header.version, header.folder].compactMap { $0 }.joined(separator: "  \u{00B7}  ")
        details.toolTip = details.stringValue.isEmpty ? nil : details.stringValue
        usage.font = .monospacedDigitSystemFont(ofSize: CGFloat(sizes.secondary), weight: .regular)
        usage.textColor = .tertiaryLabelColor
        usage.stringValue = header.usage ?? ""
        usage.isHidden = header.usage == nil
        stateLabel.font = small
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.stringValue = header.stateWords
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = Self.colour(of: header.state).cgColor
        }
        stopButton.isHidden = !header.state.showsStop
        terminalButton.isHidden = !offersTerminal
        if offersTerminal, terminalTip == nil {
            terminalTip = ShortcutToolTip(terminalButton, "Continue this conversation in a terminal tab",
                                          ChatView.handoffAction)
        }
        setAccessibilityLabel(([header.line, header.usage, header.stateWords] as [String?]).compactMap { $0 }.joined(separator: ", "))
    }

    /// The state's dot, in the tab marks' colours.
    static func colour(of state: ChatHostState) -> NSColor {
        switch state {
        case .working, .starting: return Theme.working
        case .asking, .trusting: return Theme.attention
        case .ready: return Theme.done
        case .idle, .ended: return .tertiaryLabelColor
        }
    }

    @objc private func stop() { onStop?() }
    @objc private func openInTerminal() { onOpenInTerminal?() }
}
