#if DEBUG
import AppKit
import NextTermCore

// MARK: - A row's name and detail in a narrow sidebar

extension SelfTest {
    /// How a row's line stands as laid out: everything whole, the detail cut or hidden, or the name cut.
    private enum LineState: String {
        case whole, detailCut = "detail cut", detailHidden = "detail hidden", nameCut = "name cut"
    }

    /// The Databases and Services rows' name and dimmed detail from a wide sidebar to a narrow one, in cells made for the
    /// check and configured as the sidebar's own (nothing on screen moves): the name stays whole while the row has room
    /// for it; the detail shows whole, cut to at least its first characters, or not at all, and goes before the name is
    /// cut; neither runs into the badge. Then the same on the sidebar's own rows, at the sidebar's width.
    static func rowFitChecks(_ sidebar: ProjectSidebarView) {
        guard let database = sidebar.databasesGroup.items.first,
              let openAI = sidebar.servicesGroup.items.first(where: { $0.row.name == "OpenAI" }) else {
            return check(false, "links: the RAG project shows a database row and OpenAI's row to fit")
        }
        let databaseCell = DatabaseCellView()
        let databasesCell = DatabaseCellView()
        let serviceCell = ServiceCellView()
        let servicesCell = ServiceCellView()
        // In a view of their own, as the outline holds its cells: the frame each is given then fixes its width for the
        // constraints, where a cell with no superview leaves it loose and its places drift.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        for cell in [databaseCell, databasesCell, serviceCell, servicesCell] as [NSView] {
            host.addSubview(cell)
            cell.setFrameSize(NSSize(width: 320, height: 22))
        }
        databaseCell.configure(database)
        databasesCell.configureGroup(sidebar.databasesGroup)
        serviceCell.configure(openAI)
        servicesCell.configureGroup(sidebar.servicesGroup)
        let rows: [(String, NSView, NameDetailLine, NSView)] = [
            ("the database row", databaseCell, databaseCell.line, databaseCell.badge),
            ("Databases", databasesCell, databasesCell.line, databasesCell.badge),
            ("OpenAI", serviceCell, serviceCell.line, serviceCell.badge),
            ("Services", servicesCell, servicesCell.line, servicesCell.badge),
        ]
        var problems: [String] = []
        var openAISeen: Set<String> = []
        for (label, row, line, badge) in rows {
            for width in stride(from: CGFloat(320), through: 40, by: -1) {
                row.setFrameSize(NSSize(width: width, height: 22))
                host.layoutSubtreeIfNeeded()
                // Narrower than this the row has no room for any name; the sidebar never gets there.
                guard place(badge).minX - NameDetailLine.toBadge - place(line.name).minX >= 12 else { break }
                let look = lineLook(row, line, badge: badge)
                if let problem = look.problem { problems.append("\(label): \(problem)") }
                if label == "OpenAI" { openAISeen.insert(look.state.rawValue) }
            }
        }
        let swept = [LineState.whole, .detailCut, .detailHidden, .nameCut].allSatisfy { openAISeen.contains($0.rawValue) }
        check(problems.isEmpty && swept,
              "links: in a narrowing sidebar the rows' names stay whole while they fit, and the dimmed detail gives way first",
              problems.first ?? "OpenAI's row went " + openAISeen.sorted().joined(separator: ", "))
        sidebarRowFitCheck(sidebar)
    }

    /// The sidebar's own Databases and Services rows, as laid out at its width now, pass the same look.
    private static func sidebarRowFitCheck(_ sidebar: ProjectSidebarView) {
        let outline = sidebar.outline
        var problems: [String] = []
        var looked = 0
        for row in 0..<outline.numberOfRows {
            let item = outline.item(atRow: row)
            guard item is DatabaseItem || item is DatabasesGroup || ServicesGroup.holds(item) else { continue }
            outline.scrollRowToVisible(row)
            outline.layoutSubtreeIfNeeded()
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            cell.layoutSubtreeIfNeeded()
            let look: (state: LineState, problem: String?)
            if let database = cell as? DatabaseCellView {
                look = lineLook(database, database.line, badge: database.badge)
            } else if let service = cell as? ServiceCellView {
                look = lineLook(service, service.line, badge: service.badge)
            } else {
                continue
            }
            looked += 1
            if let problem = look.problem { problems.append("row \(row): \(problem)") }
        }
        check(looked > 2 && problems.isEmpty, "links: the sidebar's Databases and Services rows show their names whole as they fit",
              problems.first ?? "\(looked) rows")
    }

    /// Where `view` sits as the constraints place it: its alignment rect, which leaves out a label's insets.
    private static func place(_ view: NSView) -> NSRect { view.alignmentRect(forFrame: view.frame) }

    /// How `line` stands in `row` as laid out now, and what is wrong with it, if anything. Read from the labels' places,
    /// not from NameDetailFit's sums, so a constraint that drifts from NameDetailLine's constants shows here. A point
    /// either way is the layout's rounding.
    private static func lineLook(_ row: NSView, _ line: NameDetailLine, badge: NSView) -> (state: LineState, problem: String?) {
        let slack: CGFloat = 1
        let gap = NameDetailLine.detailGap
        let name = place(line.name)
        let detail = place(line.detail)
        let end: CGFloat = place(badge).minX - NameDetailLine.toBadge
        let room: CGFloat = end - name.minX
        let nameWhole: CGFloat = line.name.intrinsicContentSize.width
        let hasDetail = !line.detail.stringValue.isEmpty
        let detailWhole: CGFloat = hasDetail ? line.detail.intrinsicContentSize.width : 0
        let shown = hasDetail && !line.detail.isHidden
        let nameCut = name.width < nameWhole - slack
        let detailWholeShown = shown && detail.width >= detailWhole - slack
        let detailSays = shown ? "\(Int(detail.width)) of \(Int(detailWhole))" : "hidden"
        let at = "at \(Int(row.frame.width)) pt (room \(Int(room))): name \(Int(name.width)) of \(Int(nameWhole)), detail \(detailSays)"
        var problem: String?
        if name.maxX > end + slack || (shown && detail.maxX > end + slack) {
            problem = "runs into the badge " + at
        } else if nameCut && nameWhole <= room - slack {
            problem = "the name is cut though it fits " + at
        } else if nameCut && shown {
            problem = "the name is cut before the detail " + at
        } else if shown && detail.width < min(detailWhole, line.minimumDetail) - slack {
            problem = "the detail shows a sliver " + at
        } else if shown && detail.minX < name.maxX + gap - slack {
            problem = "the detail has lost its gap " + at
        } else if hasDetail && nameWhole + gap + detailWhole <= room - slack && !detailWholeShown {
            problem = "the detail is cut though it fits " + at
        }
        let state: LineState
        if nameCut {
            state = .nameCut
        } else if !hasDetail || detailWholeShown {
            state = .whole
        } else {
            state = shown ? .detailCut : .detailHidden
        }
        return (state, problem)
    }
}
#endif
