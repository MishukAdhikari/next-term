import AppKit
import NextTermCore

/// The Welcome window's right pane while a saved server is selected: its name, where it points and the folder its tabs
/// open in, how it is kept, while it is connected what its herdr agents need ("herdr: 1 needs you, 3 working"), and
/// Connect, which Return presses.
final class WelcomeServerPane: NSView {
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let name = NSTextField(labelWithString: "")
    private let place = NSTextField(labelWithString: "")
    private let kept = NSTextField(labelWithString: "")
    /// What herdr's agents there need, while Next Term follows them (HerdrAgentMenu.summary); hidden otherwise.
    private let herdr = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private(set) var host: RemoteHost?

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.textColor = Theme.text
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        Typography.singleLine(place, truncation: .byTruncatingMiddle)
        kept.font = .systemFont(ofSize: 12)
        kept.textColor = Theme.textDim
        Typography.singleLine(kept, truncation: .byTruncatingTail)
        herdr.font = .systemFont(ofSize: 12)
        herdr.textColor = Theme.textDim
        herdr.isHidden = true
        Typography.singleLine(herdr, truncation: .byTruncatingTail)
        note.font = .systemFont(ofSize: 12)
        note.textColor = Theme.textDim
        note.stringValue = "Connect opens a window with a tab on it, in its folder."
        connectButton.bezelStyle = .rounded
        connectButton.toolTip = "Open a window with a tab on this server, over ssh"
        for view in [name, place, kept, herdr, note, connectButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Where the project's name, path and Open Project sit, so moving from a project to a server keeps the eye in
        // one place.
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            name.trailingAnchor.constraint(lessThanOrEqualTo: connectButton.leadingAnchor, constant: -16),
            place.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            place.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            place.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            kept.topAnchor.constraint(equalTo: place.bottomAnchor, constant: 3),
            kept.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            kept.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            herdr.topAnchor.constraint(equalTo: kept.bottomAnchor, constant: 3),
            herdr.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            herdr.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            note.topAnchor.constraint(equalTo: herdr.bottomAnchor, constant: 25),
            note.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            connectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            connectButton.centerYAnchor.constraint(equalTo: name.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ host: RemoteHost) {
        self.host = host
        name.stringValue = host.name
        name.toolTip = host.name
        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textDim]
        let line = NSMutableAttributedString(string: host.destination, attributes: attributes)
        line.append(Typography.gap(14, font: font))
        line.append(NSAttributedString(string: host.directory, attributes: attributes))
        place.attributedStringValue = Typography.truncating(line, .byTruncatingMiddle)
        place.toolTip = "\(host.destination), tabs open in \(host.directory)"
        place.setAccessibilityLabel("\(host.destination), in \(host.directory)")
        kept.stringValue = Self.keptText(host.keep)
        kept.toolTip = Self.keptHelp(host.keep)
        let agents = host.keep == .herdr ? HerdrAgentMenu.summary(host: host) : nil
        herdr.stringValue = agents ?? ""
        herdr.isHidden = agents == nil
        connectButton.setAccessibilityHelp("Opens a window with a tab on \(host.name), in \(host.directory)")
    }

    /// How the server keeps what runs on it: "kept with tmux", "kept with herdr", or "plain ssh".
    static func keptText(_ keep: KeepMode) -> String {
        switch keep {
        case .off: return "plain ssh"
        case .tmux: return "kept with tmux"
        case .herdr: return "kept with herdr"
        }
    }

    private static func keptHelp(_ keep: KeepMode) -> String {
        switch keep {
        case .off: return "What runs in a tab on it stops when the connection drops."
        case .tmux: return "Its sessions keep running on the server while this Mac is away, and any Mac can attach to them again."
        case .herdr: return "Your herdr on the server keeps its agents running while this Mac is away."
        }
    }

    /// For the self-test: what the pane says, line by line.
    var shownLines: [String] { [name.stringValue, place.stringValue, kept.stringValue] + (herdr.isHidden ? [] : [herdr.stringValue]) }
}
