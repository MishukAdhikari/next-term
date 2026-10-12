import AppKit
import NextTermCore

/// "Services" under Databases: what the project's files say it uses that is not a database row (AI models, vector
/// stores, tracing, agents, local servers, backends, hosting), each with a badge that opens its page.
final class ServicesGroup {
    var items: [ServiceItem] = []
    private(set) var scan = ServiceScan()
    /// Projects whose group you closed: it stays closed for them.
    var collapsedRoots: Set<String> = []
    var expandWithRoot = false

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

    /// The group's own row or one of its rows: the outline asks these the same questions.
    static func holds(_ item: Any?) -> Bool { item is ServicesGroup || item is ServiceItem }
}

/// One service row. A class, so the outline keeps it (and its place) across rescans.
final class ServiceItem {
    var row: ServiceRow
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

/// A service row, or the group's: the kind's icon, the name with its kind and file dimmed, the badge that opens its
/// page (":6334", "Console"), and ⋯. Laid out as a database row, so the two sections line up.
final class ServiceCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    let badge = LinkBadgeStack()
    private(set) lazy var more = MoreButton(toolTip: "Service actions") { [weak self] in self?.onMenu?() ?? NSMenu() }
    /// The ⋯ menu for this row (set by the sidebar each time the cell is configured).
    var onMenu: (() -> NSMenu)?
    private(set) var tipText = ""
    private(set) weak var item: ServiceItem?

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Service actions")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        for view in [icon, name, badge, more] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        let iconPlace: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ]
        let namePlace: [NSLayoutConstraint] = [
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
        ]
        let badgePlace: [NSLayoutConstraint] = [
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -2),
        ]
        let morePlace: [NSLayoutConstraint] = [
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 20),
            more.heightAnchor.constraint(equalToConstant: 20),
        ]
        NSLayoutConstraint.activate(iconPlace + namePlace + badgePlace + morePlace)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: ServiceItem) {
        self.item = item
        let row = item.row
        icon.image = ServiceText.image(row.kind)
        icon.contentTintColor = Theme.textDim
        let nameFont = NSFont.systemFont(ofSize: 12.5)
        let detailFont = NSFont.systemFont(ofSize: 11.5)
        let text = NSMutableAttributedString(string: row.name, attributes: [.font: nameFont, .foregroundColor: Theme.text])
        text.append(Typography.gap(7, font: detailFont))
        text.append(NSAttributedString(string: row.detail, attributes: [.font: detailFont, .foregroundColor: Theme.textDim]))
        name.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        badge.show(row.badges)
        more.isHidden = false
        tipText = row.tooltip
        setAccessibilityLabel(row.accessibilityLabel)
    }

    func configureGroup(_ group: ServicesGroup) {
        item = nil
        icon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Services")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.textDim
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let text = NSMutableAttributedString(string: "Services", attributes: [.font: titleFont, .foregroundColor: Theme.text])
        text.append(Typography.gap(7, font: .systemFont(ofSize: 11.5)))
        let count = NSAttributedString(string: "\(group.items.count)", attributes: [.font: countFont, .foregroundColor: Theme.textDim])
        text.append(count)
        name.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
        badge.show([])
        more.isHidden = true
        tipText = group.scan.tooltip
        setAccessibilityLabel("Services, \(group.items.count)")
    }

    /// What the row shows, for the self-test.
    var nameText: String { name.stringValue }

    /// The tooltip at `point`, in the cell's coordinates: over the badge, the page it opens; elsewhere, the row's.
    func tip(at point: NSPoint) -> String {
        badge.tip(at: convert(point, to: badge)) ?? tipText
    }
}
