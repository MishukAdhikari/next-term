import Foundation
import NextTermCore

/// The command an agent started in each tab it typed into: the one that began while the agent drove the tab. A line it
/// typed stays its own while it runs, even once the user presses a key there (a Return at the line's own prompt, ⌘C, an
/// arrow key), which ends the tab's driven mark. `nxtrm secret import` asks this as well as that mark.
@MainActor
enum SecretAgentCommands {
    private static var commands: [UUID: SecretImportPipe.AgentCommand] = [:]
    /// Tabs looked at now, for the command that starts after the agent's input.
    private static var looking: Set<UUID> = []

    /// An agent typed or pressed keys in the tab over MCP (the input hook, `SecretRequests.tabGotInput`). It is called
    /// before the tab is marked driven, so the first look comes a moment later; a line's Return comes a moment after
    /// its text.
    static func agentTyped(_ id: UUID) {
        let tabs: [TerminalTab] = AppDelegate.shared.controllers.flatMap(\.tabs)
        let open: Set<UUID> = Set(tabs.map(\.id))
        commands = commands.filter { (entry: (key: UUID, value: SecretImportPipe.AgentCommand)) -> Bool in
            open.contains(entry.key)
        }
        guard let tab = tabs.first(where: { (tab: TerminalTab) -> Bool in tab.id == id }) else { return }
        var command: SecretImportPipe.AgentCommand = commands[id] ?? SecretImportPipe.AgentCommand()
        command.agentTyped(commands: tab.status.commandsStarted)
        commands[id] = command
        guard !looking.contains(id) else { return }
        looking.insert(id)
        look(tab, count: 0)
    }

    /// Whether the command running in `tab` is one an agent started there.
    static func ranByAgent(_ tab: TerminalTab) -> Bool {
        guard let command = commands[tab.id] else { return false }
        return command.ranByAgent(commands: tab.status.commandsStarted, running: tab.status.running)
    }

    /// Looks ten times a second for five seconds, as a line typed at the prompt starts within them, then once a second
    /// (a line typed while a command ran waits for it to end), until a command starts, the user types there, or the tab
    /// ends.
    private static func look(_ tab: TerminalTab, count: Int) {
        let id: UUID = tab.id
        let delay: TimeInterval = count < 50 ? 0.1 : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tab] in
            MainActor.assumeIsolated {
                guard let tab, !tab.exited, var command = commands[id] else {
                    looking.remove(id)
                    return
                }
                let again: Bool = command.look(commands: tab.status.commandsStarted, driven: MCPControl.isDriven(tab))
                commands[id] = command
                guard again else {
                    looking.remove(id)
                    return
                }
                look(tab, count: count + 1)
            }
        }
    }
}
