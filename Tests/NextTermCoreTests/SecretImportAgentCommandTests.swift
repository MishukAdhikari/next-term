import Foundation
import Testing
@testable import NextTermCore

/// The command an agent started in a tab: the one that began while the agent drove the tab. It stays the agent's while
/// it runs, whatever keys the user presses in it then, so a line the agent typed with a prompt in it (a `read`, a
/// password manager asking for its password) is still the agent's after the user answers that prompt. Counts are made
/// up. `look` is mutating, so each answer is taken before it is checked.
@Suite struct SecretImportAgentCommandTests {
    typealias Command = SecretImportPipe.AgentCommand

    /// The agent typed a line at the prompt with its Return: the next command to start is the agent's, for as long as
    /// it runs, and the looks stop once it has started.
    @Test func theCommandThatStartsWhileTheAgentDrivesTheTabIsTheAgents() {
        var command = Command()
        command.agentTyped(commands: 4)
        let waits: Bool = command.look(commands: 4, driven: true)
        #expect(waits)
        #expect(!command.ranByAgent(commands: 4, running: false))
        let startedThenStops: Bool = command.look(commands: 5, driven: true)
        #expect(!startedThenStops)
        #expect(command.ranByAgent(commands: 5, running: true))
        // Ended, or another one started since: not the agent's any more.
        #expect(!command.ranByAgent(commands: 5, running: false))
        #expect(!command.ranByAgent(commands: 6, running: true))
    }

    /// The user's keys once the agent's command runs (a Return at its prompt, ⌘C, an arrow key) clear the tab's driven
    /// mark, but the looks have stopped and the command stays the agent's while it runs.
    @Test func theUsersKeysInTheAgentsCommandDontMakeItTheirs() {
        var command = Command()
        command.agentTyped(commands: 2)
        _ = command.look(commands: 3, driven: true)
        let afterTheUsersKey: Bool = command.look(commands: 3, driven: false)
        #expect(!afterTheUsersKey)
        #expect(command.ranByAgent(commands: 3, running: true))
    }

    /// The user typed in the tab before anything started: the line that runs next is theirs (or they changed it), so
    /// it isn't the agent's, and the looks stop.
    @Test func whatStartsAfterTheUserTypedIsTheirs() {
        var command = Command()
        command.agentTyped(commands: 7)
        let waits: Bool = command.look(commands: 7, driven: true)
        #expect(waits)
        let userTyped: Bool = command.look(commands: 7, driven: false)
        #expect(!userTyped)
        let theirsStarted: Bool = command.look(commands: 8, driven: false)
        #expect(!theirsStarted)
        #expect(!command.ranByAgent(commands: 8, running: true))
        // A command that started with the user's mark already on the tab isn't the agent's either.
        var typed = Command()
        typed.agentTyped(commands: 7)
        let startedAsTheirs: Bool = typed.look(commands: 8, driven: false)
        #expect(!startedAsTheirs)
        #expect(!typed.ranByAgent(commands: 8, running: true))
    }

    /// The agent's input while its own command runs (a key at that command's prompt) keeps that command the agent's;
    /// the next one to start while the agent still drives the tab is the agent's in its place.
    @Test func moreInputWhileTheAgentsCommandRunsKeepsIt() {
        var command = Command()
        command.agentTyped(commands: 1)
        _ = command.look(commands: 2, driven: true)
        command.agentTyped(commands: 2)
        #expect(command.ranByAgent(commands: 2, running: true))
        let userTyped: Bool = command.look(commands: 2, driven: false)
        #expect(!userTyped)
        #expect(command.ranByAgent(commands: 2, running: true))
        command.agentTyped(commands: 2)
        let nextStarted: Bool = command.look(commands: 3, driven: true)
        #expect(!nextStarted)
        #expect(command.ranByAgent(commands: 3, running: true))
        #expect(!command.ranByAgent(commands: 2, running: true))
    }

    /// The agent's input went into a program that was running (an agent's prompt, a REPL), and the user typed there
    /// before the shell started anything else: the user's next command is theirs.
    @Test func inputToARunningProgramDoesntClaimTheUsersNextCommand() {
        var command = Command()
        command.agentTyped(commands: 9)
        let waits: Bool = command.look(commands: 9, driven: true)
        let stillWaits: Bool = command.look(commands: 9, driven: true)
        #expect(waits && stillWaits)
        let userTyped: Bool = command.look(commands: 9, driven: false)
        #expect(!userTyped)
        let theirsStarted: Bool = command.look(commands: 10, driven: false)
        #expect(!theirsStarted)
        #expect(!command.ranByAgent(commands: 10, running: true))
    }

    /// No agent input: nothing to look for, and no command is the agent's. A shell that never says when a command
    /// starts never gives the agent one; the tab's driven mark alone decides there.
    @Test func withoutTheAgentsInputOrTheShellsCountNothingIsClaimed() {
        var none = Command()
        let nothingToLookFor: Bool = none.look(commands: 0, driven: true)
        #expect(!nothingToLookFor)
        #expect(!none.ranByAgent(commands: 0, running: true))
        var silent = Command()
        silent.agentTyped(commands: 0)
        let waits: Bool = silent.look(commands: 0, driven: true)
        #expect(waits)
        #expect(!silent.ranByAgent(commands: 0, running: true))
        let userTyped: Bool = silent.look(commands: 0, driven: false)
        #expect(!userTyped)
        #expect(!silent.ranByAgent(commands: 0, running: true))
    }
}
