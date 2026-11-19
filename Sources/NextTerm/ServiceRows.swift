import AppKit
import NextTermCore

/// "Services" under Databases: what the project's files say it uses that is not a database row (AI models, vector
/// stores, tracing, agents, local servers, backends, hosting), each with a badge that opens its page.
final class ServicesGroup {
    var items: [ServiceItem] = []
    /// A quiet line for a model server the project names that this Mac lacks (Ollama, LM Studio), above the rows.
    private(set) var offers: [RunOfferItem] = []
    private(set) var scan = ServiceScan()
    /// The latest "is it up" look's number: an older look's answer is dropped.
    var portLook = 0
    /// Open or closed, project by project: one you closed stays closed for that project, and a wait for a folder to
    /// open is that project's alone, so a switch between projects changes neither.
    var expansion = SidebarGroupExpansion()

    /// Takes a scan's rows, keeping each row's object (and so its place and selection in the outline) by its id. False
    /// when the scan shows what the group shows already.
    func update(_ new: ServiceScan) -> Bool {
        guard new != scan else { return false }
        let old = Dictionary(items.map { (item: ServiceItem) -> (String, ServiceItem) in (item.row.id, item) },
                             uniquingKeysWith: { (first: ServiceItem, _: ServiceItem) -> ServiceItem in first })
        scan = new
        items = new.rows.map { (row: ServiceRow) -> ServiceItem in
            guard let item = old[row.id] else { return ServiceItem(row) }
            item.row = row
            return item
        }
        return true
    }

    /// The group's rows in the outline: the offers, then the services. None while there is no service.
    var rows: [AnyObject] { items.isEmpty ? [] : (offers as [AnyObject]) + (items as [AnyObject]) }

    /// Takes a look's offers, keeping each line's object by its tool. False when they are the ones shown.
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

    /// Marks the rows whose port answered as running, and the others not. Returns the rows that changed.
    func update(running up: Set<String>) -> [ServiceItem] {
        var changed: [ServiceItem] = []
        for item in items {
            let running = up.contains(item.row.id)
            if item.running != running {
                item.running = running
                changed.append(item)
            }
        }
        return changed
    }

    /// Empties the group without touching the outline: on a project switch, before the new project's tree loads, so the
    /// old project's rows never sit in it.
    func clear() {
        _ = update(ServiceScan())
        _ = update(offers: [])
        portLook += 1
    }

    /// The group's own row or one of its rows: the outline asks these the same questions.
    static func holds(_ item: Any?) -> Bool { item is ServicesGroup || item is ServiceItem }
}

/// One service row. A class, so the outline keeps it (and its place) across rescans.
final class ServiceItem {
    var row: ServiceRow
    /// Its port answered at the last look: the row shows a small green dot.
    var running = false
    init(_ row: ServiceRow) { self.row = row }
}

/// What the rows show beyond Core's text (ServiceRow's detail, tooltip and label): each kind's icon.
enum ServiceText {
    static func symbol(_ kind: ServiceKind) -> String {
        switch kind {
        case .aiModel: return "sparkles"
        case .vectorStore: return "square.stack.3d.up"
        case .tracing: return "waveform.path.ecg"
        case .agent: return "point.3.connected.trianglepath.dotted"
        case .localServer: return "server.rack"
        case .backend: return "cloud"
        case .hosting: return "globe"
        }
    }

    /// The kind's symbol, or a plain one where this macOS lacks it; VoiceOver hears the kind either way.
    static func image(_ kind: ServiceKind) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: symbol(kind), accessibilityDescription: kind.title)
            ?? NSImage(systemSymbolName: "circle.grid.2x2", accessibilityDescription: kind.title)
        return image?.withSymbolConfiguration(config)
    }
}

/// A service row, or the group's: the kind's icon, the name, its kind and file dimmed, the badge that opens its page
/// (":6334", "Console"), and ⋯. Laid out as a database row (NameDetailLine), so the two sections line up and cut alike:
/// in a narrow sidebar the detail gives way first and the name stays whole.
final class ServiceCellView: NSTableCellView {
    private let icon = NSImageView()
    /// The name and the dimmed detail; the self-test reads their places.
    let line = NameDetailLine()
    let badge = LinkBadgeStack()
    /// A small green dot on the icon's corner while the service's port answers; nothing when it does not.
    let runningDot = NSView()
    private(set) lazy var more = MoreButton(toolTip: "Service actions") { [weak self] in self?.onMenu?() ?? NSMenu() }
    /// The ⋯ menu for this row (set by the sidebar each time the cell is configured).
    var onMenu: (() -> NSMenu)?
    private(set) var tipText = ""
    private(set) weak var item: ServiceItem?

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Service actions")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        for view in [icon, line.name, line.detail, badge, more] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = line.name
        runningDot.wantsLayer = true
        runningDot.layer?.cornerRadius = 3
        runningDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        runningDot.isHidden = true
        runningDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(runningDot)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            runningDot.widthAnchor.constraint(equalToConstant: 6),
            runningDot.heightAnchor.constraint(equalToConstant: 6),
            runningDot.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 1),
            runningDot.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
        ] + line.place(in: self, badge: badge, more: more))
    }

    /// The dot's green as this appearance draws it.
    private func colourDot() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            runningDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colourDot()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: ServiceItem) {
        self.item = item
        let row = item.row
        icon.image = ServiceText.image(row.kind)
        icon.contentTintColor = Theme.textDim
        let nameFont = NSFont.systemFont(ofSize: 12.5)
        let detailFont = NSFont.systemFont(ofSize: 11.5)
        let title = NSAttributedString(string: row.name, attributes: [.font: nameFont, .foregroundColor: Theme.text])
        let kindAndFile = NSAttributedString(string: row.detail, attributes: [.font: detailFont, .foregroundColor: Theme.textDim])
        line.show(title, detail: kindAndFile)
        badge.show(row.badges)
        more.isHidden = false
        runningDot.isHidden = !item.running
        colourDot()
        runningDot.toolTip = item.running ? "Running" : nil
        tipText = row.tooltip(running: item.running)
        setAccessibilityLabel(row.accessibilityLabel(running: item.running))
        line.fit(in: self, badge: badge)
    }

    func configureGroup(_ group: ServicesGroup) {
        item = nil
        icon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Services")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.textDim
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let title = NSAttributedString(string: "Services", attributes: [.font: titleFont, .foregroundColor: Theme.text])
        let count = NSAttributedString(string: "\(group.items.count)", attributes: [.font: countFont, .foregroundColor: Theme.textDim])
        line.show(title, detail: count)
        badge.show([])
        more.isHidden = true
        runningDot.isHidden = true
        tipText = group.scan.tooltip
        setAccessibilityLabel("Services, \(group.items.count)")
        line.fit(in: self, badge: badge)
    }

    /// What the row shows, for the self-test: the name, then its detail, hidden or not.
    var nameText: String { line.text }

    /// The tooltip at `point`, in the cell's coordinates: over the badge, the page it opens; elsewhere, the row's.
    func tip(at point: NSPoint) -> String {
        badge.tip(at: convert(point, to: badge)) ?? tipText
    }

    /// A narrower or wider sidebar refits the text.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        line.fit(in: self, badge: badge)
    }
}
