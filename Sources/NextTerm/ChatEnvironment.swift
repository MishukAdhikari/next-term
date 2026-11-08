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
        var made = ChatAgentEnvironment.make(login: LoginShell.environment, app: ProcessInfo.processInfo.environment,
                                             loginPath: LoginShell.path, socket: server.isRunning ? server.path : nil,
                                             toolFolder: CommandLineTool.script?.deletingLastPathComponent().path, version: version)
        #if DEBUG
        if let overlay = testOverlay {
            made.environment["PATH"] = overlay.pathFront + ":" + (made.environment["PATH"] ?? "/usr/bin:/bin")
            for (name, value) in overlay.variables { made.environment[name] = value }
        }
        #endif
        return made
    }

    /// Where `program` is on the environment's PATH; nil when it isn't there.
    static func locate(_ program: String, in environment: [String: String]) -> String? {
        AgentSessionCLI.locate(program, path: environment["PATH"] ?? LoginShell.path.joined(separator: ":"))
    }

    /// The PATH Agents › New Chat… and `new_tab`'s `agent_session` look along for the agents installed: the login
    /// shell's, with the usual install folders.
    static var searchPath: String {
        let path = LoginShell.path.joined(separator: ":")
        #if DEBUG
        if let overlay = testOverlay { return overlay.pathFront + ":" + path }
        #endif
        return path
    }

    #if DEBUG
    /// A self-test's stand-ins (SelfTestChatTab): `pathFront` goes first on every chat agent's PATH and on the PATH the
    /// installed agents are looked for along, and `variables` go into every chat agent's environment, while it is set.
    /// The user's own CLIs never run then. Read off the main thread, as the environment is made there.
    struct TestOverlay: Sendable {
        var pathFront: String
        var variables: [String: String]
    }

    private static let overlayLock = NSLock()
    nonisolated(unsafe) private static var overlay: TestOverlay?

    static var testOverlay: TestOverlay? {
        get {
            overlayLock.lock()
            defer { overlayLock.unlock() }
            return overlay
        }
        set {
            overlayLock.lock()
            defer { overlayLock.unlock() }
            overlay = newValue
        }
    }
    #endif
}
