import AppKit
import NextTermCore

/// `nxtrm secret import`'s preview, on the main thread: Window › Secrets comes forward with the copy sheet for the
/// piped keys, or for the file given (as Import From › A File… reads one), and the importer hears how far it got and
/// how it ended, in counts. The sheet's header says where the pipe came from: the tab above the importer and, when an
/// agent runs above it, that the agent may have seen the keys.
@MainActor
enum SecretPipeImport {
    /// The name piped keys are read under: their purpose is "From standard input" unless a manager's JSON names its app.
    nonisolated static let standardInput = "standard input"
    static let agentWarning = "An agent ran this command. It may have seen these keys."
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
        var preset: SecretImportPreset?
        /// "tab 2 of rag-api".
        var place: String?
    }

    static func origin(pid: pid_t, agent: String?, piped: Bool) -> Origin {
        var origin = Origin(piped: piped, agent: agent)
        let tabs: [TerminalTab] = AppDelegate.shared.controllers.flatMap(\.tabs)
        guard let tab = ClaudeIDEServer.tab(for: pid, among: tabs) else { return origin }
        origin.tabID = tab.id
        origin.preset = SecretManagerImportSheet.preset(ofTab: tab.id)
        guard let controller = MCPControl.controller(of: tab) else { return origin }
        let position: Int? = controller.groups.firstIndex { (group: PaneGroup) -> Bool in group.contains(tab) }
        let tabText: String = position.map { (index: Int) -> String in "tab \(index + 1)" } ?? "a tab"
        let project: String? = controller.project.map { (path: String) -> String in (path as NSString).lastPathComponent }
        origin.place = project.map { (name: String) -> String in "\(tabText) of \(name)" } ?? tabText
        return origin
    }

    /// The copy sheet for piped keys.
    static func openPiped(_ report: SourceReport, origin: Origin, channel: SecretPipeSocket.Channel) {
        let client = SecretImportClient(origin: origin, channel: channel)
        guard let view = secretsView(for: client) else { return }
        view.openFileImport(path: "", report: report, inGit: false, client: client)
    }

    /// The file given, read as Import From › A File… reads a picked one: an agent's MCP config opens the MCP-config
    /// import for it.
    static func openFile(_ path: String, format: SecretSources.Format?, origin: Origin, channel: SecretPipeSocket.Channel) {
        let client = SecretImportClient(origin: origin, channel: channel)
        guard let view = secretsView(for: client) else { return }
        view.readPicked(URL(fileURLWithPath: path), format: format, client: client)
    }

    /// Window › Secrets in front, with no sheet open on it; else the importer hears `busy`, or `refused` when Secrets
    /// can't be opened on this Mac.
    private static func secretsView(for client: SecretImportClient) -> SecretsView? {
        SecretsWindowController.show()
        NSApp.activate(ignoringOtherApps: true)
        guard let view = SecretsWindowController.shared?.secretsView else {
            client.end(.refused)
            return nil
        }
        let protection: SecretsStore.Protection = SecretsStore.shared.protection
        if protection == .cantOpen || protection == .tampered {
            client.end(.refused)
            return nil
        }
        guard !view.hasOpenSheet else {
            view.say(busyLine)
            client.end(.busy)
            return nil
        }
        return view
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
