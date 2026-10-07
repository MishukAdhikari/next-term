import AppKit
import NextTermCore

/// How the Git Log looks: lane colours, sizes, ref badges and dates.
enum GitLogStyle {
    /// One colour per lane colour of CommitGraph, readable on the dark background.
    static let lanes: [NSColor] = [0x6EA4F7, 0x73C27A, 0xE5A55C, 0xC28FE0, 0x5FC4C4, 0xE5736F, 0xD6C86A, 0x9AA3F5].map { NSColor(hex: $0) }
    static let rowHeight: CGFloat = 24
    static let laneWidth: CGFloat = 14
    static let graphInset: CGFloat = 6
    /// Wider than this many lanes, the rightmost share the last column.
    static let maxLanes = 20

    static func lane(_ index: Int) -> NSColor { lanes[((index % lanes.count) + lanes.count) % lanes.count] }

    static func graphWidth(lanes: Int) -> CGFloat { graphInset * 2 + CGFloat(max(1, lanes)) * laneWidth }

    /// Badge colour by kind: the branch checked out green, branches blue, remote ones violet, tags amber.
    static func badge(_ ref: CommitRef) -> NSColor {
        if ref.isCurrent || ref.kind == .head { return Theme.done }
        switch ref.kind {
        case .branch: return Theme.gitModified
        case .remote: return NSColor(hex: 0xB792E6)
        case .tag: return Theme.attention
        case .head, .other: return Theme.textDim
        }
    }

    /// The branch checked out first, then HEAD, branches, tags, remote branches.
    static func ordered(_ refs: [CommitRef]) -> [CommitRef] {
        func rank(_ ref: CommitRef) -> Int {
            if ref.isCurrent { return 0 }
            switch ref.kind {
            case .head: return 1
            case .branch: return 2
            case .tag: return 3
            case .remote: return 4
            case .other: return 5
            }
        }
        return refs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// "5 minutes ago" within a week, then the date and time.
    static func dateText(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age >= 0, age < 60 { return "Just now" }
        if age >= 0, age < 7 * 86_400 { return relative.localizedString(for: date, relativeTo: now) }
        return absolute.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

/// One row's piece of the graph: the lines through it and the commit's dot. Rows touch, so the lines
/// join from row to row.
final class GitGraphView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("GitGraph")
    var row: GraphRow? { didSet { needsDisplay = true } }
    /// HEAD's commit gets a ring around its dot.
    var isHead = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func x(_ column: Int) -> CGFloat { GitLogStyle.graphInset + (CGFloat(column) + 0.5) * GitLogStyle.laneWidth }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let mid = bounds.midY, bottom = bounds.maxY
        func stroke(_ line: GraphRow.Line, from y0: CGFloat, to y1: CGFloat) {
            let path = NSBezierPath()
            let start = NSPoint(x: Self.x(line.from), y: y0), end = NSPoint(x: Self.x(line.to), y: y1)
            path.move(to: start)
            if line.from == line.to {
                path.line(to: end)
            } else {
                // Leaves vertically and arrives vertically, bending in between.
                let bend = (y1 - y0) * 0.6
                path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: y0 + bend), controlPoint2: NSPoint(x: end.x, y: y1 - bend))
            }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            GitLogStyle.lane(line.color).setStroke()
            path.stroke()
        }
        for line in row.top { stroke(line, from: 0, to: mid) }
        for line in row.bottom { stroke(line, from: mid, to: bottom) }

        let center = NSPoint(x: Self.x(row.column), y: mid)
        let color = GitLogStyle.lane(row.color)
        let radius: CGFloat = 4
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if row.isMerge {
            // A merge: a ring, hollow in the middle.
            Theme.background.setFill()
            dot.fill()
            dot.lineWidth = 2
            color.setStroke()
            dot.stroke()
        } else {
            color.setFill()
            dot.fill()
        }
        if isHead {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13))
            ring.lineWidth = 1.2
            Theme.text.withAlphaComponent(0.85).setStroke()
            ring.stroke()
        }
    }
}

/// A commit's subject after its branch, tag and HEAD badges.
final class GitSubjectView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("GitSubject")
    private var subject = ""
    private var refs: [CommitRef] = []
    private static let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let subjectFont = NSFont.systemFont(ofSize: 12.5)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ commit: Commit) {
        subject = commit.subject
        refs = GitLogStyle.ordered(commit.refs)
        let names = refs.map(\.name).joined(separator: ", ")
        setAccessibilityLabel(names.isEmpty ? subject : "\(subject), \(names)")
        toolTip = names.isEmpty ? nil : names
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 4
        let height: CGFloat = 16
        let top = (bounds.height - height) / 2
        // Badges take at most half the width; the rest are counted in a last one.
        let limit = bounds.width * 0.5
        for (index, ref) in refs.enumerated() {
            let left = refs.count - index
            let label = x > limit ? "+\(left)" : (ref.isCurrent ? "HEAD → " : "") + Typography.shortened(ref.name, to: 32)
            let color = x > limit ? Theme.textDim : GitLogStyle.badge(ref)
            let text = NSAttributedString(string: label, attributes: [.font: Self.badgeFont, .foregroundColor: ref.isCurrent && x <= limit ? Theme.background : color])
            let width = ceil(text.size().width) + 10
            let rect = NSRect(x: x, y: top, width: width, height: height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            if ref.isCurrent, x <= limit {
                color.setFill()
                shape.fill()
            } else {
                color.withAlphaComponent(0.16).setFill()
                shape.fill()
                shape.lineWidth = 1
                color.withAlphaComponent(0.55).setStroke()
                shape.stroke()
            }
            text.draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + (height - text.size().height) / 2))
            x = rect.maxX + 6
            if label.hasPrefix("+") { break }
        }
        let style = Typography.paragraph(.byTruncatingTail)
        let text = NSAttributedString(string: subject, attributes: [.font: Self.subjectFont, .foregroundColor: Theme.text, .paragraphStyle: style])
        let lineHeight = text.size().height
        text.draw(with: NSRect(x: x, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - x - 4), height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A plain text cell (author, date, a file's counts).
final class GitTextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment = .natural) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = Theme.textDim
        field.alignment = alignment
        Typography.singleLine(field, truncation: .byTruncatingTail)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Full-width selection, so the graph's lines stay unbroken across the selected row.
final class GitLogRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.selection : NSColor(hex: 0x2E3138)).setFill()
        bounds.fill()
    }
}
