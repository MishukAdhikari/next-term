import AppKit
import NextTermCore

// MARK: - a window with no project, its tab in none

/// The sidebar of a window with no project while its tab is in no project (the home folder, /: ProjectRoot.project):
/// "No project open", the projects used last, Open Folder… and Connect to Server…, the Welcome window's ways in, and
/// Browse Home Folder, which shows the home folder's tree in this window (each folder read as the user opens it). No file
/// is listed and nothing is read or watched until then, so a New Terminal window sets off none of macOS's privacy
/// prompts. The tree comes back as the tab goes into a project.
final class NoProjectView: NSView {
    /// At most this many recent projects, the newest first.
    static let recentLimit = 5

    private let title = NSTextField(labelWithString: "No project open")
    private let sentence = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let recentRows = NSStackView()
    private let stack = NSStackView()
    /// The stack scrolls in a short window, so the ways in below the recent projects stay in reach.
    private let scroll = NSScrollView()
    /// Open Folder… (the folder panel, as the Welcome window's Open…) and Connect to Server….
    let openRow = WayInRow(.open, title: "Open Folder…")
    let connectRow = WayInRow(.connect)
    /// The home folder's files, in this window.
    let browseRow = SidebarActionRow(symbol: "house", title: "Browse Home Folder")
    /// A recent project was chosen.
    var onOpen: ((String) -> Void)?
    /// Browse Home Folder was clicked.
    var onBrowseHome: (() -> Void)?
    /// The projects listed, for the self-test.
    private(set) var listed: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        Typography.singleLine(title, truncation: .byTruncatingTail)
        sentence.stringValue = "The terminal works in any folder. Its files show here once the tab is in a project."
        sentence.font = .systemFont(ofSize: 12)
        sentence.textColor = Theme.textDim
        sentence.maximumNumberOfLines = 4
        sentence.cell?.truncatesLastVisibleLine = true
        heading.attributedStringValue = WelcomeWindowController.headingText("Recent")
        heading.setAccessibilityElement(false)
        recentRows.orientation = .vertical
        recentRows.alignment = .leading
        recentRows.spacing = 0
        recentRows.setAccessibilityElement(true)
        recentRows.setAccessibilityRole(.group)
        recentRows.setAccessibilityLabel("Recent projects")
        browseRow.target = self
        browseRow.action = #selector(browseHome)
        browseRow.toolTip = "Show your home folder’s files here. Desktop, Documents and the other folders macOS protects are read only when you open one."
        let ways = NSStackView(views: [openRow, connectRow, browseRow])
        ways.orientation = .vertical
        ways.alignment = .leading
        ways.spacing = 0
        ways.setAccessibilityElement(true)
        ways.setAccessibilityRole(.group)
        ways.setAccessibilityLabel("Start")
        connectRow.show(key: KeyboardShortcuts.shared.chord(for: SwitcherWayIn.connect.command))
        // Its key, ⌘O, brings the Welcome window here, not the folder panel this row opens: none is shown.
        openRow.show(key: nil)

        let text = NSStackView(views: [title, sentence])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.addArrangedSubview(text)
        stack.setCustomSpacing(18, after: text)
        let headingRow = NSStackView(views: [heading])
        headingRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 6, right: 14)
        stack.addArrangedSubview(headingRow)
        stack.addArrangedSubview(recentRows)
        headingRow.isHidden = true // until there is a recent project to list
        recentRows.isHidden = true
        stack.setCustomSpacing(12, after: recentRows)
        stack.addArrangedSubview(ways)
        for row in [text, recentRows, ways] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for row in [openRow, connectRow, browseRow] as [NSView] { row.widthAnchor.constraint(equalTo: ways.widthAnchor).isActive = true }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let clip: NSClipView = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("No project open")
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: KeyboardShortcuts.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The wrapping sentence wraps at the sidebar's width, less its insets.
    override func layout() {
        let width: CGFloat = max(0, bounds.width - 28)
        if sentence.preferredMaxLayoutWidth != width { sentence.preferredMaxLayoutWidth = width }
        super.layout()
    }

    @objc private func shortcutsChanged() {
        connectRow.show(key: KeyboardShortcuts.shared.chord(for: SwitcherWayIn.connect.command))
    }

    /// The recent projects, newest first, as Recent Projects keeps them (RecentProjects.existing: one in a protected
    /// place is listed as saved, never looked at). With none, no heading either.
    func show(recent paths: [String], home: String = NSHomeDirectory()) {
        let shown: [String] = Array(paths.prefix(Self.recentLimit))
        guard shown != listed else { return }
        listed = shown
        for row in recentRows.arrangedSubviews {
            recentRows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for path in shown {
            let row = RecentProjectRow(path: path, home: home)
            row.target = self
            row.action = #selector(chosen(_:))
            recentRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentRows.widthAnchor).isActive = true
        }
        heading.superview?.isHidden = shown.isEmpty
        recentRows.isHidden = shown.isEmpty
    }

    @objc private func chosen(_ sender: RecentProjectRow) { onOpen?(sender.path) }

    @objc private func browseHome() { onBrowseHome?() }

    /// For the self-test: the rows of the recent projects.
    var recentProjectRows: [RecentProjectRow] { recentRows.arrangedSubviews.compactMap { $0 as? RecentProjectRow } }
}

/// The scroll's document: its content from the top down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A recent project in a window's empty sidebar: a folder in the gutter, its name where the names start, and at the
/// right the folder it is in ("~/Code"), as the Welcome list shows it. Nothing on disk is read for it.
final class RecentProjectRow: FillButton {
    static let height: CGFloat = 26
    let path: String
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init(path: String, home: String) {
        self.path = path
        let parent: String = RecentProjects.abbreviate((path as NSString).deletingLastPathComponent, home: home)
        super.init(title: (path as NSString).lastPathComponent)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Theme.textDim
        name.stringValue = title
        name.font = .systemFont(ofSize: 13)
        name.textColor = Theme.text
        Typography.singleLine(name, truncation: .byTruncatingTail)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        folder.stringValue = parent
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = Theme.textDim
        folder.alignment = .right
        Typography.singleLine(folder, truncation: .byTruncatingHead)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add([icon, name, folder])
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.gutterCenter),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.nameX),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            folder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        toolTip = "Open \(RecentProjects.abbreviate(path, home: home)) as a project"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The Welcome list's selection shape, as the ways in below it.
    override var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5)
    }

    /// VoiceOver hears the name, then where it is.
    override func accessibilityHelp() -> String? { "In " + folder.stringValue }
}

/// A row that does one thing, in the ways in's geometry: a symbol in the gutter, its title where the names start.
final class SidebarActionRow: FillButton {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(symbol: String, title name: String) {
        super.init(title: name)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Theme.textDim
        label.stringValue = name
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        Typography.singleLine(label, truncation: .byTruncatingTail)
        add([icon, label])
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: WayInRow.height),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.gutterCenter),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.nameX),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The Welcome list's selection shape, as the ways in beside it.
    override var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5)
    }
}

// MARK: - a folder macOS refused

/// The one row in a folder macOS's privacy protection refused (FileNode.accessDenied): it says so, plainly, with the
/// button that opens the System Settings pane where the user can allow it (PrivacySettings.pane(forDenied:)).
final class DeniedFolderEntry {
    /// The folder it is in.
    weak var folder: FileNode?
    let pane: PrivacySettings.Pane

    init(folder: FileNode, pane: PrivacySettings.Pane) {
        self.folder = folder
        self.pane = pane
    }
}

/// "macOS hasn’t given Next Term access to this folder." and Open Settings, on one line: the words give way first, and
/// the tooltip says it in full, with the pane's name. No alert, and nothing comes back by itself once the row is there.
final class DeniedFolderCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: FolderAccess.deniedLine)
    let button = NSButton(title: "Open Settings", target: nil, action: nil)
    private var pane: PrivacySettings.Pane = .filesAndFolders
    /// The tooltip: the line in full, and where to allow it.
    private(set) var tipText = ""

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = Theme.textDim
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.textDim
        Typography.singleLine(label, truncation: .byTruncatingTail)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(openSettings)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, label, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ entry: DeniedFolderEntry) {
        pane = entry.pane
        let name: String = entry.folder?.name ?? "this folder"
        tipText = FolderAccess.deniedHelp(folder: name, pane: entry.pane)
        label.setAccessibilityLabel(tipText)
        button.toolTip = "Open System Settings › Privacy & Security › \(entry.pane.title)"
        button.setAccessibilityLabel("Open \(entry.pane.title) in System Settings")
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(PrivacySettings.url(pane))
    }
}

// MARK: - a window with no project, its tab in one

/// Under the header while a window with no project shows the project its tab is in: Open as Project Window, which opens
/// that folder as Open Project does (Settings › General › Open projects in), keeping the sidebar on it.
final class ProjectOfferNote: NSView {
    static let height: CGFloat = 28
    let button = NSButton(title: "Open as Project Window", target: nil, action: nil)
    /// The folder it offers, as the tree shows it.
    private(set) var folder: String?
    var onOpen: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        // The symbol in the accent, the words in the text colour: the accent's blue is too dim on the bar for small text.
        button.contentTintColor = Theme.accent
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Theme.text,
        ])
        button.alignment = .left
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(pressed)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ folder: String) {
        guard folder != self.folder else { return }
        self.folder = folder
        let name: String = (folder as NSString).lastPathComponent
        button.toolTip = "Open “\(name)” as a project: a window of its own, its sidebar kept on it"
        button.setAccessibilityLabel("Open “\(name)” as Project Window")
    }

    @objc private func pressed() {
        guard let folder else { return }
        onOpen?(folder)
    }

    override func layout() {
        super.layout()
        let h: CGFloat = bounds.height - 1
        let height: CGFloat = 20
        button.frame = NSRect(x: 10, y: (h - height) / 2, width: max(0, bounds.width - 20), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.tabHover.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
