import Foundation
import NextTermCore

/// The environment a chat tab's agent starts with (plan 037 KTD7): the login shell's own, from the probe Next Term runs
/// once a launch, less one shell's and Next Term's own variables, plus what a Next Term tab gives every program (its
/// name and version, the MCP socket, `nxtrm` on PATH, LANG). `ChatAgentEnvironment` holds the rules.
enum ChatEnvironment {
    /// The agent's environment, and whether it is the login shell's. The first call waits for the probe (5 s at most):
    /// call it off the main thread.
    static func make() -> (environment: [String: String], fromLoginShell: Bool) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let server = MCPControlServer.shared
        return ChatAgentEnvironment.make(login: LoginShell.environment, app: ProcessInfo.processInfo.environment,
                                         loginPath: LoginShell.path, socket: server.isRunning ? server.path : nil,
                                         toolFolder: CommandLineTool.script?.deletingLastPathComponent().path, version: version)
    }

    /// Where `program` is on the environment's PATH; nil when it isn't there.
    static func locate(_ program: String, in environment: [String: String]) -> String? {
        AgentSessionCLI.locate(program, path: environment["PATH"] ?? LoginShell.path.joined(separator: ":"))
    }
}
