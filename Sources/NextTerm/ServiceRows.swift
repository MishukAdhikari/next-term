import AppKit
import NextTermCore

/// "Services" under Databases: what the project's files say it uses that is not a database row (AI models, vector
/// stores, tracing, agents, local servers, backends, hosting), each with a badge that opens its page.
final class ServicesGroup {
    var items: [ServiceItem] = []
    private(set) var scan = ServiceScan()
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

    /// Empties the group without touching the outline: on a project switch, before the new project's tree loads, so the
    /// old project's rows never sit in it.
    func clear() {
        _ = update(ServiceScan())
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

/// A service row, or the group's: the kind's icon, the name, its kind and file dimmed, the badge that opens its page
/// (":6334", "Console"), and ⋯. Laid out as a database row, so the two sections line up. The name and the detail are
/// two labels on one baseline, sized by NameDetailFit: in a narrow sidebar the detail gives way first and the name
/// stays whole.
final class ServiceCellView: NSTableCellView {
    /// Where the name starts, past the icon; the gap the name leaves before the badge; the badge's before ⋯; ⋯'s width
    /// and its gap to the row's end.
    private static let nameStart: CGFloat = 21
    private static let toBadge: CGFloat = 6
    private static let toMore: CGFloat = 2
    private static let moreWidth: CGFloat = 20
    private static let toEnd: CGFloat = 2
    /// The space between the name's last letter and the detail's first.
    private static let detailGap: CGFloat = 7

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    let badge = LinkBadgeStack()
    private(set) lazy var more = MoreButton(toolTip: "Service actions") { [weak self] in self?.onMenu?() ?? NSMenu() }
    /// The ⋯ menu for this row (set by the sidebar each time the cell is configured).
    var onMenu: (() -> NSMenu)?
    private(set) var tipText = ""
    private(set) weak var item: ServiceItem?
    private var nameWidth: NSLayoutConstraint!
    private var detailWidth: NSLayoutConstraint!
    private var detailLead: NSLayoutConstraint!
    /// The narrowest the detail may be cut to: its first two characters and the ellipsis.
    private var minimumDetail: CGFloat = 0

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        Typography.singleLine(name, truncation: .byTruncatingTail)
        Typography.singleLine(detail, truncation: .byTruncatingTail)
        // The widths come from NameDetailFit; if the two ever disagree with the badge, the detail gives way first.
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Service actions")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        for view in [icon, name, detail, badge, more] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate(iconPlace() + textPlace() + endPlace())
    }

    private func iconPlace() -> [NSLayoutConstraint] {
        [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ]
    }

    /// The name, centred in the row, and the detail on its baseline; neither runs past the badge.
    private func textPlace() -> [NSLayoutConstraint] {
        nameWidth = name.widthAnchor.constraint(equalToConstant: 0)
        nameWidth.priority = .init(999)
        detailWidth = detail.widthAnchor.constraint(equalToConstant: 0)
        detailWidth.priority = .init(998)
        detailLead = detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 0)
        return [
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.nameStart),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Self.toBadge),
            nameWidth,
            detailLead,
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Self.toBadge),
            detailWidth,
        ]
    }

    private func endPlace() -> [NSLayoutConstraint] {
        [
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -Self.toMore),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.toEnd),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: Self.moreWidth),
            more.heightAnchor.constraint(equalToConstant: 20),
        ]
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
        show(title, detail: kindAndFile)
        badge.show(row.badges)
        more.isHidden = false
        tipText = row.tooltip
        setAccessibilityLabel(row.accessibilityLabel)
        fitText()
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
        show(title, detail: count)
        badge.show([])
        more.isHidden = true
        tipText = group.scan.tooltip
        setAccessibilityLabel("Services, \(group.items.count)")
        fitText()
    }

    /// What the row shows, for the self-test: the name, then its detail, hidden or not.
    var nameText: String { detail.stringValue.isEmpty ? name.stringValue : name.stringValue + " " + detail.stringValue }

    /// The tooltip at `point`, in the cell's coordinates: over the badge, the page it opens; elsewhere, the row's.
    func tip(at point: NSPoint) -> String {
        badge.tip(at: convert(point, to: badge)) ?? tipText
    }

    // MARK: fitting the name and the detail

    /// A label never shown, to measure text as the row's labels lay it out.
    private static let sizer = NSTextField(labelWithString: "")

    /// The row's two runs of text, each cut at its tail when it has to be, and the narrowest the detail may be cut to:
    /// its first two characters and the ellipsis, about three characters.
    private func show(_ title: NSAttributedString, detail line: NSAttributedString) {
        name.attributedStringValue = Typography.truncating(title, .byTruncatingTail)
        detail.attributedStringValue = Typography.truncating(line, .byTruncatingTail)
        let attributes = line.length > 0 ? line.attributes(at: 0, effectiveRange: nil) : [:]
        Self.sizer.attributedStringValue = NSAttributedString(string: String(line.string.prefix(2)) + "…", attributes: attributes)
        minimumDetail = Self.sizer.intrinsicContentSize.width
    }

    /// Sizes the name and the detail for the row's width (NameDetailFit): the detail gives way first and hides rather
    /// than show a sliver; the name is cut only when it alone does not fit. The badge and ⋯ keep their places.
    private func fitText() {
        guard nameWidth != nil else { return }  // still in init
        let ends: CGFloat = Self.toBadge + badge.intrinsicContentSize.width + Self.toMore + Self.moreWidth + Self.toEnd
        let room: CGFloat = bounds.width - Self.nameStart - ends
        let nameWhole: CGFloat = name.intrinsicContentSize.width
        let detailWhole: CGFloat = detail.stringValue.isEmpty ? 0 : detail.intrinsicContentSize.width
        let fit = NameDetailFit.fit(room: Double(room), name: Double(nameWhole), detail: Double(detailWhole),
                                    gap: Double(Self.detailGap), minimumDetail: Double(minimumDetail))
        Self.set(nameWidth, to: CGFloat(fit.name))
        Self.set(detailWidth, to: CGFloat(fit.detail ?? 0))
        Self.set(detailLead, to: fit.detail == nil ? 0 : Self.detailGap)
        detail.isHidden = fit.detail == nil
    }

    private static func set(_ constraint: NSLayoutConstraint, to constant: CGFloat) {
        if constraint.constant != constant { constraint.constant = constant }
    }

    /// A narrower or wider sidebar refits the text.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitText()
    }
}
