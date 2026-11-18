import AppKit
import NextTermCore

/// "Run" under Services (plan 044): the project's own tasks (RunTasks), each typed and run in a new tab in the project's
/// folder, and above them a quiet line for a tool the project needs that this Mac lacks (ProjectTools). The group shows
/// only when the project has tasks.
final class RunGroup {
    private(set) var tasks: [RunItem] = []
    private(set) var offers: [RunOfferItem] = []
    private(set) var scan = RunScan()
    /// The tools a scan said the project needs, kept for a look along PATH when the window comes forward.
    var needs: [ProjectTool] { scan.needs }
    /// Open or closed, project by project, as the Services group keeps it.
    var expansion = SidebarGroupExpansion()

    /// The group's rows: the offers, then the tasks. None while the project has no task, offers or not.
    var items: [AnyObject] { tasks.isEmpty ? [] : (offers as [AnyObject]) + (tasks as [AnyObject]) }

    /// Takes a scan's tasks, keeping each row's object (and so its place and selection) by its id. False when nothing
    /// shown changed. Offers stay until the next look along PATH replaces them, unless no tool is needed any more.
    func update(_ new: RunScan) -> Bool {
        guard new != scan else { return false }
        let old = Dictionary(tasks.map { (item: RunItem) -> (String, RunItem) in (item.task.id, item) },
                             uniquingKeysWith: { (first: RunItem, _: RunItem) -> RunItem in first })
        scan = new
        tasks = new.tasks.map { (task: RunTask) -> RunItem in
            guard let item = old[task.id] else { return RunItem(task) }
            item.task = task
            return item
        }
        offers = offers.filter { (item: RunOfferItem) -> Bool in new.needs.contains(item.offer.tool) }
        return true
    }

    /// Takes a look's offers, keeping each row's object by its tool. False when they are the ones shown.
    func update(offers new: [ToolOffer]) -> Bool {
        guard new != offers.map(\.offer) else { return false }
        let old = Dictionary(offers.map { (item: RunOfferItem) -> (String, RunOfferItem) in (item.offer.id, item) },
                             uniquingKeysWith: { (first: RunOfferItem, _: RunOfferItem) -> RunOfferItem in first })
        offers = new.map { (offer: ToolOffer) -> RunOfferItem in
            guard let item = old[offer.id] else { return RunOfferItem(offer) }
            item.offer = offer
            return item
        }
        return true
    }

    /// Empties the group without touching the outline, on a project switch.
    func clear() {
        _ = update(RunScan())
        _ = update(offers: [])
    }

    static func holds(_ item: Any?) -> Bool { item is RunGroup || item is RunItem || item is RunOfferItem }
}

/// One task's row. A class, so the outline keeps it across rescans.
final class RunItem {
    var task: RunTask
    init(_ task: RunTask) { self.task = task }
}

/// The line for a tool the project needs and this Mac lacks.
final class RunOfferItem {
    var offer: ToolOffer
    init(_ offer: ToolOffer) { self.offer = offer }
}

/// A Run row, an offer line or the group's own row, laid out as a Services row (NameDetailLine): a task's name, its
/// file dimmed, a ▶ that runs it and ⋯; an offer's text dimmed and its Install… link; the group's name and count.
final class RunCellView: NSTableCellView {
    private let icon = NSImageView()
    let line = NameDetailLine()
    /// ▶ on a task's row, Install… on an offer's: in the place a Services row has its badge.
    let action = NSButton()
    private(set) lazy var more = MoreButton(toolTip: "Task actions") { [weak self] in self?.onMenu?() ?? NSMenu() }
    var onMenu: (() -> NSMenu)?
    /// ▶ or Install… was clicked.
    var onAction: (() -> Void)?
    private(set) var tipText = ""

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Task actions")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        action.isBordered = false
        action.bezelStyle = .regularSquare
        action.target = self
        action.action = #selector(acted)
        action.setButtonType(.momentaryChange)
        for view in [icon, line.name, line.detail, action, more] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        // The name is not the cell's textField: a source list sets that label's font and colour itself after the row is
        // configured, which would undo the offer line's quiet text and the width the line was fitted to.
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ] + line.place(in: self, badge: action, more: more))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func acted() { onAction?() }

    private static func symbol(_ name: String, _ label: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// The size the source list gives a file's or a service's name, so Run rows match the rows around them.
    private static let nameFont = NSFont.systemFont(ofSize: 13)
    private static let detailFont = NSFont.systemFont(ofSize: 11.5)

    func configure(_ item: RunItem) {
        let task = item.task
        icon.image = Self.symbol("terminal", "Task")
        icon.contentTintColor = Theme.textDim
        line.show(NSAttributedString(string: task.name, attributes: [.font: Self.nameFont, .foregroundColor: Theme.text]),
                  detail: NSAttributedString(string: task.file, attributes: [.font: Self.detailFont, .foregroundColor: Theme.textDim]))
        action.isHidden = false
        action.title = ""
        action.attributedTitle = NSAttributedString(string: "")
        action.image = Self.symbol("play.fill", "Run", size: 10, weight: .regular)
        action.imagePosition = .imageOnly
        action.contentTintColor = Theme.textDim
        action.toolTip = "Run “\(task.command)” in a new tab"
        action.setAccessibilityLabel("Run \(task.name)")
        more.isHidden = false
        tipText = task.command
        setAccessibilityLabel("\(task.name), \(task.file)")
        line.fit(in: self, badge: action)
    }

    func configure(_ item: RunOfferItem) {
        let offer = item.offer
        icon.image = Self.symbol("arrow.down.circle", "Install")
        icon.contentTintColor = Theme.textDim
        line.show(NSAttributedString(string: offer.text, attributes: [.font: Self.detailFont, .foregroundColor: Theme.textDim]),
                  detail: NSAttributedString(string: ""))
        action.isHidden = false
        action.image = nil
        action.imagePosition = .noImage
        action.attributedTitle = NSAttributedString(string: ToolOffer.install, attributes: [
            .font: Self.detailFont, .foregroundColor: Theme.gitModified,
        ])
        switch offer.action {
        case .type(let command):
            action.toolTip = "Types “\(command)” in a new tab, for you to run"
            tipText = "The project needs \(offer.tool.name). Install… types its installer in a new tab; press Return to run it."
        case .open(let page):
            action.toolTip = "Opens \(page)"
            tipText = "The project needs \(offer.tool.name)."
        }
        action.setAccessibilityLabel("Install \(offer.tool.name)")
        more.isHidden = true
        setAccessibilityLabel(offer.text)
        line.fit(in: self, badge: action)
    }

    func configureGroup(_ group: RunGroup) {
        icon.image = Self.symbol("play.rectangle", "Run")
        icon.contentTintColor = Theme.textDim
        let titleFont = Self.nameFont
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        line.show(NSAttributedString(string: "Run", attributes: [.font: titleFont, .foregroundColor: Theme.text]),
                  detail: NSAttributedString(string: "\(group.tasks.count)", attributes: [.font: countFont, .foregroundColor: Theme.textDim]))
        action.isHidden = true
        more.isHidden = true
        tipText = "The project’s own tasks, each run in a new tab"
        setAccessibilityLabel("Run, \(group.tasks.count)")
        line.fit(in: self, badge: action)
    }

    /// What the row shows, for the self-test: the name, then its detail, then Install… on an offer's line.
    var shownText: String {
        let link = action.isHidden || action.attributedTitle.length == 0 ? "" : " · " + action.attributedTitle.string
        return line.text + link
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        line.fit(in: self, badge: action)
    }
}
