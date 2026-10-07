import AppKit
import NextTermCore

/// "Databases" at the top of the project tree, when the project's files name any.
final class DatabasesGroup {
    var items: [DatabaseItem] = []
    var vercelProject: String?
}

/// One database row. A class, so the outline keeps it (and its place) across rescans.
final class DatabaseItem {
    var database: DetectedDatabase
    init(_ database: DetectedDatabase) { self.database = database }
}

/// What the rows say. Built from the model only, which holds no secret: the connection is shown masked.
enum DatabaseText {
    static func environment(_ db: DetectedDatabase) -> String {
        switch db.environment {
        case .local: return db.engine == .sqlite ? "Local file" : "Local: on this Mac"
        case .development: return "Development: a container on this Mac"
        case .remote: return "Remote: not on this Mac, so treated as production"
        case .unknown: return "Not a connection"
        }
    }

    /// The secondary text after the name: the file it came from, or the SQLite file's folder.
    static func detail(_ db: DetectedDatabase) -> String {
        if !db.isConnection { return db.note?.hasPrefix("Example") == true ? "example" : "not set" }
        // A SQLite file found on disk: its folder ("database"); one only an env file names: that file.
        if db.engine == .sqlite, let path = db.filePath {
            let name = (path as NSString).lastPathComponent
            if let own = db.sources.first(where: { ($0.file as NSString).lastPathComponent == name && !$0.file.hasPrefix(".env") }) {
                return (own.file as NSString).deletingLastPathComponent
            }
        }
        return db.sourceFile ?? ""
    }

    static func badge(_ db: DetectedDatabase) -> String {
        db.providers.prefix(2).map(\.rawValue).joined(separator: " · ")
    }

    static func tooltip(_ db: DetectedDatabase) -> String {
        var lines = [([db.engine.displayName] + db.providers.map(\.rawValue)).joined(separator: " · ")]
        lines.append(db.masked)
        lines.append(environment(db))
        if let note = db.note { lines.append(note) }
        var byFile: [(String, [String])] = []
        for source in db.sources {
            if let i = byFile.firstIndex(where: { $0.0 == source.file }) {
                byFile[i].1 += source.keys.filter { !byFile[i].1.contains($0) }
            } else {
                byFile.append((source.file, source.keys))
            }
        }
        for (file, keys) in byFile.prefix(4) {
            let shown = keys.prefix(5).joined(separator: ", ") + (keys.count > 5 ? ", …" : "")
            lines.append(keys.isEmpty ? "From \(file)" : "From \(file): \(shown)")
        }
        if !db.tools.isEmpty { lines.append("Read by " + db.tools.joined(separator: ", ")) }
        return DatabaseMask.redact(lines.joined(separator: "\n"))
    }

    static func accessibility(_ db: DetectedDatabase) -> String {
        var parts = [db.name, db.engine.displayName]
        switch db.environment {
        case .local: parts.append("local")
        case .development: parts.append("development")
        case .remote: parts.append("remote")
        case .unknown: parts.append(detail(db))
        }
        parts += db.providers.map(\.rawValue)
        return parts.joined(separator: ", ")
    }

    static func symbol(_ engine: DatabaseEngine) -> String {
        switch engine {
        case .sqlite: return "tablecells"
        case .mongodb: return "leaf"
        case .libsql: return "bolt.horizontal"
        case .sqlserver: return "server.rack"
        case .mysql, .mariadb, .postgres, .cockroach: return "cylinder"
        }
    }

    static func color(_ db: DetectedDatabase) -> NSColor {
        switch db.environment {
        case .local, .unknown: return Theme.textDim
        case .development: return Theme.text
        case .remote: return Theme.attention
        }
    }
}

/// A small outlined label: "Neon · Vercel", "Herd".
final class BadgeView: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; isHidden = text.isEmpty } }
    private let font = NSFont.systemFont(ofSize: 10, weight: .medium)

    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return .zero }
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + 10, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        Theme.textDim.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        path.lineWidth = 1
        path.stroke()
        let size = (text as NSString).size(withAttributes: [.font: font])
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: [.font: font, .foregroundColor: Theme.textDim])
    }
}

/// A database row, or the group's: icon, name with its source dimmed, provider badge, ⋯ menu.
final class DatabaseCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    let badge = BadgeView()
    private(set) lazy var more = MoreButton(toolTip: "Database actions") { [weak self] in self?.onMenu?() ?? NSMenu() }
    /// The ⋯ menu for this row (set by the sidebar each time the cell is configured).
    var onMenu: (() -> NSMenu)?
    private(set) var tipText = ""
    private(set) weak var item: DatabaseItem?

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Database actions")?
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

    func configure(_ item: DatabaseItem) {
        self.item = item
        let db = item.database
        let color = DatabaseText.color(db)
        icon.image = NSImage(systemSymbolName: DatabaseText.symbol(db.engine), accessibilityDescription: db.engine.displayName)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = color
        let text = NSMutableAttributedString(string: db.name, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: db.isConnection ? (db.environment == .local ? Theme.text : color) : Theme.textDim])
        let detail = DatabaseText.detail(db)
        if !detail.isEmpty {
            text.append(Typography.gap(7, font: .systemFont(ofSize: 11.5)))
            text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.textDim]))
        }
        name.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        badge.text = DatabaseText.badge(db)
        more.isHidden = false
        tipText = DatabaseText.tooltip(db)
        setAccessibilityLabel(DatabaseText.accessibility(db))
    }

    func configureGroup(_ group: DatabasesGroup) {
        item = nil
        icon.image = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: "Databases")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.textDim
        let text = NSMutableAttributedString(string: "Databases", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: Theme.text])
        text.append(Typography.gap(7, font: .systemFont(ofSize: 11.5)))
        text.append(NSAttributedString(string: "\(group.items.count)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.textDim]))
        name.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
        badge.text = group.vercelProject == nil ? "" : DatabaseProvider.vercel.rawValue
        more.isHidden = true
        var tip = "Databases this project’s files name, found offline: env files, Prisma, Drizzle, Supabase and SQLite files. Nothing connects until you choose a hand-off."
        if let project = group.vercelProject { tip += "\nLinked to Vercel" + (project == "linked" ? "." : " project “\(project)”.") }
        tipText = tip
        setAccessibilityLabel("Databases, \(group.items.count)")
    }

    /// What the row shows, for the self-test.
    var nameText: String { name.stringValue }
}
