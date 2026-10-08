import AppKit
import NextTermCore

/// Tab completion's hook on servers (RemoteCompletionHook), host by host, only with the user's yes. Without it a
/// server tab lists folders and files over its connection and nothing is written there; with it, a zsh there
/// reports like a local one, and the list shows the server's own completions.
///
/// Per host (by its stable id): not allowed, allowed (with the host's nonce, made at Allow and kept here), or
/// removed on the server (someone deleted the files: Next Term never puts them back by itself). Kept outside the
/// saved hosts, so the hosts and the MCP host tools don't change, and dropped with its host: ids that are no
/// longer saved hosts are pruned whenever it is read. No MCP tool reads or changes it.
enum RemoteCompletionConsent {
    enum State: Equatable {
        case notAllowed
        case allowed
        case removedOnServer
    }

    private static let key = "remoteCompletionHooks"
    /// Allowed, removed or a check made: Settings and the New Remote Tab sheet show it.
    static let changed = Notification.Name("NextTermRemoteCompletionChanged")

    /// Saved state by host id: "allowed" or "removed", and the nonce.
    private static var stored: [String: [String: String]] {
        get {
            let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
            let saved = Set(RemoteHosts.all.map(\.id))
            let kept = all.filter { saved.contains($0.key) }
            if kept.count != all.count { UserDefaults.standard.set(kept, forKey: key) }
            return kept
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func state(_ host: RemoteHost) -> State {
        switch stored[host.id]?["state"] {
        case "allowed": return .allowed
        case "removed": return .removedOnServer
        default: return .notAllowed
        }
    }

    /// The host's nonce while its hook is allowed: marks from its shells must carry it.
    static func nonce(for host: RemoteHost) -> String? {
        guard let entry = stored[host.id], entry["state"] == "allowed", let nonce = entry["nonce"], !nonce.isEmpty else { return nil }
        return nonce
    }

    /// Saved hosts with the hook on, for Settings.
    static var allowedHosts: [RemoteHost] { RemoteHosts.all.filter { state($0) == .allowed } }

    /// A new tab on this host starts its shell through the hook (herdr has none).
    static func startsHooked(_ remote: RemoteTab) -> Bool {
        remote.keep != .herdr && state(remote.host) == .allowed
    }

    private static func set(_ host: RemoteHost, _ entry: [String: String]?) {
        var all = stored
        all[host.id] = entry
        stored = all
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: allow, remove, check

    /// The question on screen, for the self-test.
    nonisolated(unsafe) private(set) static var question: NSAlert?

    /// The question before anything is written, as a sheet over `window`; then the hook, over a tab's open
    /// connection (never a login of its own). `done` gets nil once it is on, or what to tell the user.
    static func allow(_ host: RemoteHost, over window: NSWindow, done: @escaping (String?) -> Void) {
        guard RemoteConnection.masterAlive(host) else { return done(noConnection(host, to: "write the hook")) }
        let alert = NSAlert()
        alert.messageText = "Allow Tab completion’s hook on “\(host.name)”?"
        alert.informativeText = """
            Next Term writes a few small files to ~/.cache/next-term/completion/ on \(host.name). With them, a zsh there \
            reports the line when you press Tab, so the list shows the server’s own completions: git branches and the rest. \
            The hook runs nothing by itself and changes none of your files; new tabs start your shell through it.

            It applies to new tabs. A kept session gets it when its shell restarts. Remove it here at any time: that \
            deletes the folder.
            """
        let allowButton = alert.addButton(withTitle: "Allow")
        allowButton.keyEquivalent = "" // a Return meant for the terminal allows nothing
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        question = alert
        alert.beginSheetModal(for: window) { response in
            question = nil
            guard response == .alertFirstButtonReturn else { return done("") }
            install(host, nonce: ShellIntegration.makeNonce(), done: done)
        }
    }

    /// Writes the hook with `nonce` (a new one at Allow and Turn On Again; the kept one for an update).
    static func install(_ host: RemoteHost, nonce: String, done: @escaping (String?) -> Void) {
        guard RemoteConnection.masterAlive(host) else { return done(noConnection(host, to: "write the hook")) }
        let input = Data((nonce + "\n").utf8)
        RemoteConnection.run(host, script: RemoteCompletionHook.installScript, input: input, timeout: 20) { output in
            switch RemoteCompletionHook.parse(output.output) {
            case .installed:
                set(host, ["state": "allowed", "nonce": nonce])
                done(nil)
            case .otherShell(let shell):
                let name = shell.isEmpty ? "not zsh" : shell
                done("The login shell on \(host.name) is \(name). The hook is for zsh; without it, Tab still lists the server’s folders and files.")
            case .failed(let why):
                done("The hook could not be written on \(host.name) (\(why)). Nothing was left there.")
            default:
                done("The hook could not be written on \(host.name): \(output.problem)")
            }
        }
    }

    /// Deletes the hook's folder on the server and takes the key off Next Term's tmux there; the nonce goes too.
    static func remove(_ host: RemoteHost, done: @escaping (String?) -> Void) {
        guard RemoteConnection.masterAlive(host) else { return done(noConnection(host, to: "remove the hook")) }
        RemoteConnection.run(host, script: RemoteCompletionHook.removeScript, timeout: 20) { output in
            if RemoteCompletionHook.parse(output.output) == .removed {
                set(host, nil)
                done(nil)
            } else {
                done("The hook could not be removed from \(host.name): \(output.problem)")
            }
        }
    }

    /// When each host was last checked.
    nonisolated(unsafe) private static var checked: [String: TimeInterval] = [:]

    /// Whether an allowed host still has its hook (once a minute at most, over a tab's connection): one deleted
    /// there is marked removed and never put back by Next Term; one from an older Next Term is brought up to date.
    static func verify(_ host: RemoteHost, force: Bool = false) {
        guard state(host) == .allowed, let nonce = nonce(for: host), RemoteConnection.masterAlive(host) else { return }
        let now = TerminalTab.now
        if !force, let last = checked[host.id], now - last < 60 { return }
        checked[host.id] = now
        RemoteConnection.run(host, script: RemoteCompletionHook.checkScript, timeout: 15) { output in
            guard state(host) == .allowed else { return }
            switch RemoteCompletionHook.parse(output.output) {
            case .missing:
                set(host, ["state": "removed"])
            case .present(let version) where version != RemoteCompletionHook.version:
                install(host, nonce: nonce) { _ in }
            default:
                break
            }
        }
    }

    private static func noConnection(_ host: RemoteHost, to action: String) -> String {
        "There is no open connection to \(host.name). Open a remote tab on it first: Next Term never logs in by itself to \(action)."
    }
}

extension TerminalTab {
    /// A completion mark from a server tab's hooked shell: only under its host's nonce, and only Tab completion's
    /// kinds (its status keeps coming from the status checks).
    func serverCompletionMark(_ payload: some Collection<UInt8>) -> ShellIntegration.Event? {
        guard let remote, let nonce = RemoteCompletionConsent.nonce(for: remote.host),
              case .completion(let message)? = ShellIntegration.parse(payload, nonce: nonce) else { return nil }
        return .completion(message)
    }
}

/// New Remote Tab's line for the selected host: what Tab completion does there, and Allow…, Remove or Turn On
/// Again.
final class RemoteCompletionRow: NSStackView {
    private let note = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var host: RemoteHost?
    private weak var sheet: NSWindow?
    private var working = false

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(act)
        addArrangedSubview(note)
        addArrangedSubview(button)
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: RemoteCompletionConsent.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The selected saved host (nil: a new one, not saved yet).
    func show(_ host: RemoteHost?, over sheet: NSWindow) {
        self.host = host
        self.sheet = sheet
        working = false
        if let host { RemoteCompletionConsent.verify(host, force: true) }
        refresh()
    }

    @objc func refresh() {
        guard let host else {
            note.stringValue = "Tab lists the server’s folders and files. Its own completions need a small hook there, which you can allow once the host is saved."
            button.isHidden = true
            return
        }
        button.isHidden = false
        button.isEnabled = !working
        switch RemoteCompletionConsent.state(host) {
        case .notAllowed:
            note.stringValue = "Tab lists the server’s folders and files; nothing is written there. Allow a small hook for zsh’s own completions on this server."
            button.title = "Allow…"
        case .allowed:
            note.stringValue = "On: zsh’s own completions, through the hook in ~/.cache/next-term/completion on this server."
            button.title = "Remove"
        case .removedOnServer:
            note.stringValue = "The hook was removed on the server. New tabs start without it; Next Term doesn’t put it back by itself."
            button.title = "Turn On Again"
        }
        button.setAccessibilityLabel("Tab completion on \(host.name): \(button.title)")
    }

    /// For the self-test.
    var text: String { note.stringValue }
    var buttonTitle: String { button.isHidden ? "" : button.title }
    func press() { act() }

    @objc private func act() {
        guard let host, let sheet, !working else { return }
        let finish: (String?) -> Void = { [weak self] message in
            self?.working = false
            self?.refresh()
            guard let message, !message.isEmpty else { return }
            self?.note.stringValue = message
        }
        switch RemoteCompletionConsent.state(host) {
        case .allowed:
            working = true
            refresh()
            RemoteCompletionConsent.remove(host, done: finish)
        case .notAllowed, .removedOnServer:
            RemoteCompletionConsent.allow(host, over: sheet, done: finish)
        }
    }
}
