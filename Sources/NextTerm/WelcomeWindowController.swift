import AppKit
import NextTermCore

/// Shown after the last project closes: recent projects one click away, plus Open and New Terminal.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let list = NSStackView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Next Term"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.bar
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        reloadRecents()
        super.showWindow(sender)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = NSTextField(labelWithString: "Next Term")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = Theme.text
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let subtitle = NSTextField(labelWithString: version.map { "Version \($0)" } ?? "Development build")
        subtitle.textColor = Theme.textDim

        let open = NSButton(title: "Open Project…", target: NSApp.delegate, action: #selector(AppDelegate.openProjectPanel(_:)))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        let terminal = NSButton(title: "New Terminal", target: self, action: #selector(newTerminal))
        terminal.bezelStyle = .rounded

        let left = NSStackView(views: [icon, title, subtitle, NSView(), open, terminal])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 8
        left.setCustomSpacing(24, after: subtitle)
        left.translatesAutoresizingMaskIntoConstraints = false

        let recentTitle = NSTextField(labelWithString: "Recent Projects")
        recentTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        recentTitle.textColor = Theme.textDim
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let flipped = FlippedView()
        flipped.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        flipped.translatesAutoresizingMaskIntoConstraints = false

        let right = NSStackView(views: [recentTitle, scroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(left)
        content.addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            left.widthAnchor.constraint(equalToConstant: 180),
            left.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 28),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            right.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            right.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: flipped.topAnchor),
            list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
    }

    /// Recent projects shown, for the self-test.
    private(set) var shownProjects: [String] = []

    private func reloadRecents() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        shownProjects = AppDelegate.shared.recentProjects
        if shownProjects.isEmpty {
            let none = NSTextField(labelWithString: "Projects you open appear here.")
            none.textColor = Theme.textDim
            list.addArrangedSubview(none)
        }
        for path in shownProjects {
            let button = NSButton(title: "", target: self, action: #selector(openRecent(_:)))
            button.isBordered = false
            button.alignment = .left
            let text = NSMutableAttributedString(string: (path as NSString).lastPathComponent + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Theme.text,
            ])
            text.append(NSAttributedString(string: RecentProjects.abbreviate(path), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim,
            ]))
            button.attributedTitle = text
            button.identifier = NSUserInterfaceItemIdentifier(path)
            button.toolTip = path
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            list.addArrangedSubview(button)
        }
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        AppDelegate.shared.openProject(at: URL(fileURLWithPath: path), from: nil)
    }

    @objc private func newTerminal() {
        AppDelegate.shared.newWindow(nil)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
