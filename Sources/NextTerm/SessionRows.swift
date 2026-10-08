import AppKit
import NextTermCore

/// "Agent Sessions" at the top of the project tree: the newest few sessions any agent kept for the folder,
/// and "More…" (the whole list, ⌥⌘O) when there are others. Shown only when the folder has some.
final class SessionsGroup {
    /// How many sessions the tree shows.
    static let shown = 5
    /// The rows: the newest sessions, one object per session so the outline keeps its place across reads.
    var items: [SessionItem] = []
    /// Every session the folder has, newest first.
    var all: [AgentSession] = []
    var tabs = SessionTabs()
    let more = MoreSessionsItem()
    var hasMore: Bool { all.count > items.count }
    /// The rows under the group.
    var children: [AnyObject] { items + (hasMore ? [more] : []) }
    /// Bumped by every read, so one that finishes after a newer one started is dropped.
    var token = 0
    var reloadQueued = false
    /// The agent tabs (and their states) seen last: a change reads the sessions again.
    var agentTabs = ""
    /// Projects whose group you closed: it stays closed for them.
    var collapsedRoots: Set<String> = []
    var expandWithRoot = false

    /// Agents with a session started in `folder` itself, in a fixed order: what "Continue Latest" offers,
    /// since each agent continues the latest session of the folder it runs in.
    func agents(in folder: String) -> [AgentKind] {
        AgentKind.allCases.filter { agent in all.contains { $0.agent == agent && $0.cwd == folder } }
    }
}

/// One session row. A class, so the outline keeps it (and its place) across reads.
final class SessionItem {
    var session: AgentSession
    var inTab: Bool
    init(_ session: AgentSession, inTab: Bool) {
        self.session = session
        self.inTab = inTab
    }
}

/// "More…" under the sessions: the whole list.
final class MoreSessionsItem {}

/// A session row (the agent's colour, the title, when), the group's ("Agent Sessions 12"), or "More…".
/// A session open in a tab, or in an agent running elsewhere, has a "running" badge.
final class SessionRowCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    let badge = BadgeView()
    private(set) lazy var more = MoreButton(toolTip: "Session actions") { [weak self] in self?.onMenu?() ?? NSMenu() }
    /// The ⋯ menu for this row (set by the sidebar each time the cell is configured).
    var onMenu: (() -> NSMenu)?
    private(set) var tipText = ""

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        Typography.singleLine(name, truncation: .byTruncatingTail)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Session actions")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        for view in [icon, name, badge, more] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -2),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 20),
            more.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: SessionItem) {
        let session = item.session
        icon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: session.agent.name)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
        icon.contentTintColor = SessionStore.color(session.agent)
        // A name you gave it reads a little stronger than one the agent made up.
        let font = NSFont.systemFont(ofSize: 12.5, weight: session.named ? .medium : .regular)
        let text = NSMutableAttributedString(string: session.title, attributes: [.font: font, .foregroundColor: Theme.text])
        text.append(Typography.gap(7, font: .systemFont(ofSize: 11.5)))
        text.append(NSAttributedString(string: SessionStore.when(session.updatedAt), attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim,
        ]))
        name.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
        let running = item.inTab || session.isRunning
        badge.text = running ? "running" : ""
        more.isHidden = false
        var tip = [session.title, session.agent.name + ", " + SessionStore.when(session.updatedAt)]
        if let branch = session.gitBranch { tip[1] += ", ⎇ " + branch }
        if let model = session.model { tip[1] += ", " + model }
        if item.inTab {
            tip.append("Open in a tab now: a double-click goes to it.")
        } else if session.isRunning, session.agent.canFork {
            tip.append("Open in \(session.agent.name) outside Next Term: Fork is the safe way to continue it here.")
        } else if session.isRunning {
            tip.append("Open in \(session.agent.name) outside Next Term: resuming it here as well runs it twice.")
        } else {
            tip.append("Double-click to continue it in a new tab: " + SessionStore.commandPrefix + session.resumeCommand())
        }
        tipText = tip.joined(separator: "\n")
        let state = item.inTab ? ", open in a tab" : session.isRunning ? ", running" : ""
        setAccessibilityLabel("\(session.title), \(session.agent.name), \(SessionStore.when(session.updatedAt))" + state)
    }

    func configureGroup(_ group: SessionsGroup) {
        icon.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Agent Sessions")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.textDim
        let text = NSMutableAttributedString(string: "Agent Sessions", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: Theme.text,
        ])
        text.append(Typography.gap(7, font: .systemFont(ofSize: 11.5)))
        text.append(NSAttributedString(string: "\(group.all.count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.textDim,
        ]))
        name.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
        let open = group.items.filter { $0.inTab || $0.session.isRunning }.count
        badge.text = open > 0 ? "\(open) running" : ""
        more.isHidden = false
        tipText = "Conversations agents kept for this folder, newest first. Double-click one to continue it in a new tab; ⋯ continues an agent's latest."
        setAccessibilityLabel("Agent Sessions, \(group.all.count)")
    }

    func configureMore(_ group: SessionsGroup) {
        icon.image = nil
        name.attributedStringValue = NSAttributedString(string: "More…", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textDim,
        ])
        badge.text = ""
        more.isHidden = true
        tipText = "All \(group.all.count) sessions, to filter and resume (⌥⌘O)"
        setAccessibilityLabel("More sessions, \(group.all.count) in all")
    }

    /// What the row shows, for the self-test.
    var nameText: String { name.stringValue }
}
