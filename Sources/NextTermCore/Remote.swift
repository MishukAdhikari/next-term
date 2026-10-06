import Foundation

// Connect VPS: terminal tabs on a server, over the system ssh. Pure logic here (hosts, the scripts that
// run on the host, the parsing of what they print); the app owns the processes.
//
// Security rules this file keeps:
// - Nothing typed by a user or an agent is ever spliced into a remote shell line. Every script is built
//   here from fixed text plus values quoted for POSIX sh, then sent base64-encoded (an alphabet no shell
//   reads specially) and decoded by /bin/sh on the host. See RemoteShell.command.
// - A destination can never be read by ssh as an option (no leading "-", and ssh is given "--").
// - Next Term installs nothing on a host: tmux and herdr are used only if the user installed them.

/// How a host keeps agents running when this Mac disconnects, sleeps or is off.
public enum KeepMode: String, Codable, Sendable, CaseIterable {
    /// A plain ssh shell: what runs in it stops when the connection drops.
    case off
    /// A private tmux server on the host (`tmux -L nextterm`): sessions outlive the connection, and any
    /// Mac can attach to them again.
    case tmux
    /// The user's own herdr (herdr.dev) on the host: Next Term attaches to it and shows its agents' states.
    case herdr

    public var label: String {
        switch self {
        case .off: return "Off"
        case .tmux: return "tmux"
        case .herdr: return "herdr"
        }
    }

    /// One line on what the choice means, for the sheet and for MCP.
    public var summary: String {
        switch self {
        case .off: return "A plain shell: agents stop if the connection drops."
        case .tmux: return "Agents keep running on the host while this Mac is away; tabs reattach. Needs tmux on the host."
        case .herdr: return "Attaches to your own herdr on the host, which keeps agents running and resumes them after a reboot."
        }
    }
}

/// A server the user connects to.
public struct RemoteHost: Codable, Equatable, Sendable {
    /// Stable id (saved tabs and MCP refer to it).
    public var id: String
    /// What the user calls it ("web-1").
    public var name: String
    /// What ssh connects to: an alias from ~/.ssh/config, `host`, `user@host` or `user@2001:db8::1`.
    public var destination: String
    public var port: Int?
    /// Folder new tabs open in, on the host: absolute, `~` or `~/…`.
    public var directory: String
    public var keep: KeepMode

    public init(id: String = RemoteHost.makeID(), name: String, destination: String, port: Int? = nil,
                directory: String = "~", keep: KeepMode = .tmux) {
        self.id = id
        self.name = name
        self.destination = destination
        self.port = port
        self.directory = directory
        self.keep = keep
    }

    public static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Why this host cannot be used, or nil.
    public var problem: String? {
        if let issue = Self.destinationProblem(destination) { return issue }
        if let port, !(1...65535).contains(port) { return "The port must be between 1 and 65535." }
        if let issue = Self.directoryProblem(directory) { return issue }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.count > 64 || trimmed.unicodeScalars.contains(where: ShellQuote.isControl) {
            return "Give the host a name of up to 64 characters."
        }
        return nil
    }

    /// ssh destinations: letters, digits and `. _ - @ : % +` (IPv6 as `user@2001:db8::1`; OpenSSH takes no
    /// brackets there). Nothing ssh or a shell could read as an option, a command or a second argument.
    public static func destinationProblem(_ destination: String) -> String? {
        if destination.isEmpty { return "Give the ssh destination: user@host, or an alias from ~/.ssh/config." }
        if destination.count > 255 { return "The destination is too long." }
        if destination.hasPrefix("-") { return "The destination cannot start with “-”." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:%+")
        guard destination.unicodeScalars.allSatisfy(allowed.contains) else {
            return "The destination may only hold letters, digits and . _ - @ : % + (no spaces; the port goes in its own field)."
        }
        return nil
    }

    public static func directoryProblem(_ directory: String) -> String? {
        if directory.isEmpty || directory.count > 1024 { return "Give a folder on the host (absolute, or starting with ~)." }
        if directory.unicodeScalars.contains(where: ShellQuote.isControl) { return "The folder name holds a control character." }
        guard directory == "~" || directory.hasPrefix("~/") || directory.hasPrefix("/") else {
            return "The folder must be absolute (/srv/app) or start with ~ (~/app)."
        }
        return nil
    }

    /// The hosts as saved (a JSON array).
    public static func decodeList(_ data: Data?) -> [RemoteHost] {
        guard let data, let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return [] }
        return hosts.filter { $0.problem == nil }
    }

    public static func encodeList(_ hosts: [RemoteHost]) -> Data {
        (try? JSONEncoder().encode(hosts)) ?? Data("[]".utf8)
    }
}

/// A remote tab as saved at quit, so Next Term reattaches to its session at the next launch.
public struct RemoteTabRecord: Codable, Equatable, Sendable {
    public var hostID: String
    public var directory: String
    public var session: String
    public var keep: KeepMode
    /// The project window it was in, if any.
    public var project: String?
    public var title: String?

    public init(hostID: String, directory: String, session: String, keep: KeepMode, project: String? = nil, title: String? = nil) {
        self.hostID = hostID
        self.directory = directory
        self.session = session
        self.keep = keep
        self.project = project
        self.title = title
    }
}

// MARK: - ssh command lines

public enum SSHArguments {
    /// Options for every connection to a host. One master connection per host carries every tab and
    /// every background check (ControlMaster). The master stays 10 minutes after its last use.
    /// ClearAllForwardings: Next Term forwards nothing (not its MCP socket, not its IDE ports), and a
    /// forward in the user's ssh config would clash with their own sessions.
    public static func common(controlPath: String, port: Int?) -> [String] {
        var args = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\"\(controlPath)\"",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "ClearAllForwardings=yes",
            // A RemoteCommand in the user's config would make ssh refuse ours.
            "-o", "RemoteCommand=none",
        ]
        if let port { args += ["-p", String(port)] }
        return args
    }

    /// A terminal tab: a pty on the host running `command`. No escape character, so text pasted into an
    /// agent (or typed by MCP) that starts a line with "~." cannot cut the connection.
    public static func tab(_ host: RemoteHost, controlPath: String, command: String) -> [String] {
        common(controlPath: controlPath, port: host.port) + ["-t", "-o", "EscapeChar=none", "--", host.destination, command]
    }

    /// A background command (status checks, git). Never prompts: with no master and no usable key it
    /// fails. An unknown or changed host key is refused, never accepted, whatever the user's config says
    /// (accept-new or no would otherwise add a key with nobody looking). Over an open master the key was
    /// checked when the tab connected, in front of the user.
    public static func exec(_ host: RemoteHost, controlPath: String, command: String) -> [String] {
        common(controlPath: controlPath, port: host.port)
            + ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "--", host.destination, command]
    }

    /// Asks the master to exit (at quit).
    public static func exit(_ host: RemoteHost, controlPath: String) -> [String] {
        ["-o", "ControlPath=\"\(controlPath)\""] + (host.port.map { ["-p", String($0)] } ?? []) + ["-O", "exit", "--", host.destination]
    }

    /// A control socket's file name for a host: short (Unix socket paths hold 104 bytes, and ssh adds a
    /// 17-character suffix while it binds), and the same for the same destination and port.
    public static func controlName(_ host: RemoteHost) -> String {
        // FNV-1a, 64 bits: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(host.destination)|\(host.port ?? 22)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Longest control path ssh accepts: sun_path (104) less its terminator and the bind suffix.
    public static let maxControlPathBytes = 104 - 1 - 17
}

// MARK: - scripts run on the host

public enum RemoteShell {
    /// Single quotes for POSIX sh (dash has no $'…', so ShellQuote's ANSI-C form is not used here).
    /// Values are checked for control characters before they get here.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A folder on the host as one sh word: `~` and `~/x` become `$HOME` and `$HOME/x`.
    public static func folder(_ path: String) -> String {
        if path.isEmpty || path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return rest.isEmpty ? "\"$HOME\"" : "\"$HOME\"/" + quote(rest)
        }
        return quote(path)
    }

    /// The command line ssh hands to the user's login shell (bash, zsh, fish, tcsh…). It only ever holds
    /// fixed text and base64: /bin/sh decodes the script and runs it, so no login shell parses the script.
    public static func command(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        // GNU, BusyBox and macOS 13+ take -d; older macOS only -D.
        return "exec /bin/sh -c 'd=$(printf %s \(encoded) | base64 -d 2>/dev/null) || d=$(printf %s \(encoded) | base64 -D); eval \"$d\"'"
    }

    /// Lines before this marker are the login shell's own noise (motd, rc files); parsers start after it.
    public static let marker = "@@NEXTTERM@@"
    static let herdrMarker = "@@NEXTTERM-HERDR@@"
    static let statMarker = "@@NEXTTERM-STAT@@"
    static let diffMarker = "@@NEXTTERM-DIFF@@"

    /// Where Next Term keeps its few files on the host (tab pid files, the tmux config).
    static let cacheDir = "\"$HOME/.cache/next-term\""

    /// Finds the user's herdr: on PATH or in its usual install folders. Sets H.
    static let findHerdr = """
        H=$(command -v herdr 2>/dev/null)
        if [ -z "$H" ]; then
          for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
            if [ -x "$p" ]; then H=$p; break; fi
          done
        fi
        """

    /// Finds tmux: on PATH, or where Homebrew, Linuxbrew and user installs put it (a non-login shell's
    /// PATH often lacks them). Sets T.
    static let findTmux = """
        T=$(command -v tmux 2>/dev/null)
        if [ -z "$T" ]; then
          for p in "$HOME/.local/bin/tmux" /home/linuxbrew/.linuxbrew/bin/tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
            if [ -x "$p" ]; then T=$p; break; fi
          done
        fi
        """

    /// Settings for Next Term's own tmux server (`-L nextterm`), never the user's default server.
    /// Next Term's tab bar replaces tmux's status line; the mouse wheel scrolls tmux's history; titles
    /// (Claude Code names its task) reach the tab; Escape is not delayed (agents use it to interrupt).
    static let tmuxConfig = """
        set -g status off
        set -g mouse on
        set -g history-limit 50000
        set -sg escape-time 10
        set -g focus-events on
        set -g set-titles on
        set -g set-titles-string "#{pane_title}"
        set -gq allow-passthrough on
        set -sq extended-keys on
        set -gq window-size latest
        """

    static func plainShell(_ note: String?) -> String {
        var lines: [String] = []
        if let note { lines.append("printf '%s\\r\\n' \(quote(note))") }
        lines.append("exec \"${SHELL:-/bin/sh}\" -l")
        return lines.joined(separator: "\n")
    }

    /// What a tab runs on the host. Every mode records the tab's shell pid, so status checks can find
    /// what runs in front of it.
    public static func tabScript(keep: KeepMode, directory: String, session: String, tabID: String) -> String {
        // K: this tab's files on the host. K.plain: tmux or herdr was missing, so this is a plain shell.
        // K.nodir: the folder was not there.
        var lines = [
            "C=\(cacheDir)",
            "K=\"$C/tabs/\(safeName(tabID))\"",
            "mkdir -p \"$C/tabs\" 2>/dev/null; rm -f \"$K.plain\" \"$K.nodir\"",
            "if ! cd \(folder(directory)) 2>/dev/null; then",
            "  : > \"$K.nodir\" 2>/dev/null",
            "  printf 'Next Term: %s is not a folder on this host; this tab opened in your home folder.\\r\\n' \(quote(directory))",
            "  cd",
            "fi",
            "printf '%s\\n' \"$$\" > \"$K\" 2>/dev/null",
        ]
        switch keep {
        case .off:
            lines.append(plainShell(nil))
        case .tmux:
            lines += [
                findTmux,
                "if [ -z \"$T\" ]; then",
                "  : > \"$K.plain\" 2>/dev/null",
                plainShell("tmux is not installed on this host: this is a plain shell, and what runs in it stops if the connection drops."),
                "fi",
                "printf '%s\\n' \(quote(tmuxConfig)) > \"$C/tmux.conf\" 2>/dev/null",
                "exec \"$T\" -L nextterm -f \"$C/tmux.conf\" new-session -A -s \(quote(safeName(session))) -c \"$PWD\"",
            ]
        case .herdr:
            lines += [
                findHerdr,
                "if [ -z \"$H\" ]; then",
                "  : > \"$K.plain\" 2>/dev/null",
                plainShell("herdr is not installed on this host (see herdr.dev). Next Term uses your own herdr and never installs it: this is a plain shell."),
                "fi",
                "exec \"$H\"",
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// One status check for every tab on a host: what runs in front of each tab's shell, its folder, and
    /// (if a tab uses herdr) herdr's list of agents.
    public static func pollScript(tabs: [(id: String, keep: KeepMode, session: String)]) -> String {
        var lines = [
            "C=\(cacheDir)",
            findTmux,
            // $1: the pid of a tab's shell. Prints "shell", "fg<TAB>comm<TAB>args", or "?". procps and BSD
            // ps, or /proc where ps is BusyBox's (no -p, no tpgid).
            "nt_fg() {",
            "  p=$1",
            "  if [ -z \"$p\" ]; then echo '?'; return; fi",
            "  g=$(ps -o tpgid= -p \"$p\" 2>/dev/null | tr -d ' ')",
            "  if [ -z \"$g\" ] && [ -r \"/proc/$p/stat\" ]; then g=$(sed 's/.*) //' \"/proc/$p/stat\" | cut -d' ' -f6); fi",
            "  if [ -z \"$g\" ] || [ \"$g\" = -1 ] || [ \"$g\" = 0 ]; then echo '?'; return; fi",
            "  if [ \"$g\" = \"$p\" ]; then echo shell; return; fi",
            "  c=$(ps -o comm= -p \"$g\" 2>/dev/null)",
            "  a=$(ps -o args= -p \"$g\" 2>/dev/null | tr '\\t' ' ')",
            "  if [ -z \"$c\" ] && [ -r \"/proc/$g/comm\" ]; then c=$(cat \"/proc/$g/comm\"); a=$(tr '\\000\\t' '  ' < \"/proc/$g/cmdline\" 2>/dev/null); fi",
            "  if [ -z \"$c\" ]; then echo '?'; else printf 'fg\\t%s\\t%s\\n' \"$c\" \"$a\"; fi",
            "}",
            "printf '%s\\n' \(quote(marker))",
        ]
        for tab in tabs {
            let id = safeName(tab.id)
            switch tab.keep {
            case .herdr:
                // herdr reports its agents itself; the pid only shows the tab got past ssh's login.
                lines.append("p=$(cat \"$C/tabs/\(id)\" 2>/dev/null); d=")
            case .tmux:
                lines += [
                    "p= ; d=",
                    "if [ -n \"$T\" ]; then",
                    "  p=$(\"$T\" -L nextterm display-message -p -t \(quote("=" + safeName(tab.session) + ":")) '#{pane_pid}' 2>/dev/null)",
                    "  d=$(\"$T\" -L nextterm display-message -p -t \(quote("=" + safeName(tab.session) + ":")) '#{pane_current_path}' 2>/dev/null)",
                    "fi",
                    "[ -n \"$p\" ] || p=$(cat \"$C/tabs/\(id)\" 2>/dev/null)",
                ]
            case .off:
                lines += [
                    "p=$(cat \"$C/tabs/\(id)\" 2>/dev/null); d=",
                    "[ -n \"$p\" ] && d=$(readlink \"/proc/$p/cwd\" 2>/dev/null)",
                ]
            }
            lines += [
                "printf '%s\\t' \(quote(id)); nt_fg \"$p\"",
                "[ -n \"$d\" ] && printf '%s\\tdir\\t%s\\n' \(quote(id)) \"$d\"",
                "[ -e \"$C/tabs/\(id).plain\" ] && printf '%s\\tplain\\n' \(quote(id))",
                "[ -e \"$C/tabs/\(id).nodir\" ] && printf '%s\\tnodir\\n' \(quote(id))",
            ]
        }
        if tabs.contains(where: { $0.keep == .herdr }) {
            lines += [findHerdr, "if [ -n \"$H\" ]; then printf '%s\\n' \(quote(herdrMarker)); \"$H\" agent list 2>/dev/null | tr -d '\\n'; echo; fi"]
        }
        return lines.joined(separator: "\n")
    }

    /// What the host has: for check_host and the sheet.
    public static let probeScript = """
        printf '%s\\n' \(quote(marker))
        printf 'os\\t%s\\n' "$(uname -sm 2>/dev/null)"
        printf 'shell\\t%s\\n' "${SHELL:-}"
        printf 'home\\t%s\\n' "$HOME"
        \(findTmux)
        [ -n "$T" ] && printf 'tmux\\t%s\\n' "$("$T" -V 2>/dev/null)"
        \(findHerdr)
        [ -n "$H" ] && printf 'herdr\\t%s\\n' "$("$H" --version 2>/dev/null | head -n 1)"
        command -v git >/dev/null 2>&1 && printf 'git\\t%s\\n' "$(git --version 2>/dev/null)"
        for a in claude codex gemini; do command -v "$a" >/dev/null 2>&1 && printf 'agent\\t%s\\n' "$a"; done
        command -v loginctl >/dev/null 2>&1 && printf 'linger\\t%s\\n' "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
        [ -n "$T" ] && "$T" -L nextterm list-sessions -F 'session\t#{session_name}\t#{session_attached}\t#{pane_current_path}\t#{pane_current_command}' 2>/dev/null
        true
        """

    /// The kept sessions on a host: Next Term's tmux sessions, and herdr's agents.
    public static let sessionsScript = """
        printf '%s\\n' \(quote(marker))
        \(findTmux)
        [ -n "$T" ] && "$T" -L nextterm list-sessions -F 'session\t#{session_name}\t#{session_attached}\t#{pane_current_path}\t#{pane_current_command}' 2>/dev/null
        \(findHerdr)
        if [ -n "$H" ]; then printf '%s\\n' \(quote(herdrMarker)); "$H" agent list 2>/dev/null | tr -d '\\n'; echo; fi
        true
        """

    /// What changed in a git work tree on the host: status, a diffstat, and the diff (cut at `maxBytes`).
    /// Never takes git's index lock, and no fsmonitor hook runs.
    public static func changesScript(directory: String, maxBytes: Int) -> String {
        """
        cd \(folder(directory)) 2>/dev/null || { echo 'No such folder on the host.' >&2; exit 3; }
        G='git -c core.fsmonitor=false -c core.pager=cat'
        export GIT_OPTIONAL_LOCKS=0
        $G rev-parse --show-toplevel >/dev/null 2>&1 || { echo 'Not a git work tree.' >&2; exit 4; }
        printf '%s\\n' \(quote(marker))
        $G status --porcelain=v1 -b 2>/dev/null
        printf '%s\\n' \(quote(statMarker))
        B=HEAD; $G rev-parse --verify -q HEAD >/dev/null || B=$($G hash-object -t tree /dev/null)
        $G diff "$B" --stat --no-color 2>/dev/null
        printf '%s\\n' \(quote(diffMarker))
        $G diff "$B" --no-color --no-ext-diff 2>/dev/null | head -c \(max(0, maxBytes))
        """
    }

    /// Names that go into scripts and file names: letters, digits, `-` and `_` only.
    public static func safeName(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
        return String(String(String.UnicodeScalarView(kept)).prefix(64))
    }

    /// A tmux session name for a new tab: "nt-<folder>-<6 hex>".
    public static func newSessionName(directory: String) -> String {
        let last = directory == "~" ? "home" : (directory as NSString).lastPathComponent.lowercased()
        let slug = String(safeName(last.replacingOccurrences(of: " ", with: "-")).prefix(24))
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        return "nt-" + (slug.isEmpty ? "tab" : slug) + "-" + suffix
    }

    /// The lines after the marker (nil when the marker never came: the script did not run).
    public static func payload(_ output: String, after mark: String = marker) -> [Substring]? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        guard let start = lines.firstIndex(where: { $0 == mark }) else { return nil }
        return Array(lines[(start + 1)...])
    }
}

// MARK: - what the scripts print

/// One tab's line from the status check.
public struct RemoteTabReport: Equatable, Sendable {
    /// nil: unknown (the tab's shell is gone or not found yet); keep the current state.
    public var foreground: ForegroundProcess?
    public var directory: String?
    /// The tab's script ran on the host (it got past ssh's login).
    public var started = false
    /// tmux or herdr was missing: the tab is a plain shell, kept by nothing.
    public var plain = false
    /// The folder asked for was not there; the tab opened in the home folder.
    public var folderMissing = false
}

public struct RemotePoll: Equatable, Sendable {
    public var tabs: [String: RemoteTabReport] = [:]
    /// herdr's agents, when a tab on this host uses herdr and herdr answered.
    public var herdr: [HerdrAgent]?

    public init() {}

    public static func parse(_ output: String) -> RemotePoll? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var poll = RemotePoll()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line == RemoteShell.herdrMarker {
                if index < lines.count { poll.herdr = HerdrAgent.parseList(String(lines[index])) }
                index += 1
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { continue }
            var report = poll.tabs[fields[0]] ?? RemoteTabReport()
            switch fields[1] {
            case "plain":
                report.plain = true
            case "nodir":
                report.folderMissing = true
            case "shell":
                report.started = true
                report.foreground = ForegroundProcess(isShell: true, name: "")
            case "fg" where fields.count >= 3:
                report.started = true
                let args = fields.count > 3 ? fields[3].split(separator: " ").map(String.init) : []
                // Login shells show as "-bash"; comm is cut to 15 characters on Linux, args are not.
                var name = (fields[2] as NSString).lastPathComponent
                if name.hasPrefix("-") { name.removeFirst() }
                let path = args.first ?? ""
                report.foreground = ForegroundProcess(isShell: false, name: name, arguments: args, executablePath: path.hasPrefix("/") ? path : "")
            case "dir" where fields.count >= 3:
                report.directory = fields[2...].joined(separator: "\t")
            default:
                break
            }
            poll.tabs[fields[0]] = report
        }
        return poll
    }
}

/// An agent as herdr lists it (`herdr agent list`).
public struct HerdrAgent: Equatable, Sendable {
    public enum Status: String, Sendable {
        case idle, working, blocked, done, unknown
    }
    public var paneID: String
    public var name: String
    public var status: Status
    public var title: String?
    public var directory: String?

    /// herdr's JSON (`{"result": {"agents": [...]}}`, or the bare result): unknown fields are ignored.
    public static func parseList(_ json: String) -> [HerdrAgent]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        func agents(in value: Any) -> [[String: Any]]? {
            guard let dict = value as? [String: Any] else { return nil }
            if let list = dict["agents"] as? [[String: Any]] { return list }
            if let result = dict["result"] { return agents(in: result) }
            return nil
        }
        guard let list = agents(in: object) else { return nil }
        return list.map { item in
            let label = [item["name"], item["display_agent"], item["agent"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            return HerdrAgent(
                paneID: item["pane_id"] as? String ?? "",
                name: label ?? "agent",
                status: Status(rawValue: item["agent_status"] as? String ?? "") ?? .unknown,
                title: (item["terminal_title_stripped"] as? String) ?? (item["title"] as? String),
                directory: (item["foreground_cwd"] as? String) ?? (item["cwd"] as? String)
            )
        }
    }

    /// What a tab showing herdr reports for all its agents together: a decision first, then work.
    public static func activity(_ agents: [HerdrAgent]) -> AgentActivity {
        if let blocked = agents.first(where: { $0.status == .blocked }) {
            let others = agents.filter { $0.status == .blocked }.count - 1
            return .asking("\(blocked.name) (\(blocked.paneID)) needs a decision" + (others > 0 ? ", and \(others) more" : ""))
        }
        if agents.contains(where: { $0.status == .working }) { return .working }
        return .idle
    }
}

/// What check_host found.
public struct RemoteProbe: Equatable, Sendable {
    public var os = ""
    public var shell = ""
    public var home = ""
    public var tmux: String?
    public var herdr: String?
    public var git: String?
    public var agents: [String] = []
    /// systemd's linger for the user: "yes" keeps their processes after logout on hosts that kill them.
    public var linger: String?
    public var sessions: [RemoteSession] = []

    public init() {}

    /// tmux 3.2 or later (what the tmux mode is tested with).
    public var tmuxUsable: Bool {
        guard let tmux else { return false }
        let digits = tmux.drop { !$0.isNumber }
        let parts = digits.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let major = parts.first else { return tmux.contains("master") || tmux.contains("next") }
        return major > 3 || (major == 3 && (parts.dropFirst().first ?? 0) >= 2)
    }

    public static func parse(_ output: String) -> RemoteProbe? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var probe = RemoteProbe()
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            switch fields[0] {
            case "os": probe.os = fields[1]
            case "shell": probe.shell = fields[1]
            case "home": probe.home = fields[1]
            case "tmux": probe.tmux = fields[1]
            case "herdr": probe.herdr = fields[1]
            case "git": probe.git = fields[1]
            case "agent": probe.agents.append(fields[1])
            case "linger": probe.linger = fields[1]
            case "session": if let session = RemoteSession(fields: fields) { probe.sessions.append(session) }
            default: break
            }
        }
        return probe
    }
}

/// One of Next Term's tmux sessions on a host.
public struct RemoteSession: Equatable, Sendable {
    public var name: String
    /// Clients attached right now (another Mac, or this one).
    public var attached: Int
    public var directory: String
    public var program: String

    init?(fields: [String]) {
        guard fields.count >= 5, fields[0] == "session", !fields[1].isEmpty else { return nil }
        name = fields[1]
        attached = Int(fields[2]) ?? 0
        directory = fields[3]
        program = fields[4]
    }

    public static func parseList(_ output: String) -> (sessions: [RemoteSession], herdr: [HerdrAgent]?)? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var sessions: [RemoteSession] = []
        var herdr: [HerdrAgent]?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line == RemoteShell.herdrMarker {
                if index < lines.count { herdr = HerdrAgent.parseList(String(lines[index])) }
                index += 1
                continue
            }
            if let session = RemoteSession(fields: line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)) {
                sessions.append(session)
            }
        }
        return (sessions, herdr)
    }
}

/// What host_changes found in a work tree.
public struct RemoteChanges: Equatable, Sendable {
    public var branch = ""
    /// `XY path` lines from `git status --porcelain`.
    public var files: [String] = []
    public var stat = ""
    public var diff = ""

    public static func parse(_ output: String) -> RemoteChanges? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var changes = RemoteChanges()
        var section = 0
        var stat: [Substring] = [], diff: [Substring] = []
        for line in lines {
            if line == RemoteShell.statMarker { section = 1; continue }
            if line == RemoteShell.diffMarker { section = 2; continue }
            switch section {
            case 0:
                if line.hasPrefix("## ") { changes.branch = String(line.dropFirst(3)) } else if !line.isEmpty { changes.files.append(String(line)) }
            case 1: stat.append(line)
            default: diff.append(line)
            }
        }
        changes.stat = stat.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        changes.diff = diff.joined(separator: "\n")
        return changes
    }
}
