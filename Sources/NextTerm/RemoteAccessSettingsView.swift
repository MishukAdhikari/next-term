import AppKit
import NextTermCore

/// Settings › Remote Access (U11), top to bottom: the switch, disabled while agent control is off (R1); the tunnel,
/// in a guided mode that recommends what is ready on this Mac, or all four choices (R28, R49); the chosen tunnel's
/// panel, with the tool's version or how to install it, its setup a step at a time, the Cloudflare token, the
/// hostname, your own server, the local address and the checks (R29, R30, R33, R35, R46 to R48); the status line
/// with Test Connection and "Allow Keychain access" (R36, R44); Connect a Client, the connector URL and the leak
/// notice; the connections with Edit… and Revoke (R15, R22, R60); Keep Awake on Battery and the lid note (R41); what
/// to do if the tunnel token leaked; and the activity (R39).
///
/// The tunnel's settings apply at the next start, so they wait while Remote access is on. Everything is read again
/// when Remote access changes, when agent control changes, and when the window comes to the front; the tools are
/// looked for when the tab shows, at most every 30 seconds after that, and on Check Again.
@MainActor
final class RemoteAccessSettingsView: NSView {
    typealias Kind = RemoteAccessTunnelConfig.Kind
    typealias Config = RemoteAccessTunnelConfig
    typealias Text = RemoteAccessSettingsText
    typealias Guide = RemoteAccessGuide

    /// The tab's identifier in Settings.
    static let tabID = "remoteAccess"
    static let contentWidth: CGFloat = 548
    static let detectAgain: TimeInterval = 30

    // MARK: the switch

    let onSwitch = NSSwitch()
    let statusLabel = NSTextField(labelWithString: "")
    let switchNote = RemoteAccessSettingsView.note("")

    // MARK: the tunnel

    let lockedNote = RemoteAccessSettingsView.note(RemoteAccessSettingsText.lockedWhileOn)
    let guideTitle = NSTextField(wrappingLabelWithString: "")
    let guideWhy = RemoteAccessSettingsView.note("")
    let useButton = NSButton(title: "", target: nil, action: nil)
    let needsStack = NSStackView()
    let choicesStack = NSStackView()
    /// The radio button of each choice in "Show all options".
    private(set) var choiceButtons: [Kind: NSButton] = [:]
    let modeButton = NSButton(title: RemoteAccessSettingsText.showAllOptions, target: nil, action: nil)

    // MARK: the chosen tunnel

    let providerBox = NSStackView()
    let providerTitle = NSTextField(labelWithString: "")
    let trafficLabel = RemoteAccessSettingsView.note("")
    let toolLabel = NSTextField(wrappingLabelWithString: "")
    let checkAgainButton = NSButton(title: "Check Again", target: nil, action: nil)
    let warningsLabel = NSTextField(wrappingLabelWithString: "")
    let stepsStack = NSStackView()
    let tokenRow = NSStackView()
    let tokenField = NSSecureTextField()
    let saveTokenButton = NSButton(title: "Save Token", target: nil, action: nil)
    let tunnelIDLabel = NSTextField(labelWithString: "")
    let removeTokenButton = NSButton(title: "Remove Token", target: nil, action: nil)
    let tokenSavedRow = NSStackView()
    let tokenMessage = NSTextField(wrappingLabelWithString: "")
    let hostLabel = NSTextField(wrappingLabelWithString: "")
    let confirmRow = NSStackView()
    let confirmLabel = NSTextField(wrappingLabelWithString: "")
    let confirmButton = NSButton(title: "Confirm", target: nil, action: nil)
    let declineButton = NSButton(title: "Decline", target: nil, action: nil)
    let hostRow = NSStackView()
    let hostField = NSTextField()
    let saveHostButton = NSButton(title: "Save", target: nil, action: nil)
    let hostMessage = NSTextField(wrappingLabelWithString: "")
    let serverBox = NSStackView()
    let serverPopup = NSPopUpButton()
    let serverPortLabel = NSTextField(labelWithString: "")
    let newServerPortButton = NSButton(title: RemoteAccessTunnelConfig.newServerPortTitle, target: nil, action: nil)
    let caddyfileLabel = NSTextField(wrappingLabelWithString: "")
    let caddyButton = NSButton(title: "Set Up Caddy…", target: nil, action: nil)
    let caddyMessage = RemoteAccessSettingsView.note("")
    let addressRow = NSStackView()
    let addressLabel = NSTextField(labelWithString: "")
    let copyAddressButton = NSButton(title: "Copy", target: nil, action: nil)
    let checklistLabel = NSTextField(wrappingLabelWithString: "")
    let advancedWarning = NSTextField(wrappingLabelWithString: RemoteAccessTunnelConfig.advancedWarning)

    // MARK: the status

    let statusLine = NSTextField(wrappingLabelWithString: "")
    let keychainButton = NSButton(title: "Allow Keychain Access", target: nil, action: nil)
    let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    let otherHostButton = NSButton(title: "", target: nil, action: nil)
    let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
    let testResult = RemoteAccessSettingsView.note("")
    let outputButton = NSButton(title: "Show Tunnel Output", target: nil, action: nil)
    let outputLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: Connect a Client

    let connectButton = NSButton(title: "Connect a Client…", target: nil, action: nil)
    let countdownLabel = NSTextField(labelWithString: "")
    let connectorRow = NSStackView()
    let connectorLabel = NSTextField(labelWithString: "")
    let copyConnectorButton = NSButton(title: "Copy", target: nil, action: nil)
    let connectNote = RemoteAccessSettingsView.note(RemoteAccessSettingsText.connectNeedsHost)
    let leakNotice = NSTextField(wrappingLabelWithString: RemoteAccessSettingsText.leakNotice)

    // MARK: the rest

    let connections = RemoteAccessConnectionsView()
    let keepAwake = NSButton(checkboxWithTitle: RemoteAccessSettingsText.keepAwakeLabel, target: nil, action: nil)
    let leakedBox = NSStackView()
    let activity = RemoteAccessActivityView()

    /// What the last look for the tools found; nil until it answers.
    private(set) var detection: RemoteAccessTunnel.Detection?
    private var detectedAt: Date?
    private var detecting = false
    /// "Show all options" is open.
    private(set) var showsAll = false
    /// "Set up Caddy" typed its commands since this view was made.
    private var caddyTyped = false
    private var testing = false
    private var tokenBusy = false
    private var timer: Timer?
    private var keyObserver: NSObjectProtocol?
    private var ticks = 0
    private var refreshing = false
    private var refreshAgain = false
    /// The saved token's tunnel id, as this pass read it.
    private var tunnelID: String?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed), name: RemoteAccess.didChange, object: nil)
        center.addObserver(self, selector: #selector(changed), name: MCPRegistration.changed, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown: the tools are looked for, and the countdown and the times tick while it shows.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        let key = NSWindow.didBecomeKeyNotification
        keyObserver = NotificationCenter.default.addObserver(forName: key, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameToFront() }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        detect()
        refresh()
    }

    @objc private func changed() {
        refresh()
    }

    private func cameToFront() {
        if detectedAt.map({ Date().timeIntervalSince($0) >= Self.detectAgain }) ?? true { detect() }
        refresh()
    }

    /// Every second while the window shows: the pairing countdown; every 30, the connections' times. A closed
    /// Settings window keeps its views, so the timer runs on, but does nothing.
    private func tick() {
        guard window?.isVisible == true else { return }
        refreshCountdown()
        ticks += 1
        if ticks % 30 == 0 { refreshConnections() }
    }

    /// Looks for the tools off the main thread (5 seconds each at most).
    func detect(done: (@MainActor () -> Void)? = nil) {
        guard !detecting else { return }
        detecting = true
        checkAgainButton.isEnabled = false
        RemoteAccessTunnel.detect { [weak self] found in
            guard let self else { return }
            self.detecting = false
            self.detection = found
            self.detectedAt = Date()
            self.checkAgainButton.isEnabled = true
            self.refresh()
            done?()
        }
    }

    // MARK: words and controls

    static func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return note
    }

    static func title(_ text: String) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        return title
    }

    /// A wrapping label as wide as the column, less `indent`.
    private func fit(_ label: NSTextField, indent: CGFloat = 0) {
        let width = Self.contentWidth - indent
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = spacing
        return row
    }

    private func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = spacing
        return column
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - building

extension RemoteAccessSettingsView {
    private func build() {
        let sections: [NSView] = [
            buildSwitch(), buildTunnel(), buildProvider(), buildStatus(), buildConnect(),
            section("Connections", [connections]), buildKeepAwake(), buildLeaked(),
            section("Activity", [activity]),
        ]
        for view in sections { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = RemoteAccessFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor),
        ])
        // As wide as the scroll view; wider only when the column doesn't fit, which scrolls sideways then.
        let fill = document.widthAnchor.constraint(equalTo: clip.widthAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true
    }

    /// A section: its title, then its views.
    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        column([Self.title(title)] + views, spacing: 8)
    }

    private func buildSwitch() -> NSView {
        onSwitch.target = self
        onSwitch.action = #selector(switchFlipped)
        onSwitch.setAccessibilityLabel("Remote access")
        let name = NSTextField(labelWithString: "Remote access")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [onSwitch, name, statusLabel])
        top.alignment = .centerY
        top.spacing = 10
        switchNote.textColor = .systemOrange
        let intro = Self.note(Text.intro)
        for label in [switchNote, intro] { fit(label) }
        top.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
        return column([top, switchNote, intro])
    }

    private func buildTunnel() -> NSView {
        guideTitle.font = .systemFont(ofSize: 12, weight: .medium)
        for label in [lockedNote, guideTitle, guideWhy] { fit(label) }
        lockedNote.textColor = .systemOrange
        wire(useButton, #selector(useRecommended))
        wire(modeButton, #selector(modeClicked))
        needsStack.orientation = .vertical
        needsStack.alignment = .leading
        needsStack.spacing = 8
        choicesStack.orientation = .vertical
        choicesStack.alignment = .leading
        choicesStack.spacing = 6
        for kind in Kind.allCases {
            let radio = NSButton(radioButtonWithTitle: kind.label, target: self, action: #selector(choicePicked(_:)))
            radio.font = .systemFont(ofSize: 12, weight: .medium)
            choiceButtons[kind] = radio
            let traffic = Self.note(kind.traffic)
            fit(traffic, indent: 20)
            radio.setAccessibilityHelp(kind.traffic)
            let indented = NSStackView(views: [traffic])
            indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 4, right: 0)
            choicesStack.addArrangedSubview(column([radio, indented], spacing: 2))
        }
        return section("Tunnel", [lockedNote, guideTitle, guideWhy, useButton, needsStack, choicesStack, modeButton])
    }

    private func buildProvider() -> NSView {
        providerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        toolLabel.font = .systemFont(ofSize: 12)
        warningsLabel.font = .systemFont(ofSize: 11)
        warningsLabel.textColor = .systemOrange
        advancedWarning.font = .systemFont(ofSize: 11)
        advancedWarning.textColor = .systemOrange
        for label in [trafficLabel, warningsLabel, advancedWarning] { fit(label) }
        toolLabel.preferredMaxLayoutWidth = Self.contentWidth - 110
        toolLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wire(checkAgainButton, #selector(checkAgain))
        let toolRow = row([toolLabel, checkAgainButton])
        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = 6
        let views: [NSView] = [
            providerTitle, trafficLabel, toolRow, warningsLabel, stepsStack, buildToken(), buildHost(),
            buildServer(), buildAddress(), advancedWarning,
        ]
        for view in views { providerBox.addArrangedSubview(view) }
        providerBox.orientation = .vertical
        providerBox.alignment = .leading
        providerBox.spacing = 10
        return providerBox
    }

    private func buildToken() -> NSView {
        tokenField.placeholderString = "Paste the tunnel token"
        tokenField.setAccessibilityLabel("Cloudflare tunnel token")
        tokenField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        tokenField.target = self
        tokenField.action = #selector(saveToken)
        wire(saveTokenButton, #selector(saveToken))
        wire(removeTokenButton, #selector(removeToken))
        let label = NSTextField(labelWithString: "Tunnel token:")
        for view in [label, tokenField, saveTokenButton] { tokenRow.addArrangedSubview(view) }
        tokenRow.alignment = .firstBaseline
        tokenRow.spacing = 8
        tunnelIDLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tunnelIDLabel.isSelectable = true
        for view in [NSTextField(labelWithString: "Saved:"), tunnelIDLabel, removeTokenButton] {
            tokenSavedRow.addArrangedSubview(view)
        }
        tokenSavedRow.alignment = .firstBaseline
        tokenSavedRow.spacing = 8
        tokenMessage.font = .systemFont(ofSize: 11)
        fit(tokenMessage)
        checklistLabel.font = .systemFont(ofSize: 11)
        checklistLabel.textColor = .secondaryLabelColor
        fit(checklistLabel)
        let checks = Self.note("In the Cloudflare dashboard, check:")
        return column([tokenRow, tokenSavedRow, tokenMessage, checks, checklistLabel], spacing: 6)
    }

    private func buildHost() -> NSView {
        hostLabel.font = .systemFont(ofSize: 12)
        hostLabel.isSelectable = true
        fit(hostLabel)
        confirmLabel.font = .systemFont(ofSize: 12, weight: .medium)
        confirmLabel.preferredMaxLayoutWidth = Self.contentWidth - 170
        confirmLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wire(confirmButton, #selector(confirmHost))
        wire(declineButton, #selector(declineHost))
        confirmButton.keyEquivalent = ""
        for view in [confirmLabel, confirmButton, declineButton] { confirmRow.addArrangedSubview(view) }
        confirmRow.alignment = .firstBaseline
        confirmRow.spacing = 8
        hostField.placeholderString = "mcp.example.com"
        hostField.setAccessibilityLabel("Public hostname")
        hostField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        hostField.target = self
        hostField.action = #selector(saveHost)
        wire(saveHostButton, #selector(saveHost))
        let label = NSTextField(labelWithString: "Public hostname:")
        for view in [label, hostField, saveHostButton] { hostRow.addArrangedSubview(view) }
        hostRow.alignment = .firstBaseline
        hostRow.spacing = 8
        hostMessage.font = .systemFont(ofSize: 11)
        fit(hostMessage)
        return column([hostLabel, confirmRow, hostRow, hostMessage], spacing: 6)
    }

    private func buildServer() -> NSView {
        serverPopup.target = self
        serverPopup.action = #selector(serverPicked)
        serverPopup.setAccessibilityLabel("Your server")
        serverPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let serverRow = row([NSTextField(labelWithString: "Server:"), serverPopup])
        serverPortLabel.font = .systemFont(ofSize: 12)
        wire(newServerPortButton, #selector(newServerPort))
        newServerPortButton.toolTip = "Another port on the server, for when something there holds this one. Set up "
            + "Caddy again afterwards, so its site uses the new port."
        let portRow = row([serverPortLabel, newServerPortButton])
        caddyfileLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        caddyfileLabel.isSelectable = true
        fit(caddyfileLabel)
        wire(caddyButton, #selector(setUpCaddy))
        fit(caddyMessage)
        let caddyNote = Self.note("Caddy on your server serves https for the hostname and passes each request to "
            + "the forward. Next Term shows the commands first, and types them in a tab only after you confirm.")
        fit(caddyNote)
        for view in [serverRow, portRow, caddyNote, caddyfileLabel, caddyButton, caddyMessage] {
            serverBox.addArrangedSubview(view)
        }
        serverBox.orientation = .vertical
        serverBox.alignment = .leading
        serverBox.spacing = 6
        return serverBox
    }

    private func buildAddress() -> NSView {
        addressLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addressLabel.isSelectable = true
        wire(copyAddressButton, #selector(copyAddress))
        copyAddressButton.controlSize = .small
        let label = NSTextField(labelWithString: "Local address:")
        for view in [label, addressLabel, copyAddressButton] { addressRow.addArrangedSubview(view) }
        addressRow.alignment = .firstBaseline
        addressRow.spacing = 8
        return addressRow
    }

    private func buildStatus() -> NSView {
        statusLine.font = .systemFont(ofSize: 13, weight: .medium)
        fit(statusLine)
        fit(testResult)
        wire(keychainButton, #selector(allowKeychain))
        wire(dismissButton, #selector(dismissStatus))
        wire(otherHostButton, #selector(useOtherHost))
        wire(testButton, #selector(testConnection))
        wire(outputButton, #selector(toggleOutput))
        let buttons = row([keychainButton, otherHostButton, dismissButton, testButton])
        outputLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        outputLabel.textColor = .secondaryLabelColor
        outputLabel.isSelectable = true
        outputLabel.isHidden = true
        fit(outputLabel)
        return section("Status", [statusLine, buttons, testResult, outputButton, outputLabel])
    }

    private func buildConnect() -> NSView {
        wire(connectButton, #selector(connectClient))
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countdownLabel.textColor = .secondaryLabelColor
        let top = row([connectButton, countdownLabel])
        connectorLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        connectorLabel.isSelectable = true
        wire(copyConnectorButton, #selector(copyConnector))
        copyConnectorButton.controlSize = .small
        let label = NSTextField(labelWithString: "Connector URL:")
        for view in [label, connectorLabel, copyConnectorButton] { connectorRow.addArrangedSubview(view) }
        connectorRow.alignment = .firstBaseline
        connectorRow.spacing = 8
        fit(connectNote)
        leakNotice.font = .systemFont(ofSize: 12)
        fit(leakNotice, indent: 26)
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        mark.contentTintColor = .systemOrange
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let notice = NSStackView(views: [mark, leakNotice])
        notice.alignment = .top
        notice.spacing = 6
        return section("Connect a Client", [top, connectorRow, connectNote, notice])
    }

    private func buildKeepAwake() -> NSView {
        keepAwake.target = self
        keepAwake.action = #selector(keepAwakeChanged)
        let note = Self.note(Text.lidNote)
        fit(note)
        keepAwake.setAccessibilityHelp(Text.lidNote)
        return section("Sleep", [keepAwake, note])
    }

    private func buildLeaked() -> NSView {
        leakedBox.orientation = .vertical
        leakedBox.alignment = .leading
        leakedBox.spacing = 4
        leakedBox.addArrangedSubview(Self.title(Text.leakedTokenTitle))
        for (index, step) in Text.leakedTokenSteps.enumerated() {
            let line = Self.note("\(index + 1). \(step)")
            fit(line)
            leakedBox.addArrangedSubview(line)
        }
        return leakedBox
    }
}

// MARK: - showing

extension RemoteAccessSettingsView {
    /// Everything, from Remote access as it is now. A change it makes itself (the port or the server port picked
    /// and saved the first time they show) reads everything again once this pass is done.
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() {
        let tunnel = RemoteAccess.shared.settings.tunnel
        // Only the guide and the Cloudflare panel need it: a read that never asks, once a pass.
        tunnelID = tunnel == nil || tunnel == .cloudflare ? RemoteAccess.shared.savedTunnelID : nil
        let facts = currentFacts()
        refreshSwitch()
        refreshTunnel(facts)
        refreshProvider(facts)
        refreshStatus()
        refreshConnect()
        refreshConnections()
        let access = RemoteAccess.shared
        keepAwake.state = access.settings.keepAwakeOnBattery ? .on : .off
        leakedBox.isHidden = access.settings.tunnel != .cloudflare
    }

    /// The tunnel the guide recommends now, saved choice or not (U12 reads it).
    var recommendation: Kind? {
        var facts = currentFacts()
        facts.tokenSaved = RemoteAccess.shared.savedTunnelID != nil
        return Guide.recommendation(facts)
    }

    /// What the guide decides with.
    func currentFacts() -> Guide.Facts {
        let access = RemoteAccess.shared
        var facts = Guide.Facts()
        if let detection {
            facts.tailscale = detection.tailscale == nil ? .missing : .installed
            facts.tailscaleStatus = detection.tailscaleStatus
            if let found = detection.cloudflared { facts.cloudflared = found.tooOld ? .tooOld : .installed }
        }
        facts.tokenSaved = tunnelID != nil
        let hosts = RemoteHosts.all
        facts.servers = hosts.count
        facts.serverChosen = hosts.contains { $0.id == access.settings.server }
        facts.host = access.settings.host
        facts.caddyTyped = caddyTyped
        facts.on = access.status.phase == .on
        return facts
    }

    private func refreshSwitch() {
        let access = RemoteAccess.shared
        let agentControl = AppDelegate.shared?.agentControl ?? false
        onSwitch.state = access.isOn ? .on : .off
        // Off stays a click away whatever happens; on needs agent control (R1).
        onSwitch.isEnabled = agentControl || access.isOn
        switchNote.stringValue = agentControl ? "" : Text.agentControlOff
        switchNote.isHidden = agentControl
        statusLabel.stringValue = RemoteAccessIndicator(access.status.phase).word
    }

    private func refreshTunnel(_ facts: Guide.Facts) {
        let access = RemoteAccess.shared
        let locked = access.isOn
        let saved = access.settings.tunnel
        lockedNote.isHidden = !locked
        modeButton.title = showsAll ? Text.showGuided : Text.showAllOptions
        choicesStack.isHidden = !showsAll
        for (kind, radio) in choiceButtons {
            radio.state = kind == saved ? .on : .off
            radio.isEnabled = !locked
        }
        useButton.isHidden = true
        needsStack.isHidden = true
        guideWhy.isHidden = false
        if showsAll {
            guideTitle.stringValue = "Pick the tunnel that carries the door to the internet."
            guideWhy.isHidden = true
            return
        }
        if let saved {
            guideTitle.stringValue = "Tunnel: \(saved.label)"
            guideWhy.stringValue = saved.traffic
            return
        }
        guard detection != nil else {
            guideTitle.stringValue = "Looking for Tailscale and cloudflared…"
            guideWhy.isHidden = true
            return
        }
        if let recommended = Guide.recommendation(facts) {
            guideTitle.stringValue = "Recommended: \(recommended.label)"
            guideWhy.stringValue = Guide.why(recommended) + " " + recommended.traffic
            useButton.title = "Use \(recommended.label)"
            useButton.isHidden = false
            useButton.isEnabled = !locked
            return
        }
        guideTitle.stringValue = "Nothing is ready on this Mac yet. Each choice needs:"
        guideWhy.isHidden = true
        showNeeds(Guide.choices(facts), locked: locked)
    }

    /// With none ready: all four, each with what it needs and a button that picks it to set it up.
    private func showNeeds(_ choices: [Guide.Choice], locked: Bool) {
        for view in needsStack.arrangedSubviews { view.removeFromSuperview() }
        for (index, choice) in choices.enumerated() {
            let name = NSTextField(labelWithString: choice.kind.label)
            name.font = .systemFont(ofSize: 12, weight: .medium)
            let setUp = NSButton(title: "Set Up", target: self, action: #selector(setUpChoice(_:)))
            setUp.tag = index
            setUp.bezelStyle = .rounded
            setUp.controlSize = .small
            setUp.isEnabled = !locked
            setUp.setAccessibilityLabel("Set up \(choice.kind.label)")
            let needs = Self.note(choice.needs ?? Guide.why(choice.kind))
            fit(needs, indent: 12)
            let indented = NSStackView(views: [needs])
            indented.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
            needsStack.addArrangedSubview(column([row([name, setUp]), indented], spacing: 2))
        }
        needsStack.isHidden = false
    }

    private func refreshProvider(_ facts: Guide.Facts) {
        let access = RemoteAccess.shared
        guard let kind = access.settings.tunnel else {
            providerBox.isHidden = true
            return
        }
        providerBox.isHidden = false
        let locked = access.isOn
        // Cloudflare's route and your own tunnel are pointed at the door's port by hand, so it is picked as their
        // setup shows. Funnel and your own server get it at the first turn-on (R2): Next Term points them itself.
        let pointedByHand = kind == .cloudflare || kind == .advanced
        let port = (pointedByHand ? access.ensurePort() : access.settings.port).map(Int.init)
        providerTitle.stringValue = "\(kind.label) setup"
        trafficLabel.stringValue = kind.traffic
        refreshTool(kind)
        showSteps(Guide.steps(kind, facts, port: port))
        refreshToken(kind, locked: locked, port: port)
        refreshHost(kind, locked: locked)
        refreshServer(kind, locked: locked)
        addressRow.isHidden = port == nil
        addressLabel.stringValue = port.map { Config.doorAddress(port: $0) } ?? ""
        advancedWarning.isHidden = kind != .advanced
    }

    private func refreshTool(_ kind: Kind) {
        var warnings = detection?.warnings ?? []
        warnings += (RemoteAccess.shared.tunnel as? RemoteAccessTunnel)?.warnings ?? []
        warningsLabel.stringValue = warnings.joined(separator: "\n")
        warningsLabel.isHidden = warnings.isEmpty
        let tool: Config.Tool?
        switch kind {
        case .funnel: tool = .tailscale
        case .cloudflare: tool = .cloudflared
        case .ownServer, .advanced: tool = nil
        }
        toolLabel.superview?.isHidden = tool == nil
        guard let tool else { return }
        guard let detection else {
            toolLabel.stringValue = "Looking for \(tool.rawValue)…"
            toolLabel.textColor = .secondaryLabelColor
            return
        }
        let found = tool == .tailscale ? detection.tailscale : detection.cloudflared
        guard let found else {
            toolLabel.stringValue = tool.missing
            toolLabel.textColor = .systemOrange
            return
        }
        let version = found.version.map { " \($0)" } ?? ""
        let name = tool == .tailscale ? "Tailscale" : "cloudflared"
        var text = "\(name)\(version) at \(found.path)"
        if found.tooOld { text += ". " + Config.updateCloudflared }
        toolLabel.stringValue = text
        toolLabel.textColor = found.tooOld ? .systemOrange : .labelColor
    }

    /// The setup's steps: the done ones checked, the one to do now with what to do, the rest to come.
    private func showSteps(_ steps: [Guide.Step]) {
        for view in stepsStack.arrangedSubviews { view.removeFromSuperview() }
        let current = Guide.current(steps)
        for (index, step) in steps.enumerated() {
            let now = index == current
            let symbol = step.done ? "checkmark.circle.fill" : now ? "arrow.right.circle.fill" : "circle"
            let mark = NSImageView()
            mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: step.done ? "Done" : nil)
            mark.contentTintColor = step.done ? .systemGreen : now ? .controlAccentColor : .tertiaryLabelColor
            let title = NSTextField(labelWithString: "\(index + 1). \(step.title)")
            title.font = .systemFont(ofSize: 12, weight: now ? .semibold : .regular)
            title.textColor = step.done || now ? .labelColor : .secondaryLabelColor
            let line = NSStackView(views: [mark, title])
            line.alignment = .centerY
            line.spacing = 6
            stepsStack.addArrangedSubview(line)
            guard now else { continue }
            let detail = Self.note(step.detail)
            fit(detail, indent: 24)
            let indented = NSStackView(views: [detail])
            indented.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 2, right: 0)
            stepsStack.addArrangedSubview(indented)
        }
    }

    private func refreshToken(_ kind: Kind, locked: Bool, port: Int?) {
        let cloudflare = kind == .cloudflare
        let saved = cloudflare ? tunnelID : nil
        tokenRow.superview?.isHidden = !cloudflare
        tokenRow.isHidden = saved != nil
        tokenSavedRow.isHidden = saved == nil
        tunnelIDLabel.stringValue = saved ?? ""
        tokenField.isEnabled = !locked && !tokenBusy
        saveTokenButton.isEnabled = !locked && !tokenBusy
        removeTokenButton.isEnabled = !locked && !tokenBusy
        tokenMessage.isHidden = tokenMessage.stringValue.isEmpty
        checklistLabel.stringValue = Text.cloudflareChecklist(port: port).map { "• \($0)" }
            .joined(separator: "\n")
    }

    private func refreshHost(_ kind: Kind, locked: Bool) {
        let access = RemoteAccess.shared
        let saved = access.settings.host
        let typed = kind == .ownServer || kind == .advanced
        hostRow.isHidden = !typed
        hostLabel.isHidden = typed
        if !typed {
            let shown = saved ?? "set when the tunnel is first ready"
            hostLabel.stringValue = "Public hostname: \(shown)"
        } else if hostField.currentEditor() == nil {
            hostField.stringValue = saved ?? ""
        }
        hostField.isEnabled = !locked
        saveHostButton.isEnabled = !locked
        if case .confirmHost(let shown) = access.status.phase {
            confirmLabel.stringValue = "The tunnel serves \(shown). Use it as the public hostname?"
            confirmRow.isHidden = false
        } else {
            confirmRow.isHidden = true
        }
        if hostMessage.stringValue.isEmpty, saved != nil, typed {
            hostMessage.stringValue = Text.hostChangeEnds
            hostMessage.textColor = .secondaryLabelColor
        }
        hostMessage.isHidden = !typed || hostMessage.stringValue.isEmpty
    }

    private func refreshServer(_ kind: Kind, locked: Bool) {
        serverBox.isHidden = kind != .ownServer
        guard kind == .ownServer else { return }
        let access = RemoteAccess.shared
        let hosts = RemoteHosts.all
        let first = hosts.isEmpty ? "No servers yet: File › New Remote Tab…" : "Choose a server…"
        let titles = [first] + hosts.map { "\($0.name) (\($0.destination))" }
        // Built again only when the servers changed, so a refresh never pulls an open menu from under the user.
        let ids: [String?] = [nil] + hosts.map(\.id)
        let shownIDs = serverPopup.itemArray.map { $0.representedObject as? String }
        if serverPopup.itemTitles != titles || shownIDs != ids {
            // Through the menu, which keeps two items of the same title (the popup's own add drops one).
            serverPopup.removeAllItems()
            for (title, id) in zip(titles, ids) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = id
                serverPopup.menu?.addItem(item)
            }
        }
        let chosen = hosts.firstIndex { $0.id == access.settings.server }
        serverPopup.selectItem(at: chosen.map { $0 + 1 } ?? 0)
        serverPopup.isEnabled = !locked && !hosts.isEmpty
        let server = chosen.map { hosts[$0] }
        let port = server.map { access.serverPort(for: $0) }
        serverPortLabel.stringValue = port.map { "Port on the server: 127.0.0.1:\($0)" } ?? ""
        serverPortLabel.superview?.isHidden = server == nil
        newServerPortButton.isEnabled = !locked
        let caddyfile = access.settings.host.flatMap { host in
            port.map { Config.caddyfile(hostname: host, serverPort: $0) }
        }
        caddyfileLabel.stringValue = caddyfile ?? ""
        caddyfileLabel.isHidden = caddyfile == nil
        caddyButton.title = server.map { "Set Up Caddy on \($0.name)…" } ?? "Set Up Caddy…"
        caddyButton.isEnabled = caddyfile != nil
        caddyMessage.isHidden = caddyMessage.stringValue.isEmpty
    }

    private func refreshStatus() {
        let access = RemoteAccess.shared
        let status = access.status
        statusLine.stringValue = status.text
        statusLine.textColor = Self.statusColor(status)
        keychainButton.isHidden = status.phase != .waitingForKeychain
        keychainButton.isEnabled = !status.askingKeychain
        switch status.phase {
        case .portBusy, .stopped: dismissButton.isHidden = false
        default: dismissButton.isHidden = true
        }
        if let other = status.otherHost {
            otherHostButton.title = Text.useOtherHost(other)
            otherHostButton.isHidden = false
        } else {
            otherHostButton.isHidden = true
        }
        testButton.isEnabled = status.doorOpen && status.host != nil && !testing
        testResult.isHidden = testResult.stringValue.isEmpty
        let lines = (access.tunnel as? RemoteAccessTunnel)?.output.lines ?? []
        outputButton.isHidden = lines.isEmpty
        outputLabel.stringValue = lines.joined(separator: "\n")
        if lines.isEmpty { outputLabel.isHidden = true }
    }

    private static func statusColor(_ status: RemoteAccessStatus) -> NSColor {
        switch status.phase {
        case .on: return .systemGreen
        case .portBusy, .stopped: return .systemRed
        case .off: return status.problem == nil ? .secondaryLabelColor : .systemRed
        default: return .labelColor
        }
    }

    private func refreshConnect() {
        let access = RemoteAccess.shared
        let host = access.doorState?.host
        connectButton.isEnabled = host != nil
        connectNote.isHidden = host != nil
        connectorRow.isHidden = host == nil
        connectorLabel.stringValue = host.map(Text.connectorURL) ?? ""
        refreshCountdown()
    }

    private func refreshCountdown() {
        guard let pairing = RemoteAccessPairingWindow.current, pairing.state === RemoteAccess.shared.doorState else {
            countdownLabel.stringValue = ""
            return
        }
        let left = Int(pairing.ends.timeIntervalSince(pairing.state.now).rounded(.up))
        countdownLabel.stringValue = left > 0 ? Text.pairingCountdown(seconds: left) : ""
    }

    func refreshConnections() {
        connections.show(RemoteAccess.shared.connectionRows())
    }
}

// MARK: - actions

extension RemoteAccessSettingsView {
    @objc func switchFlipped() {
        let access = RemoteAccess.shared
        if onSwitch.state == .on {
            access.turnOn()
        } else {
            access.turnOff()
        }
        refresh()
    }

    /// Picks a tunnel: it applies at the next start.
    func choose(_ kind: Kind) {
        guard !RemoteAccess.shared.isOn else { return }
        RemoteAccess.shared.change { $0.tunnel = kind }
        refresh()
    }

    @objc private func useRecommended() {
        guard let kind = Guide.recommendation(currentFacts()) else { return }
        choose(kind)
    }

    @objc private func choicePicked(_ sender: NSButton) {
        guard let kind = choiceButtons.first(where: { $0.value === sender })?.key else { return }
        choose(kind)
    }

    @objc private func setUpChoice(_ sender: NSButton) {
        let kinds = Kind.allCases
        guard kinds.indices.contains(sender.tag) else { return }
        choose(kinds[sender.tag])
    }

    /// "Show all options", or back to the guide.
    @objc func modeClicked() {
        showsAll.toggle()
        refresh()
    }

    @objc private func checkAgain() {
        detect()
    }

    /// The pasted token, checked for shape: a bad one is cleared and never saved; a good one goes to the Keychain,
    /// and the field is cleared either way, so the token never stays on screen.
    @objc func saveToken() {
        let pasted = tokenField.stringValue
        tokenField.stringValue = ""
        guard !pasted.isEmpty, !tokenBusy else { return }
        tokenBusy = true
        refresh()
        RemoteAccess.shared.saveToken(pasted) { [weak self] problem in
            guard let self else { return }
            self.tokenBusy = false
            self.tokenMessage.stringValue = problem ?? "Saved in your Keychain."
            self.tokenMessage.textColor = problem == nil ? .secondaryLabelColor : .systemRed
            self.refresh()
        }
    }

    @objc private func removeToken() {
        guard !tokenBusy else { return }
        tokenBusy = true
        refresh()
        RemoteAccess.shared.removeToken { [weak self] problem in
            guard let self else { return }
            self.tokenBusy = false
            self.tokenMessage.stringValue = problem ?? "Removed from your Keychain."
            self.tokenMessage.textColor = problem == nil ? .secondaryLabelColor : .systemRed
            self.refresh()
        }
    }

    /// A typed hostname (your own server, Advanced): checked, then saved for the next start.
    @objc func saveHost() {
        let access = RemoteAccess.shared
        switch Config.publicHostname(hostField.stringValue) {
        case .failure(let error):
            hostMessage.stringValue = error.message
            hostMessage.textColor = .systemRed
        case .success(let name):
            hostField.stringValue = name
            let changing = access.settings.host != nil && access.settings.host != name
            access.change { $0.host = name }
            hostMessage.stringValue = changing ? "Saved. " + Text.hostChangeEnds : "Saved."
            hostMessage.textColor = .secondaryLabelColor
        }
        refresh()
    }

    @objc private func confirmHost() {
        guard case .confirmHost(let shown) = RemoteAccess.shared.status.phase else { return }
        RemoteAccess.shared.confirmHost(shown)
    }

    @objc private func declineHost() {
        RemoteAccess.shared.declineHost()
    }

    @objc private func serverPicked() {
        let id = serverPopup.selectedItem?.representedObject as? String
        RemoteAccess.shared.change { $0.server = id }
        refresh()
    }

    @objc private func newServerPort() {
        let access = RemoteAccess.shared
        guard let id = access.settings.server, let host = RemoteHosts.all.first(where: { $0.id == id }) else { return }
        access.newServerPort(for: host)
        caddyMessage.stringValue = "Set up Caddy again, so the server's site uses the new port."
        refresh()
    }

    @objc private func setUpCaddy() {
        caddyMessage.stringValue = ""
        RemoteAccess.shared.setUpCaddy(window: window) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .canceled:
                self.caddyMessage.stringValue = ""
            case .typed:
                self.caddyTyped = true
                self.caddyMessage.stringValue = "Typed in a tab on the server. Check how it went there."
            case .notTyped(let reason):
                self.caddyMessage.stringValue = reason
            }
            self.refresh()
        }
    }

    @objc private func copyAddress() {
        copy(addressLabel.stringValue)
    }

    @objc private func allowKeychain() {
        RemoteAccess.shared.allowKeychainAccess()
    }

    @objc private func dismissStatus() {
        RemoteAccess.shared.dismiss()
    }

    @objc private func useOtherHost() {
        RemoteAccess.shared.useOtherHost()
    }

    /// Test Connection, only on this click (R36).
    @objc func testConnection() {
        let status = RemoteAccess.shared.status
        guard let kind = status.tunnel, let host = status.host, !testing else { return }
        testing = true
        testResult.stringValue = "Testing https://\(host)…"
        refresh()
        RemoteAccessTunnel.testConnection(kind: kind, host: host) { [weak self] message in
            guard let self else { return }
            self.testing = false
            self.testResult.stringValue = message
            self.refresh()
        }
    }

    @objc private func toggleOutput() {
        outputLabel.isHidden.toggle()
        outputButton.title = outputLabel.isHidden ? "Show Tunnel Output" : "Hide Tunnel Output"
    }

    /// Connect a Client: the pairing window, and pairing open for 10 minutes (U8).
    @objc func connectClient() {
        guard let state = RemoteAccess.shared.doorState else { return }
        RemoteAccessPairingWindow.open(state: state)
        refreshCountdown()
    }

    @objc private func copyConnector() {
        copy(connectorLabel.stringValue)
    }

    @objc private func keepAwakeChanged() {
        let on = keepAwake.state == .on
        RemoteAccess.shared.change { $0.keepAwakeOnBattery = on }
    }
}

/// A document view that lays out from the top, as a page reads.
private final class RemoteAccessFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - the controller's entries for Settings and the status item (U11)

extension RemoteAccess {
    static let notSaved = "The connection ended, but Next Term could not save that yet. It tries again, and at quit; "
        + "until it can, the connection would work again after Next Term restarts."
    static let allNotSaved = "Every connection ended, but Next Term could not save that yet. It tries again, and at "
        + "quit; until it can, they would work again after Next Term restarts."
    static let connectionEnded = "That connection ended, so there is nothing to change."

    /// The connections as they are now: the open door's, or, with the door closed, the grants file's under the
    /// saved hostname, or the last state's when their save failed. The file is only read, never moved aside or
    /// written, so looking changes nothing.
    func connectionRows(now: Date = Date()) -> [RemoteAccessConnectionRow] {
        if let doorState { return RemoteAccessConnectionRow.rows(doorState.grants, host: doorState.host, now: now) }
        let grants = carried?.unsaved?.grants ?? savedGrants()
        return RemoteAccessConnectionRow.rows(grants, host: settings.host, now: now)
    }

    private func savedGrants() -> [RemoteAccessOAuth.Grant] {
        let url = RemoteAccessGrantStore(folder: folder).url
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? RemoteAccessGrantFile.decoded(data))?.grants ?? []
    }

    /// A connection's options now, or nil when it has ended.
    func connectionOptions(_ grantID: String) -> RemoteAccessOptions? {
        connectionRows().first { $0.id == grantID }?.options
    }

    /// What the status item shows: the calls of the last hour, across starts too.
    func statusItemModel() -> RemoteAccessStatusItemModel {
        let rows = status.isOn ? connectionRows() : []
        let calls = doorState?.callsInLastHour ?? carried?.callCount.count(at: Date()) ?? 0
        return RemoteAccessStatusItemModel(status: status, rows: rows, calls: calls)
    }

    /// The saved token's tunnel id, all Settings shows of it.
    var savedTunnelID: String? { tokens.tunnelID }

    /// Revoke, on a connection's row or in the status item: it ends now, and its open calls are answered (R38).
    /// With the door closed, the grants file's own ends. Why it could not be saved, or nil: it holds all the same
    /// while Next Term runs, and the save is tried again (`withClosedDoor`).
    @discardableResult
    func revoke(_ grantID: String) -> String? {
        defer { told() }
        do {
            if let doorState {
                try doorState.revoke(grant: grantID)
            } else {
                try withClosedDoor { try $0.revoke(grant: grantID) }
            }
            return nil
        } catch {
            return Self.notSaved
        }
    }

    /// Revoke All in Settings: every connection ends, Remote access stays as it is.
    @discardableResult
    func revokeAll() -> String? {
        defer { told() }
        do {
            if let doorState {
                try doorState.revokeAll()
            } else {
                try withClosedDoor { try $0.revokeAll() }
            }
            return nil
        } catch {
            return Self.allNotSaved
        }
    }

    /// Edit…'s Save, after Touch ID or the password (R60): the new options are saved, then apply from the
    /// connection's next call, and the audit log gets the old and new options. Why not, or nil.
    func changeOptions(of grantID: String, to options: RemoteAccessOptions) -> String? {
        guard connectionOptions(grantID) != nil else { return Self.connectionEnded }
        defer { told() }
        do {
            if let doorState {
                try doorState.changeOptions(of: grantID, to: options)
            } else {
                try withClosedDoor { try $0.changeOptions(of: grantID, to: options) }
            }
            return nil
        } catch {
            return "Next Term could not save the new options, so nothing changed. Try again."
        }
    }

    /// The pasted token: checked for shape first, so a bad one is never saved (R30); then written to the Keychain
    /// off the main thread, since macOS may ask about the item. `done` gets why not, or nil; the tunnel line in the
    /// audit log names only the tunnel id.
    func saveToken(_ pasted: String, done: @escaping @MainActor (String?) -> Void) {
        let token: RemoteAccessTunnelConfig.Token
        switch RemoteAccessTunnelConfig.token(pasted) {
        case .failure(let error): return done(error.message)
        case .success(let checked): token = checked
        }
        let tokens = self.tokens
        DispatchQueue.global(qos: .userInitiated).async {
            var problem: String?
            do {
                try tokens.save(token)
            } catch {
                problem = "Next Term could not keep the token in your Keychain: \(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if problem == nil { self.auditTunnel("token_saved", detail: token.description) }
                    self.told()
                    done(problem)
                }
            }
        }
    }

    /// Remove Token: off the main thread too.
    func removeToken(done: @escaping @MainActor (String?) -> Void) {
        let tokens = self.tokens
        DispatchQueue.global(qos: .userInitiated).async {
            var problem: String?
            do {
                try tokens.remove()
            } catch {
                problem = "Next Term could not remove the token from your Keychain: \(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if problem == nil { self.auditTunnel("token_removed", detail: nil) }
                    self.told()
                    done(problem)
                }
            }
        }
    }

    /// The door's port, for the local address before the first turn-on of a tunnel the user points at it by hand
    /// (Cloudflare's route, Advanced): the saved one, or one picked now from 40000 to 48999 and saved, as the first
    /// turn-on would pick it (R2), so the tunnel can be pointed at it before Remote access is on. It never changes
    /// by itself after that. Nil when none is free.
    func ensurePort() -> UInt16? {
        if let port = settings.port { return port }
        guard let choice = RemoteAccessPort.choose(saved: nil, isFree: Self.isFree) else { return nil }
        change { $0.port = choice.port }
        return choice.port
    }

    /// "Use <host> (ends every connection)": the hostname the tunnel serves now is saved, and Remote access starts
    /// again with it. The grants of the old one end as the door opens (KTD17).
    func useOtherHost() {
        guard let other = status.otherHost else { return }
        change { $0.host = other }
        turnOn()
    }

    /// The audit log's file, for Show in Finder.
    var auditFile: URL { folder.appendingPathComponent(RemoteAccessAuditRetention.fileName(0)) }

    /// The activity view's read: the last 500 entries, oldest first, on the audit queue, after the open door's
    /// lines or the closed door's. `done` gets them on the main thread.
    func readActivity(done: @escaping @MainActor ([RemoteAccessAuditEntry]) -> Void) {
        let deliver: @Sendable ([RemoteAccessAuditEntry]) -> Void = { entries in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(entries) } }
        }
        if let doorState { return doorState.readAudit(done: deliver) }
        let closedLog = self.closedLog
        Self.auditQueue.async {
            deliver(closedLog.log.tail(now: Date()))
        }
    }

    /// Clear Log: every audit file goes. `done` gets why not, or nil, on the main thread.
    func clearActivity(done: @escaping @MainActor (String?) -> Void) {
        let deliver: @Sendable (Error?) -> Void = { error in
            let problem = error.map { "Next Term could not clear the log: \($0)" }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(problem) } }
        }
        if let doorState { return doorState.clearAudit(done: deliver) }
        let closedLog = self.closedLog
        Self.auditQueue.async {
            do {
                try closedLog.log.clear()
                deliver(nil)
            } catch {
                deliver(error)
            }
        }
    }

    /// Settings and the status item read again.
    private func told() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
