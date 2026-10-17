import AppKit
import NextTermCore

/// `nxtrm secret import`'s preview, on the main thread: the Secrets window comes forward with the copy sheet for the
/// piped keys, or for the file given (as Import From › A File… reads one), and the importer hears how far it got and
/// how it ended, in counts. The sheet's header says where the pipe came from: the tab above the importer and, when an
/// agent runs above it or no tab is, that an agent may have seen the keys. Busy and refused are decided first, before
/// Secrets comes forward and before the keys are sent.
@MainActor
enum SecretPipeImport {
    /// The name piped keys are read under: their purpose is "From standard input" unless a manager's JSON names its app.
    nonisolated static let standardInput = "standard input"
    static let busyLine = "nxtrm secret import asked to open an import. Finish what\u{2019}s open here, then run it again."

    /// Where the keys came from, as the process tree and the tabs tell it: never from what was piped.
    struct Origin {
        /// Keys on standard input; false for a file the app read.
        var piped: Bool
        /// The agent above the importer, by its name.
        var agent: String?
        /// The tab the importer runs in.
        var tabID: UUID?
        /// The preset whose line that tab got (Import From › 1Password…), when it is one of theirs.
        var tabPreset: SecretImportPreset?
        /// The line the tab's shell said it is running; nil when its shell doesn't say (only zsh's integration does).
        var command: String?
        /// `tabPreset`, when the tab runs its line as typed: only then does the sheet name it.
        var preset: SecretImportPreset?
        /// "tab 2 of rag-api".
        var place: String?

        /// The warning under the sheet's header: an agent ran it, or no tab did.
        var warning: String? { SecretImportPipe.originWarning(agent: agent, inTab: tabID != nil) }
    }

    static func origin(pid: pid_t, agent: String?, piped: Bool) -> Origin {
        var origin = Origin(piped: piped, agent: agent)
        let tabs: [TerminalTab] = AppDelegate.shared.controllers.flatMap(\.tabs)
        guard let tab = ClaudeIDEServer.tab(for: pid, among: tabs) else { return origin }
        origin.tabID = tab.id
        let said: String = tab.status.integrated && tab.status.running ? tab.status.command : ""
        origin.command = said.isEmpty ? nil : said
        origin.tabPreset = SecretManagerImportSheet.preset(ofTab: tab.id)
        if let preset = origin.tabPreset, let command = origin.command,
           let line = SecretManagerImportSheet.line(preset, shell: SecretsMCP.shellName(of: tab)),
           SecretImportPreset.ran(command, as: line) {
            origin.preset = preset
        }
        guard let controller = MCPControl.controller(of: tab) else { return origin }
        let position: Int? = controller.groups.firstIndex { (group: PaneGroup) -> Bool in group.contains(tab) }
        let tabText: String = position.map { (index: Int) -> String in "tab \(index + 1)" } ?? "a tab"
        let project: String? = controller.project.map { (path: String) -> String in (path as NSString).lastPathComponent }
        origin.place = project.map { (name: String) -> String in "\(tabText) of \(name)" } ?? tabText
        return origin
    }

    /// The copy sheet for piped keys. From the tab an agent's import_secrets request opened (Open in a New Tab), it
    /// shows that request's banner and answers it.
    static func openPiped(_ report: SourceReport, origin: Origin, channel: SecretPipeSocket.Channel) {
        let client = SecretImportClient(origin: origin, channel: channel)
        guard let view = secretsView(for: client) else { return }
        let asked: SecretImportAsk? = origin.tabID.flatMap { (id: UUID) -> SecretImportAsk? in
            SecretImportAsk.waiting(onTab: id)
        }
        view.openFileImport(path: "", report: report, inGit: false, client: client, asked: asked)
    }

    /// The file given, read as Import From › A File… reads a picked one: an agent's MCP config opens the MCP-config
    /// import for it.
    static func openFile(_ path: String, format: SecretSources.Format?, origin: Origin, channel: SecretPipeSocket.Channel) {
        let client = SecretImportClient(origin: origin, channel: channel)
        guard let view = secretsView(for: client) else { return }
        view.readPicked(URL(fileURLWithPath: path), format: format, client: client)
    }

    /// The Secrets window in front, with no sheet open on it. Busy or refused is decided first, so a run that can't open
    /// a sheet never takes the keyboard from the tab the user types in (a password at bw's prompt, say).
    private static func secretsView(for client: SecretImportClient) -> SecretsView? {
        if let status = blockedStatus() {
            client.end(status)
            return nil
        }
        SecretsWindowController.show()
        NSApp.activate(ignoringOtherApps: true)
        guard let view = SecretsWindowController.shared?.secretsView else {
            client.end(.refused)
            return nil
        }
        return view
    }

    /// Why no import can open now, without bringing anything forward: `refused` when Secrets can't be opened on this
    /// Mac, `busy` (and a line under the list) when it shows another sheet. The socket asks this before `ready`, so a
    /// busy Secrets never gets the keys; the sheet asks it again as it opens.
    static func blockedStatus() -> SecretImportPipe.Reply.Status? {
        SecretsStore.shared.reloadIfChanged()
        let protection: SecretsStore.Protection = SecretsStore.shared.protection
        if protection == .cantOpen || protection == .tampered { return .refused }
        guard let view = SecretsWindowController.shared?.secretsView, view.hasOpenSheet else { return nil }
        view.say(busyLine)
        return .busy
    }
}

/// The importer waiting on the socket for a preview: told once it opens, and once it ends. Counts only.
@MainActor
final class SecretImportClient {
    let origin: SecretPipeImport.Origin
    private let channel: SecretPipeSocket.Channel
    private(set) var hasEnded = false

    init(origin: SecretPipeImport.Origin, channel: SecretPipeSocket.Channel) {
        self.origin = origin
        self.channel = channel
    }

    /// The copy sheet is open for `report`.
    func opened(_ report: SourceReport) {
        guard !hasEnded else { return }
        let found = SecretImportPipe.Reply(status: .found, count: report.rows.count)
        channel.send(report.unreadable == nil ? found : SecretImportPipe.Reply(status: .unreadable))
    }

    /// The copy sheet closed, having copied `count` keys in.
    func ended(copied count: Int) {
        end(count > 0 ? .imported : .nothing, count: count)
    }

    func end(_ status: SecretImportPipe.Reply.Status, count: Int? = nil) {
        guard !hasEnded else { return }
        hasEnded = true
        channel.send(SecretImportPipe.Reply(status: status, count: count))
    }
}
