import AppKit
import NextTermCore

/// Settings › Remote Access's Security section: the master key (set, change, replace with the recovery key) and the
/// security checklist (RemoteAccessChecklist). macOS's own settings are read, never changed: their rows open System
/// Settings. FileVault and the firewall are read off the main thread, once a minute at most.
@MainActor
final class RemoteAccessSecuritySection: NSStackView {
    /// The columns every row shares, so the marks, the words and the buttons line up: a mark, the words (a title
    /// and a line under it), and the actions in one column at the right.
    static let markWidth: CGFloat = 18
    static let textWidth: CGFloat = 360
    static let actionsWidth: CGFloat = 160
    private let setButton = NSButton(title: "Set Master Key…", target: nil, action: nil)
    private let changeButton = NSButton(title: "Change…", target: nil, action: nil)
    private let recoverButton = NSButton(title: "Use Recovery Key…", target: nil, action: nil)
    private let rowsStack = NSStackView()
    private let ruleNote = NSTextField(wrappingLabelWithString: "")
    /// The connections the checklist counts, from the Connections section.
    var connections: () -> [RemoteAccessConnectionRow] = { [] }
    /// Opens the tunnel choice and the connections, in the pane this section is in.
    var showTunnel: () -> Void = {}
    var showConnections: () -> Void = {}

    private static var systemFacts: (fileVault: Bool?, firewall: Bool?, read: Date)?
    /// FileVault and the firewall as last read here, for MCP's remote_access_guide; nil until Settings read them.
    static var lastSystemFacts: (fileVault: Bool?, firewall: Bool?)? { systemFacts.map { ($0.fileVault, $0.firewall) } }
    private var actions: [ObjectIdentifier: RemoteAccessChecklist.Action] = [:]

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let title = NSTextField(labelWithString: "Security")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        for (button, action) in [(setButton, #selector(setKey)), (changeButton, #selector(changeKey)), (recoverButton, #selector(recoverKey))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        for button in [setButton, changeButton, recoverButton] { button.controlSize = .small }
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        ruleNote.textColor = .secondaryLabelColor
        ruleNote.font = .systemFont(ofSize: 11)
        ruleNote.preferredMaxLayoutWidth = Self.textWidth
        ruleNote.isHidden = true
        for view in [title, rowsStack, ruleNote] { addArrangedSubview(view) }
        setCustomSpacing(10, after: title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        let set = MasterKeyGate.isSet
        readSystemFactsIfStale()
        var facts = RemoteAccessChecklist.Facts()
        facts.masterKeySet = set
        facts.tunnel = RemoteAccess.shared.settings.tunnel
        facts.host = RemoteAccess.shared.settings.host
        facts.controlWithoutAsking = connections().filter { !$0.options[.askOnMac] }.count
        facts.fileVaultOn = Self.systemFacts?.fileVault
        facts.firewallOn = Self.systemFacts?.firewall
        show(RemoteAccessChecklist.rows(facts))
    }

    private func show(_ rows: [RemoteAccessChecklist.Row]) {
        for view in rowsStack.arrangedSubviews { view.removeFromSuperview() }
        for button in [setButton, changeButton, recoverButton] { button.removeFromSuperview() }
        actions.removeAll()
        for row in rows {
            let mark = NSImageView()
            let (symbol, tint): (String, NSColor) = switch row.state {
            case .done: ("checkmark.circle.fill", .systemGreen)
            case .suggested: (row.required ? "exclamationmark.circle.fill" : "circle", row.required ? .systemRed : .systemOrange)
            case .notChecked: ("questionmark.circle", .tertiaryLabelColor)
            }
            mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            mark.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            mark.contentTintColor = tint
            mark.widthAnchor.constraint(equalToConstant: Self.markWidth).isActive = true
            let title = NSTextField(labelWithString: row.title)
            title.font = .systemFont(ofSize: 13)
            var heading: [NSView] = [title]
            if row.required {
                let required = NSTextField(labelWithString: "Required")
                required.font = .systemFont(ofSize: 11, weight: .medium)
                required.textColor = row.state == .done ? .secondaryLabelColor : .systemRed
                heading.append(required)
            }
            let headingRow = NSStackView(views: heading)
            headingRow.alignment = .firstBaseline
            headingRow.spacing = 6
            let detail = NSTextField(wrappingLabelWithString: row.detail)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 11)
            detail.preferredMaxLayoutWidth = Self.textWidth
            let text = NSStackView(views: [headingRow, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
            var buttons: [NSButton] = []
            if row.id == "master-key" {
                buttons = MasterKeyGate.isSet ? [changeButton, recoverButton] : [setButton]
            } else if !row.actionTitle.isEmpty {
                let button = NSButton(title: row.actionTitle, target: self, action: #selector(rowAction(_:)))
                button.bezelStyle = .rounded
                button.controlSize = .small
                actions[ObjectIdentifier(button)] = row.action
                buttons = [button]
            }
            let actionsColumn = NSStackView(views: buttons)
            actionsColumn.orientation = .vertical
            actionsColumn.alignment = .leading
            actionsColumn.spacing = 4
            actionsColumn.widthAnchor.constraint(equalToConstant: Self.actionsWidth).isActive = true
            let line = NSStackView(views: [mark, text, actionsColumn])
            line.alignment = .top
            line.spacing = 8
            line.setAccessibilityLabel("\(row.title): " + (row.state == .done ? "done" : row.state == .suggested ? "suggested" : "not checked"))
            rowsStack.addArrangedSubview(line)
        }
    }

    // MARK: actions

    @objc private func setKey() {
        MasterKeyGate.setUp(over: window) { [weak self] _ in self?.refresh() }
    }

    @objc private func changeKey() {
        MasterKeyGate.change(over: window) { [weak self] _ in self?.refresh() }
    }

    @objc private func recoverKey() {
        MasterKeyGate.recover(over: window) { [weak self] _ in self?.refresh() }
    }

    @objc private func rowAction(_ sender: NSButton) {
        guard let action = actions[ObjectIdentifier(sender)] else { return }
        switch action {
        case .setMasterKey: setKey()
        case .chooseTunnel: showTunnel()
        case .reviewConnections: showConnections()
        case .openSystemSettings(let url): NSWorkspace.shared.open(url)
        case .updateCloudflared: showTunnel()
        case .copyEdgeRule:
            guard let host = RemoteAccess.shared.settings.host else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RemoteAccessChecklist.edgeRule(host: host), forType: .string)
            ruleNote.stringValue = "Copied. In Cloudflare, add it as a WAF custom rule with the action Block. First create an IP "
                + "list named \(RemoteAccessChecklist.listName) from \(RemoteAccessChecklist.openAIRangesURL.absoluteString), "
                + "and refresh it from time to time: OpenAI's addresses change."
            ruleNote.isHidden = false
        case .none: break
        }
    }

    // MARK: macOS's own settings, read only

    private func readSystemFactsIfStale() {
        if let read = Self.systemFacts?.read, Date().timeIntervalSince(read) < 60 { return }
        Self.systemFacts = (Self.systemFacts?.fileVault, Self.systemFacts?.firewall, Date())
        Task.detached {
            let vault = Self.output("/usr/bin/fdesetup", ["status"]).flatMap(RemoteAccessChecklist.fileVault(fromStatus:))
            let wall = Self.output("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
                .flatMap(RemoteAccessChecklist.firewall(fromState:))
            await MainActor.run { [weak self] in
                Self.systemFacts = (vault, wall, Date())
                self?.refresh()
            }
        }
    }

    nonisolated private static func output(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
