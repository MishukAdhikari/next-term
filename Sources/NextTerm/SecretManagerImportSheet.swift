import AppKit
import NextTermCore

/// Import From › 1Password…, Bitwarden… and Bitwarden Secrets Manager…: says what will run, shows the line, links the
/// CLI's download page, and Open in a New Tab types that line into a new tab in the home folder with no Return. The user
/// reads it and presses Return; unlocking happens at the CLI's own prompt, and the keys go by pipe into
/// `nxtrm secret import`, never onto the screen. Next Term runs no CLI itself, installs nothing and probes nothing.
///
/// From the moment the line is typed until the tab closes, agents can't type into that tab, press its keys, answer in
/// it or close it (`MCPInputLine`): an agent could otherwise rewrite the line before the Return, press it, or use the
/// password manager's authorization for that terminal afterwards.
@MainActor
final class SecretManagerImportSheet: NSWindowController, NSWindowDelegate {
    static let openTitle = "Open in a New Tab"
    static let agentControlOff = "Turn on \u{201C}Let agents control Next Term\u{201D} first: the keys reach Next Term "
        + "through it."
    static let typedLine = "The line is in a new tab, not run. Read it there, then press Return."
    static let notTyped = "Next Term couldn\u{2019}t type the line in the new tab."

    /// The tabs a preset typed its line into, by id, with that preset: refused to agents until they close.
    private(set) static var tabs: [UUID: SecretImportPreset] = [:]
    /// The rule, added to MCPInputLine's once.
    private static let rule: Void = {
        MCPInputLine.rules.append { (tab: TerminalTab) -> String? in SecretManagerImportSheet.inputRefusal(tab) }
    }()

    let preset: SecretImportPreset
    /// A line for under the list: the line was typed, or why it wasn't.
    let say: (String) -> Void
    /// The sheet has gone.
    let done: () -> Void
    /// Open in a New Tab made its tab: an agent's import_secrets request waits for that tab's pipe.
    var opened: ((TerminalTab) -> Void)?
    private(set) var commandField = NSTextField(wrappingLabelWithString: "")
    private(set) var openButton = NSButton(title: SecretManagerImportSheet.openTitle, target: nil, action: nil)
    private(set) var cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var downloadButton = NSButton(title: "", target: nil, action: nil)
    private(set) var offLabel = NSTextField(wrappingLabelWithString: "")

    init(preset: SecretImportPreset, say: @escaping (String) -> Void, done: @escaping () -> Void) {
        self.preset = preset
        self.say = say
        self.done = done
        let frame = NSRect(x: 0, y: 0, width: 560, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
    }

    // MARK: the preset tabs

    /// The preset a tab got its line from, while that tab is open.
    static func preset(ofTab id: UUID) -> SecretImportPreset? { tabs[id] }

    /// Why agents can't act on a preset's tab, or nil for any other tab.
    static func inputRefusal(_ tab: TerminalTab) -> String? {
        guard let preset = tabs[tab.id] else { return nil }
        return "That tab is Import from \(preset.app): the user runs their password manager there, so agents can\u{2019}t "
            + "type in it, press its keys, answer in it or close it."
    }

    /// From now until the tab closes, agents can't act on it. Tabs closed since are let go.
    static func register(_ tab: TerminalTab, preset: SecretImportPreset) {
        _ = rule
        let open: Set<UUID> = Set(AppDelegate.shared.controllers.flatMap(\.tabs).map(\.id))
        tabs = tabs.filter { (entry: (key: UUID, value: SecretImportPreset)) -> Bool in open.contains(entry.key) }
        tabs[tab.id] = preset
    }

    // MARK: words

    /// What the sheet says will run, and how it unlocks.
    static func explanation(_ preset: SecretImportPreset) -> String {
        switch preset {
        case .onePassword:
            return "This runs 1Password\u{2019}s own CLI, op, in a new tab. You unlock it there with Touch ID. It reads "
                + "your API Credential and Password items and sends them to Next Term by pipe, not to the screen. "
                + "Next Term doesn\u{2019}t install op."
        case .bitwarden:
            return "This runs Bitwarden\u{2019}s own CLI, bw, in a new tab. You unlock it there with your master "
                + "password, at bw\u{2019}s own prompt. It reads your items and sends them to Next Term by pipe, not to "
                + "the screen, then locks Bitwarden again. Next Term doesn\u{2019}t install bw, and keeps no master "
                + "password or session key."
        case .bws:
            return "This runs Bitwarden Secrets Manager\u{2019}s CLI, bws, in a new tab. bws reads your access token "
                + "from BWS_ACCESS_TOKEN in the tab\u{2019}s environment. It sends your secrets to Next Term by pipe, not "
                + "to the screen. Next Term doesn\u{2019}t install bws."
        }
    }

    /// A line under the command, for Bitwarden Secrets Manager: how to take the token from Secrets by hand.
    static func note(_ preset: SecretImportPreset) -> String? {
        guard preset == .bws else { return nil }
        return "If you keep that token in Secrets, put nxtrm secret run BWS_ACCESS_TOKEN -- in front of bws yourself."
    }

    /// The line the new tab gets, for its shell; nil when that shell can't read it.
    static func line(_ preset: SecretImportPreset, shell: String) -> String? {
        preset.line(nxtrm: nxtrmWords, shell: shell)
    }

    /// `nxtrm` as the line runs it: the app's script, else its binary in command line mode. Never a PATH lookup, so a
    /// program of that name earlier on PATH can't pose as it.
    static var nxtrmWords: [String] {
        if let script = CommandLineTool.script?.path { return [script] }
        return [Bundle.main.executablePath ?? CommandLine.arguments[0], "--cli"]
    }
}
