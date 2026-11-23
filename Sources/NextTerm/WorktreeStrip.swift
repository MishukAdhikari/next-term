import AppKit
import NextTermCore

/// The slim strip above an agent's pane when its agent works in another linked worktree of the window's repository:
/// the place glyph, "This tab's agent works in xcloud-wt-11650 (fix/11650).", a quiet Not Now and Open as Project, the
/// one primary. It lies over the pane's top rows and never resizes the terminal (each resize redraws the agent's
/// screen), never covers the bottom rows where agents keep their input, and takes no key: Return still goes to the
/// terminal, and neither button joins the key-view loop (the tab's menu has Open as Project for the keyboard).
/// WorktreeLifecycle.Offers decides when it shows; TerminalWindowController.updateWorktreeStrips feeds it.
final class WorktreeStrip: NSView {
    static let height: CGFloat = 32

    private let glyph = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private let notNow = MCPConnectorBar.quiet("Not Now")
    private let primary = PrimaryButton(title: "Open as Project", target: nil, action: nil)

    var onOpen: (() -> Void)?
    var onNotNow: (() -> Void)?

    /// The worktree it offers now, nil while hidden.
    private(set) var worktree: Checkout?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themedBackground(Theme.bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Worktree")

        glyph.image = PlaceGlyph.image(size: 13)
        glyph.contentTintColor = Theme.textDim
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        message.font = .systemFont(ofSize: 12)
        message.textColor = Theme.text
        Typography.singleLine(message, truncation: .byTruncatingMiddle)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)

        notNow.setAccessibilityLabel("Not Now")
        notNow.target = self
        notNow.action = #selector(notNowClicked)
        primary.keyEquivalent = "" // Return stays the terminal's
        for button in [notNow, primary] { button.refusesFirstResponder = true } // a click never takes the terminal's keyboard
        primary.setAccessibilityLabel("Open as Project")
        primary.target = self
        primary.action = #selector(openClicked)

        let lead = NSStackView(views: [glyph, message])
        lead.orientation = .horizontal
        lead.spacing = 7
        let trail = NSStackView(views: [notNow, primary])
        trail.orientation = .horizontal
        trail.spacing = 10
        trail.setHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [lead, trail])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Its bottom edge over the terminal: a line that is always seen.
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Theme.divider
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: line.topAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What it says for `worktree`: its folder's name and its branch (or the commit it is detached at).
    static func words(for worktree: Checkout) -> String {
        let name = (worktree.path as NSString).lastPathComponent
        let head: String
        switch worktree.head {
        case let .branch(branch): head = branch
        case let .detached(commit): head = String(commit.prefix(7))
        }
        return "This tab\u{2019}s agent works in \(name) (\(head))."
    }

    /// Shows the offer for `worktree`, or hides the strip for nil. A newer worktree takes its words in place.
    func show(_ worktree: Checkout?) {
        guard worktree != self.worktree else { return }
        self.worktree = worktree
        guard let worktree else { return setVisible(false) }
        let words = Self.words(for: worktree)
        let name = (worktree.path as NSString).lastPathComponent
        let text = NSMutableAttributedString(string: words, attributes: [.foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 12)])
        if let range = words.range(of: name) {
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .semibold), range: NSRange(range, in: words))
        }
        message.attributedStringValue = text
        message.toolTip = words + "\n" + worktree.path
        setAccessibilityLabel(words)
        let appearing = isHidden
        setVisible(true)
        if appearing {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// A short fade in and out, none with Reduce Motion. Its frame never changes, so nothing under it moves.
    private func setVisible(_ visible: Bool) {
        guard visible == isHidden else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            alphaValue = reduce ? 1 : 0
            isHidden = false
        }
        guard !reduce else {
            alphaValue = 1
            isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.worktree == nil else { return }
                self.isHidden = true
            }
        })
    }

    @objc private func openClicked() { onOpen?() }
    @objc private func notNowClicked() { onNotNow?() }

    #if DEBUG
    /// The words shown, for the self-test.
    var messageForTest: String { message.stringValue }
    var buttonsForTest: [String] { isHidden ? [] : [notNow.title, primary.title] }
    var primaryKeyForTest: String { primary.keyEquivalent }
    var buttonsTakeKeysForTest: Bool { !notNow.refusesFirstResponder || !primary.refusesFirstResponder }
    func pressForTest(_ title: String) { [notNow, primary].first { !isHidden && $0.title == title }?.performClick(nil) }
    #endif
}
