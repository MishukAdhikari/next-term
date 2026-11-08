import AppKit
import NextTermCore

/// Why a chat isn't running, as its end card says it (plan 037 R8, R12): ended with a reason, or brought back idle
/// after a crash or in safe mode.
enum ChatEndState: Equatable {
    case idle
    case ended(AgentSessionEngine.Ending)
    /// The conversation went on in another tab (Open in Terminal): the ended row's words, and whether that tab is open.
    case continued(String, tabOpen: Bool)
}

/// The card docked in the decision card's place once a chat isn't running: what happened in words, and what to do —
/// Resume (idle after a crash), Restart (ended), Open in Terminal (Claude Code and Codex).
final class ChatEndCard: ChatCardView {
    enum Action {
        case restart, resume, openInTerminal, showTab
    }

    private let icon = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let buttons = ChatButtonRow()
    private var actions: [Action] = []

    var onAction: ((Action) -> Void)?

    override init() {
        super.init()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        headline.translatesAutoresizingMaskIntoConstraints = false
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.isSelectable = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let column = addColumn([Self.headRow([icon, headline]), detail, buttons], spacedAfter: detail)
        NSLayoutConstraint.activate([
            detail.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The card's words and buttons for `state`. `resumable`: a conversation id is known, so Resume and Restart go on
    /// with it. `offersTerminal`: Claude Code or Codex, whose conversation a terminal tab can go on with.
    func show(_ state: ChatEndState, agent: String, resumable: Bool, offersTerminal: Bool, sizes: ChatTextSizes) {
        let words = Self.words(state, agent: agent, resumable: resumable)
        headline.font = .systemFont(ofSize: CGFloat(sizes.body), weight: .semibold)
        headline.textColor = .labelColor
        headline.stringValue = words.headline
        detail.font = .systemFont(ofSize: CGFloat(sizes.secondary))
        detail.textColor = .secondaryLabelColor
        detail.stringValue = words.detail ?? ""
        detail.isHidden = words.detail == nil
        icon.image = NSImage(systemSymbolName: words.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(sizes.body), weight: .medium))
        icon.contentTintColor = words.warns ? .systemOrange : .secondaryLabelColor
        var actions: [Action] = [state == .idle ? .resume : .restart]
        if offersTerminal { actions.append(.openInTerminal) }
        // Gone on elsewhere: the tab it went to is the one thing to do here (a restart would refuse while it holds it).
        if case .continued(_, let open) = state { actions = open ? [.showTab] : [] }
        self.actions = actions
        buttons.show(actions.enumerated().map { index, action in
            let title: String
            switch action {
            case .resume: title = resumable ? "Resume" : "Start"
            case .restart: title = resumable ? "Restart" : "Start Again"
            case .openInTerminal: title = "Open in Terminal"
            case .showTab: title = "Show Tab"
            }
            return ChatButtonRow.Item(title: title, accent: index == 0, label: title, tip: nil)
        }) { [weak self] index in
            guard let self, self.actions.indices.contains(index) else { return }
            self.onAction?(self.actions[index])
        }
        setAccessibilityLabel(words.headline + (words.detail.map { ". " + $0 } ?? ""))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fitWidth(of: detail)
    }

    /// Return picks the first button (Resume or Restart).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let first = actions.first { return onAction?(first) ?? () }
        super.keyDown(with: event)
    }

    struct Words: Equatable {
        var headline: String
        var detail: String?
        var symbol: String
        var warns: Bool
    }

    static func words(_ state: ChatEndState, agent: String, resumable: Bool) -> Words {
        switch state {
        case .continued(let note, _):
            return Words(headline: "Continued in Terminal", detail: note, symbol: "arrow.right.circle", warns: false)
        case .idle:
            let detail = resumable ? "Resume goes on with this conversation." : "Start runs \(agent) here again."
            return Words(headline: "\(agent) isn\u{2019}t running", detail: detail, symbol: "pause.circle", warns: false)
        case .ended(let ending):
            switch ending {
            case .quit(let status, let words):
                let last = words.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
                let headline = status == 0 ? "\(agent) quit" : "\(agent) quit (exit status \(status))"
                return Words(headline: headline, detail: last?.isEmpty == false ? last : nil, symbol: "stop.circle", warns: status != 0)
            case .fatal(let note):
                return Words(headline: "This session ended", detail: note, symbol: "exclamationmark.triangle", warns: true)
            case .signIn(let note):
                return Words(headline: "\(agent) needs you to sign in",
                             detail: note.isEmpty ? "Sign in from its terminal interface, then restart the chat." : note,
                             symbol: "person.crop.circle.badge.exclamationmark", warns: true)
            case .resumeFailed(let why):
                return Words(headline: "This conversation couldn\u{2019}t go on here", detail: why.isEmpty ? nil : why,
                             symbol: "exclamationmark.triangle", warns: true)
            case .closed:
                return Words(headline: "This session ended", detail: nil, symbol: "stop.circle", warns: false)
            }
        }
    }
}
