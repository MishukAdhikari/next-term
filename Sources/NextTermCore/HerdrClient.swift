import Foundation

/// herdr's own screen in a tab on this Mac: the program in front is herdr's client (`herdr`, `herdr --session X`,
/// `herdr session attach X`), which Next Term then reads as it reads a server's herdr (HerdrAgents), through the same
/// herdr executable. Any other herdr command (`herdr agent list`, `herdr status`) is a plain command.
public enum HerdrClient {
    /// The client's variables Next Term passes to the herdr it runs for it, so it asks the client's own server, and no
    /// others of its environment (they are never kept).
    public static let variables: Set<String> = ["HERDR_SOCKET_PATH", "HERDR_SESSION", "XDG_CONFIG_HOME"]

    /// Shells that run a script given as their first argument: a wrapper script named herdr is the executable then.
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// The herdr client in front, from what the kernel says of it: the executable to run herdr's commands with (absolute),
    /// and the session it shows (nil: herdr's default). nil when it is not herdr's client, or its executable is unknown.
    public static func match(_ process: ForegroundProcess) -> (executable: String, session: String?)? {
        guard !process.isShell else { return nil }
        var arguments = process.arguments
        if arguments.isEmpty { arguments = [process.executablePath.isEmpty ? process.name : process.executablePath] }
        guard let found = match(arguments: arguments) else { return nil }
        // The executable herdr runs as: the kernel's path for herdr itself; the script for a wrapper (argv says it).
        let executable = found.script ?? (process.executablePath.hasPrefix("/") ? process.executablePath : found.program)
        guard executable.hasPrefix("/") else { return nil }
        return (executable, found.session)
    }

    /// argv (the program first) of herdr's client: herdr with no arguments, `--session X` (or `--session=X`), or
    /// `session attach X`; or an interpreter running a script named herdr with the same. `script`: the script's path for
    /// the second.
    public static func match(arguments: [String]) -> (program: String, script: String?, session: String?)? {
        guard let first = arguments.first else { return nil }
        let name = (first as NSString).lastPathComponent
        if name == "herdr" {
            guard let session = session(Array(arguments.dropFirst())) else { return nil }
            return (first, nil, session)
        }
        guard interpreters.contains(name), arguments.count >= 2 else { return nil }
        let script = arguments[1]
        guard script.hasPrefix("/"), (script as NSString).lastPathComponent == "herdr" else { return nil }
        guard let session = session(Array(arguments.dropFirst(2))) else { return nil }
        return (first, script, session)
    }

    /// What the client's arguments say of its session: `.some(nil)` for herdr's default, `.some(name)` for one it
    /// names, nil when they are not a client's (another verb, or `--session` with no name herdr takes).
    static func session(_ arguments: [String]) -> String?? {
        switch arguments.count {
        case 0:
            return .some(nil)
        case 1:
            guard arguments[0].hasPrefix("--session=") else { return nil }
            let name = String(arguments[0].dropFirst("--session=".count))
            return HerdrSession.isName(name) ? .some(name) : nil
        case 2:
            guard arguments[0] == "--session", HerdrSession.isName(arguments[1]) else { return nil }
            return .some(arguments[1])
        case 3:
            guard arguments[0] == "session", arguments[1] == "attach", HerdrSession.isName(arguments[2]) else { return nil }
            return .some(arguments[2])
        default:
            return nil
        }
    }
}
