import Foundation

extension SecretImportPipe {
    /// The command an agent started in a tab: the one that began while the agent drove the tab (it typed or pressed
    /// keys there, and the user hasn't since). It stays the agent's while it runs, whatever keys the user presses in it
    /// then: a Return at a prompt it prints, a password a password manager asks for, ⌘C or an arrow key. Those clear
    /// the tab's driven mark, but they don't change who started the line that runs. Commands go by the count of those
    /// the tab's shell said it started; a shell that doesn't say never gives an agent a command here.
    public struct AgentCommand: Equatable, Sendable {
        /// The commands the shell had started when the agent's input came, while none has started since and the user
        /// hasn't typed: the next one to start is the agent's.
        public private(set) var after: Int?
        /// The command, by the shell's count, that started while the agent drove the tab.
        public private(set) var started: Int?

        public init() {}

        /// The agent typed or pressed keys in the tab when its shell had started `commands` commands. A command of the
        /// agent's that still runs stays the agent's.
        public mutating func agentTyped(commands: Int) {
            after = commands
        }

        /// A look at the tab, whose shell has started `commands` commands, and which the agent still drives (`driven`)
        /// or not, since the user typed there. Returns whether to look again: until a command starts, or the user types
        /// first, when what starts next is theirs.
        public mutating func look(commands: Int, driven: Bool) -> Bool {
            guard let waited = after else { return false }
            if commands > waited {
                after = nil
                started = driven ? commands : nil
                return false
            }
            guard driven else {
                after = nil
                return false
            }
            return true
        }

        /// Whether the command running in the tab, the shell's `commands`th, is the one the agent started.
        public func ranByAgent(commands: Int, running: Bool) -> Bool {
            running && started == commands
        }
    }
}
