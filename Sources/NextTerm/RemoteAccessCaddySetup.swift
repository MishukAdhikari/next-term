import AppKit
import NextTermCore

/// "Set up Caddy on <server>" (R48, U15): offered, never automatic. A confirmation lists the exact commands for the
/// server's system, picked in it; only once the user accepts are they typed, as one line, into a visible remote tab
/// on the server, at its shell's prompt, where the user answers sudo. Nothing runs on the server otherwise: no
/// command before the confirmation, and none to find out the system.
@MainActor
final class RemoteAccessCaddySetup: NSObject {
    typealias Config = RemoteAccessTunnelConfig

    enum Outcome: Equatable {
        case canceled
        /// Typed into the tab, which shows how it went.
        case typed
        /// Accepted, but not typed: why.
        case notTyped(String)
    }

    /// How long the tab may take to reach the server's prompt, the user's login there included.
    static let promptWait: TimeInterval = 300

    private let server: Config.OwnServer
    private let hostname: String
    private let alert = NSAlert()
    private let systems = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandsView = NSTextView(frame: .zero)

    #if DEBUG
    /// The confirmation while it is shown, for the self-test (U12), which offers it on a window and answers through
    /// its buttons: nothing is typed before the first one.
    static weak var shown: RemoteAccessCaddySetup?
    var shownAlert: NSAlert { alert }
    var shownCommands: [String] { commands }
    #endif

    private init(server: Config.OwnServer, hostname: String) {
        self.server = server
        self.hostname = hostname
        super.init()
    }

    /// Shows the confirmation, as a sheet on `window` when there is one. `done` gets what happened. Nil commands
    /// (no public hostname saved, or no server port) show nothing and say why.
    static func offer(on server: Config.OwnServer, hostname: String, window: NSWindow?,
                      done: @escaping @MainActor (Outcome) -> Void) {
        guard Config.caddySetup(.apt, hostname: hostname, serverPort: server.port) != nil else {
            return done(.notTyped(RemoteAccessStatus.hostNeeded))
        }
        let setup = RemoteAccessCaddySetup(server: server, hostname: hostname)
        setup.build()
        #if DEBUG
        shown = setup
        #endif
        // Holds the setup until the user answers.
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return done(.canceled) }
                setup.typeCommands(done: done)
            }
        }
        if let window {
            setup.alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(setup.alert.runModal())
        }
    }

    /// The commands for the system picked now.
    private var system: Config.CaddySystem {
        let index = systems.indexOfSelectedItem
        let all = Config.CaddySystem.allCases
        return all.indices.contains(index) ? all[index] : .apt
    }

    private var commands: [String] {
        Config.caddySetup(system, hostname: hostname, serverPort: server.port) ?? []
    }

    // MARK: the confirmation

    private func build() {
        let name = server.name
        alert.messageText = "Set up Caddy on \(name)?"
        let intro = "Next Term types these commands into a remote tab on \(name), as one line, once its shell is "
            + "ready. sudo asks for your password there."
        let what = "They add a site for \(hostname) that passes requests to 127.0.0.1:\(server.port) on \(name), "
            + "check Caddy's whole config, and start or reload Caddy. With Debian, Ubuntu or Fedora picked, they "
            + "install Caddy first. If the check fails, they put your Caddyfile back as it was and stop. Your other "
            + "Caddy sites stay as they are."
        let other = "On another system, install Caddy yourself first (caddyserver.com/docs/install), then pick "
            + "\"\(Config.CaddySystem.installed.label)\"."
        let needs = "Ports 80 and 443 must be open on \(name), and \(hostname) must point to it in DNS."
        alert.informativeText = [intro, what, other, needs].joined(separator: "\n\n")
        let action = alert.addButton(withTitle: "Type Commands on \(name)")
        // No default button: Return never types sudo commands on a server.
        action.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.accessoryView = accessory()
        showCommands()
    }

    private func accessory() -> NSView {
        let label = NSTextField(labelWithString: "Server system:")
        for system in Config.CaddySystem.allCases { systems.addItem(withTitle: system.label) }
        systems.selectItem(at: 0)
        systems.target = self
        systems.action = #selector(systemChanged)
        let row = NSStackView(views: [label, systems])
        row.orientation = .horizontal
        row.spacing = 8

        commandsView.isEditable = false
        commandsView.isSelectable = true
        commandsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandsView.textContainerInset = NSSize(width: 4, height: 4)
        commandsView.isVerticallyResizable = true
        commandsView.isHorizontallyResizable = false
        commandsView.textContainer?.widthTracksTextView = true
        commandsView.setAccessibilityLabel("The commands Next Term types")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 150))
        scroll.documentView = commandsView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        commandsView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        commandsView.autoresizingMask = [.width]

        let stack = NSStackView(views: [row, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: 186)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 520),
            scroll.heightAnchor.constraint(equalToConstant: 150),
        ])
        return stack
    }

    @objc private func systemChanged() {
        showCommands()
    }

    /// Each command on a line of its own, joined by `&&` as they are typed.
    private func showCommands() {
        let shown = commands.enumerated().map { index, command in
            index < commands.count - 1 ? command + " &&" : command
        }
        commandsView.string = shown.joined(separator: "\n")
    }

    // MARK: typing them

    /// Accepted: a visible remote tab on the server, and the line typed there once its shell is at the prompt.
    private func typeCommands(done: @escaping @MainActor (Outcome) -> Void) {
        let line = Config.caddySetupLine(commands)
        guard !line.isEmpty else { return done(.notTyped(RemoteAccessStatus.hostNeeded)) }
        let tab = RemoteAccessServerTab.open(server.host)
        let name = server.name
        RemoteAccessServerTab.type(line, into: tab, within: Self.promptWait) { typed in
            guard !typed else { return done(.typed) }
            done(.notTyped("The tab on \(name) didn't reach its prompt, so nothing was typed. Set up Caddy again "
                + "once you are logged in there."))
        }
    }
}

// MARK: - the controller's entry (U11's button)

extension RemoteAccess {
    /// "Set up Caddy on <server>", only on that click: the confirmation for the chosen server, the saved public
    /// hostname and its server port, then the typed commands (R48).
    /// The typed commands get a tunnel line in the audit log (R39).
    func setUpCaddy(window: NSWindow?, done: @escaping @MainActor (RemoteAccessCaddySetup.Outcome) -> Void) {
        guard let server = ownServer() else { return done(.notTyped(RemoteAccessTunnelConfig.serverNeeded)) }
        guard let hostname = settings.host else { return done(.notTyped(RemoteAccessStatus.hostNeeded)) }
        RemoteAccessCaddySetup.offer(on: server, hostname: hostname, window: window) { [weak self] outcome in
            if outcome == .typed {
                let detail = "\(server.name): \(hostname) to 127.0.0.1:\(server.port)"
                self?.auditTunnel("caddy_typed", detail: detail)
            }
            done(outcome)
        }
    }
}
