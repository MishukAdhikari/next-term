import AppKit
import NextTermCore

/// An agent's import_secrets request, from its turn in `SecretRequests`' queue to its answer: Window › Secrets comes
/// forward with Import from a File's sheet for the file, or a password manager's sheet for a source, each with a banner
/// naming who asks, from where, and the agent's reason. The import itself is the sheet's own: the user ticks, a key
/// they have is replaced only by a tick of theirs, and one Touch ID copies the keys in. The agent hears names and counts
/// only (`SecretSources.answer(for:)`).
///
/// For a source, Open in a New Tab ends the sheet but not the request: it waits, out of the panel's turn, for the keys
/// that tab's line pipes into `nxtrm secret import`, whose sheet shows the banner too and answers. A request whose tab
/// never pipes ends after the queue's 30 minutes, unanswered.
@MainActor
final class SecretImportAsk {
    enum Target {
        case file(String)
        case source(SecretImportPreset)

        /// The file's path, or the source's name, as the request's binding and audit line name it.
        var text: String {
            switch self {
            case .file(let path): return path
            case .source(let preset): return preset.rawValue
            }
        }

        /// As the banner names it: the path from `~`, or the app.
        func shown(home: String) -> String {
            switch self {
            case .file(let path): return SecretSources.shownPath(path, home: home)
            case .source(let preset): return preset.app
            }
        }
    }

    /// How the request ended, as the agent hears it.
    enum End {
        case outcome(SecretSources.CopyInOutcome)
        case declined
        /// Secrets shows another sheet: the import window couldn't open.
        case busy
        case refused(String)

        /// The answer, for every end but a decline (the queue's own decline answers that).
        var answer: [String: Any] {
            switch self {
            case .outcome(let outcome): return SecretSources.answer(for: outcome)
            case .declined: return SecretSources.answer(for: .declined)
            case .busy: return ["status": "busy", "note": SecretImportAsk.busyNote]
            case .refused(let note): return ["status": "refused", "note": note]
            }
        }
    }

    nonisolated static let busyNote = "Secrets has another window open on the Mac. Try again once the user has closed it."
    static let busyLine = "An agent asked to import keys. Finish what\u{2019}s open here; it can ask again."

    let target: Target
    /// "Claude Code in shop-web asks to import keys from ~/Code/shop-web/.env.local: Move the app's keys out of …".
    let banner: String
    /// The request's Asked by facts in one line (`SecretRequests.who`), for the banner and the copy-in's audit line.
    let askedBy: String
    /// The audit line's command: the tool, what it names, and the agent's reason.
    let command: String
    private(set) var wasOpened = false
    private(set) var hasEnded = false
    /// The tab Open in a New Tab made for a source, whose pipe this request waits for.
    private(set) var tabID: UUID?
    private var ended: ((End) -> Void)?
    private var leftScreen: (() -> Void)?
    /// The sheets showing it, closed when the queue ends it first.
    private weak var fileSheet: SecretFileImportSheet?
    private weak var managerSheet: SecretManagerImportSheet?

    /// The requests waiting for their tab's pipe, by that tab's id.
    private(set) static var waiting: [UUID: SecretImportAsk] = [:]

    init(target: Target, banner: String, askedBy: String, command: String) {
        self.target = target
        self.banner = banner
        self.askedBy = askedBy
        self.command = command
    }

    /// A sheet of it is up, in the queue's turn.
    var isOnScreen: Bool { wasOpened && !hasEnded && tabID == nil }

    /// The request waiting on tab `id`'s pipe, if any.
    static func waiting(onTab id: UUID) -> SecretImportAsk? {
        guard let ask = waiting[id], !ask.hasEnded else { return nil }
        return ask
    }
}

// MARK: opening and ending

extension SecretImportAsk {
    /// Its turn in the queue: the sheet for its file or source. `ended` hears how it ended, once; `leftScreen` that a
    /// source's sheet went and the request now waits for its tab, so the queue can show the next.
    func open(ended: @escaping (End) -> Void, leftScreen: @escaping () -> Void) {
        guard !wasOpened else { return }
        wasOpened = true
        self.ended = ended
        self.leftScreen = leftScreen
        guard let view = secretsView() else { return }
        switch target {
        case .file(let path): openFile(path, in: view)
        case .source(let preset): openSource(preset, in: view)
        }
    }

    /// The request ended: the agent hears `end`, and nothing more after.
    func end(_ end: End) {
        guard !hasEnded else { return }
        hasEnded = true
        forgetTab()
        let told = ended
        ended = nil
        leftScreen = nil
        told?(end)
    }

    /// The queue ended it first (a pause, Start Over, its 30 minutes): its sheet closes, and nothing more is told.
    func close() {
        guard !hasEnded else { return }
        hasEnded = true
        ended = nil
        leftScreen = nil
        forgetTab()
        fileSheet?.closeSheet()
        managerSheet?.cancel()
    }

    private func forgetTab() {
        guard let id = tabID, Self.waiting[id] === self else { return }
        Self.waiting[id] = nil
    }

    /// Window › Secrets in front, with no sheet open on it; nil, and the request ended, when Secrets can't be opened on
    /// this Mac or shows another sheet. It never activates Next Term: when another app is in front, the Dock icon
    /// bounces, as request_secret's window does.
    private func secretsView() -> SecretsView? {
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered {
            end(.refused(SecretsMCP.cantOpenNote))
            return nil
        }
        if let open = SecretsWindowController.shared?.secretsView, open.hasOpenSheet {
            open.say(Self.busyLine)
            end(.busy)
            return nil
        }
        SecretsWindowController.show()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard let view = SecretsWindowController.shared?.secretsView else {
            end(.refused(SecretsMCP.cantOpenNote))
            return nil
        }
        return view
    }

    /// The file read off the main thread, its path checked again first (time passed in the queue), then Import from a
    /// File's sheet with the banner.
    private func openFile(_ path: String, in view: SecretsView) {
        let home: String = NSHomeDirectory()
        let vault: String = SecretsStore.shared.folder.url.path
        let stored: Set<String> = Set(SecretsStore.shared.index?.names ?? [])
        view.say("Reading \((path as NSString).lastPathComponent)\u{2026}")
        Task { @MainActor in
            let read = await Task.detached { () -> (checked: Result<String, SecretSources.PathRefusal>, report: SourceReport?, inGit: Bool) in
                let checked = SecretSources.checkPath(path, home: home, vaultFolder: vault)
                guard case .success(let real) = checked else { return (checked, nil, false) }
                let report: SourceReport = SecretSources.readFile(real, stored: stored)
                return (checked, report, SecretImport.isInGitWorkTree(real))
            }.value
            view.say("")
            guard !self.hasEnded else { return }
            switch read.checked {
            case .failure(let refusal): return self.end(.refused(refusal.note))
            case .success(let real):
                guard let report = read.report else { return self.end(.refused(SecretSources.PathRefusal.notFound.note)) }
                view.openFileImport(path: real, report: report, inGit: read.inGit, asked: self)
            }
        }
    }

    /// A password manager's sheet with the banner. Open in a New Tab leaves the request waiting for that tab's pipe;
    /// Cancel declines it.
    private func openSource(_ preset: SecretImportPreset, in view: SecretsView) {
        guard let window = view.window else { return end(.busy) }
        let sheet = SecretManagerImportSheet(preset: preset, say: { [weak view] (line: String) in
            view?.say(line)
        }, done: { [weak view, weak self] in
            view?.managerSheet = nil
            self?.sourceSheetWent()
        })
        sheet.opened = { [weak self] (tab: TerminalTab) in self?.waitFor(tab) }
        managerSheet = sheet
        view.managerSheet = sheet
        Self.addBanner(self, to: sheet.window)
        sheet.begin(on: window)
    }

    private func waitFor(_ tab: TerminalTab) {
        guard !hasEnded else { return }
        tabID = tab.id
        Self.waiting[tab.id] = self
    }

    /// The source's sheet went: with a tab opened, the request waits for its pipe out of the panel's turn; else the
    /// user cancelled it.
    private func sourceSheetWent() {
        managerSheet = nil
        guard !hasEnded else { return }
        guard tabID != nil else { return end(.declined) }
        leftScreen?()
    }

    /// The copy sheet for its file, or for its tab's piped keys, is up: it shows the banner and says how it ends.
    func showing(_ sheet: SecretFileImportSheet) {
        fileSheet = sheet
        Self.addBanner(self, to: sheet.window)
    }
}

// MARK: the banner

extension SecretImportAsk {
    /// The banner under a sheet's title: who asks, from where, and the agent's reason, then its Asked by facts. The
    /// agent's words are shown as its own and never become a key's purpose.
    static func addBanner(_ ask: SecretImportAsk, to window: NSWindow?) {
        guard let stack = window?.contentView?.subviews.first(where: { (view: NSView) -> Bool in view is NSStackView })
            as? NSStackView, !stack.arrangedSubviews.isEmpty else { return }
        let banner: NSView = bannerView(ask)
        stack.insertArrangedSubview(banner, at: 1)
        banner.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
    }

    static func bannerView(_ ask: SecretImportAsk) -> NSView {
        let said: String = SecretApprovalPanel.sanitized(ask.banner, limit: 700)
        let line = NSTextField(wrappingLabelWithString: said)
        line.font = .systemFont(ofSize: 12, weight: .semibold)
        line.setAccessibilityLabel("Request: " + said)
        let facts: String = "Asked by \(SecretApprovalPanel.sanitized(ask.askedBy, limit: 300))."
        let asked = NSTextField(wrappingLabelWithString: facts)
        asked.font = .systemFont(ofSize: 11)
        asked.textColor = .secondaryLabelColor
        let replace = NSTextField(wrappingLabelWithString: replaceLine)
        replace.font = .systemFont(ofSize: 11)
        replace.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [line, asked, replace])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        box.identifier = NSUserInterfaceItemIdentifier(bannerID)
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        for label in [line, asked, replace] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        return box
    }

    static let bannerID = "import-secrets-banner"
    static let replaceLine = "The agent learns only the names you import and counts. A key you already have is "
        + "replaced only if you tick its row."
}
