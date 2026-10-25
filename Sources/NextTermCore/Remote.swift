import Foundation

// Connect VPS: terminal tabs on a server, over the system ssh. Pure logic here (hosts, the scripts that
// run on the host, the parsing of what they print); the app owns the processes.
//
// Security rules this file keeps:
// - Nothing typed by a user or an agent is ever spliced into a remote shell line. Every script is built
//   here from fixed text plus values quoted for POSIX sh, then sent base64-encoded (an alphabet no shell
//   reads specially) and decoded by /bin/sh on the host. See RemoteShell.command.
// - A destination can never be read by ssh as an option (no leading "-", and ssh is given "--").
// - Next Term installs nothing on a host, except Tab completion's hook where the user allowed it
//   (RemoteCompletionHook): tmux and herdr are used only if the user installed them.

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

    /// What a tab opened with this mode has: a plain shell that nothing keeps (off) once tmux or herdr was missing on
    /// the host and it fell back.
    public func shown(fellBack: Bool) -> KeepMode { fellBack ? .off : self }

    /// The tab's tooltip line: "Sessions kept: tmux", or for a tab that fell back "Sessions kept: Off (herdr wasn’t
    /// found on the host)".
    public func keptLine(fellBack: Bool) -> String {
        guard fellBack, self != .off else { return "Sessions kept: \(label)" }
        return "Sessions kept: Off (\(label) wasn’t found on the host)"
    }
}

/// Where a remote tab's connection stands: the dot on its server mark, and the note in its title.
public enum RemoteLink: String, Sendable, CaseIterable {
    case connected
    case connecting
    /// Another tab is logging in to the same host; this one goes once that login is through.
    case waiting
    /// ssh is asking in this tab: a password, a passphrase, a host key.
    case logIn = "log in"
    /// The connection dropped or could not be made: Return connects again.
    case disconnected
    /// The shell on the host ended (`exit 1`) and the tab stays to show why: nothing to reconnect.
    case ended

    public init(exited: Bool, disconnected: Bool, waiting: Bool, loginPrompt: Bool, connected: Bool) {
        if exited {
            self = .ended
        } else if disconnected {
            self = .disconnected
        } else if waiting {
            self = .waiting
        } else if loginPrompt {
            self = .logIn
        } else {
            self = connected ? .connected : .connecting
        }
    }

    /// The tab title's note, "(connecting)": nothing while the connection is simply up, or once the shell
    /// ended (the tab says why on its screen, and its status mark is the failure's).
    public var titleNote: String? { self == .connected || self == .ended ? nil : rawValue }

    /// For the tooltip and VoiceOver: "Remote: web-1 (deploy@203.0.113.5), connected".
    public var phrase: String {
        switch self {
        case .connected, .connecting, .disconnected, .ended: return rawValue
        case .waiting: return "waiting for another tab’s login"
        case .logIn: return "waiting for you to log in"
        }
    }

    /// The dot: filled when up, a ring while on its way, barred when lost or ended.
    public var isOnItsWay: Bool { self == .connecting || self == .waiting || self == .logIn }

    /// A split tab shows its weakest pane: lost (Return brings it back), ended, then on its way, the login
    /// that waits for you first.
    public static func weakest(_ links: [RemoteLink]) -> RemoteLink? {
        for link in [RemoteLink.disconnected, .ended, .logIn, .connecting, .waiting] where links.contains(link) { return link }
        return links.first
    }
}

/// A remote tab's host and connection, as its tab, the sidebar and the overflow menu show them.
public struct RemoteMark: Equatable, Sendable {
    public var host: String
    public var destination: String
    public var link: RemoteLink

    public init(host: String, destination: String, link: RemoteLink) {
        self.host = host
        self.destination = destination
        self.link = link
    }

    /// "web-1 (deploy@203.0.113.5)", or "web-1" alone when the destination is an ssh alias of that name.
    public var place: String { destination == host ? host : "\(host) (\(destination))" }

    /// "Remote: web-1 (deploy@203.0.113.5), connected"
    public var summary: String { "Remote: \(place), \(link.phrase)" }

    /// A split tab's mark: its weakest pane's, so a pane that lost its connection is not hidden, and the
    /// host named is the one whose connection it shows (the focused pane's, when that one is as weak).
    public static func split(focused: RemoteMark?, panes: [RemoteMark]) -> RemoteMark? {
        guard let weakest = RemoteLink.weakest(panes.map(\.link)) else { return nil }
        if let focused, focused.link == weakest { return focused }
        return panes.first { $0.link == weakest }
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
        // host:2222 is not a destination ssh understands (IPv6 addresses have several colons).
        let hostPart = destination.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        if hostPart.filter({ $0 == ":" }).count == 1 { return "Put the port in the Port field, not after a colon." }
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
    /// Where the host pointed when the tab was saved: a host re-pointed since is not followed.
    public var destination: String?
    public var port: Int?
    public var directory: String
    public var session: String
    public var keep: KeepMode
    /// The project window it was in, if any.
    public var project: String?
    public var title: String?
    /// A herdr tab's herdr session (`herdr --session`); nil for herdr's default, and in a record saved before tabs had one.
    public var herdrSession: String?

    public init(hostID: String, destination: String? = nil, port: Int? = nil, directory: String, session: String, keep: KeepMode,
                project: String? = nil, title: String? = nil, herdrSession: String? = nil) {
        self.hostID = hostID
        self.destination = destination
        self.port = port
        self.directory = directory
        self.session = session
        self.keep = keep
        self.project = project
        self.title = title
        self.herdrSession = herdrSession
    }
}

// MARK: - ssh command lines

public enum SSHArguments {
    /// Options for every connection to a host. One master connection per host carries every tab and
    /// every background check (ControlMaster). The master stays 10 minutes after its last use.
    /// ClearAllForwardings: Next Term forwards nothing (not its MCP socket, not its IDE ports), and a
    /// forward in the user's ssh config would clash with their own sessions.
    public static func common(controlPath: String, port: Int?, configFile: String? = nil, master: String = "auto") -> [String] {
        var args: [String] = configFile.map { ["-F", $0] } ?? []
        args += [
            "-o", "ControlMaster=\(master)",
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

    /// A terminal tab: a pty on the host running `command`. Host keys: ssh asks, in the tab, about a new
    /// one and refuses a changed one, whatever the user's config says (accept-new and no would take keys
    /// with nobody looking). The option reaches ProxyJump hops through `configFile` (see `configText`).
    /// No escape character, so text pasted into an agent (or typed by MCP) that starts a line with "~."
    /// cannot cut the connection.
    public static func tab(_ host: RemoteHost, controlPath: String, configFile: String? = nil, command: String) -> [String] {
        common(controlPath: controlPath, port: host.port, configFile: configFile)
            + ["-t", "-o", "StrictHostKeyChecking=ask", "-o", "EscapeChar=none", "--", host.destination, command]
    }

    /// A background command (status checks, git): only ever a session on a master a tab opened, in front
    /// of the user. It never logs in itself, so it can neither prompt nor meet a host key: with no master
    /// it fails, and if the master refuses the session (sshd's MaxSessions) the direct connection ssh
    /// would fall back to goes nowhere (ProxyCommand false).
    public static func exec(_ host: RemoteHost, controlPath: String, configFile: String? = nil, command: String) -> [String] {
        common(controlPath: controlPath, port: host.port, configFile: configFile, master: "no")
            + ["-T", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false", "--", host.destination, command]
    }

    /// Next Term's ssh config, given with -F: the user's own config, then the system's, as ssh itself
    /// reads them (the first value wins), after one rule. ssh passes -F to ProxyJump hops, so they ask
    /// about host keys too. (A hop written as `ProxyCommand ssh …` gets no -F and follows the user's
    /// config; the target host is still asked about.)
    public static let configText = """
        # Written by Next Term for its remote tabs; your own config is included below, unchanged.
        Host *
          StrictHostKeyChecking ask
        Include ~/.ssh/config
        Include /etc/ssh/ssh_config

        """

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
    /// The changes script's last line: without it, the connection cut what the host printed.
    static let endMarker = "@@NEXTTERM-END@@"

    /// Where Next Term keeps its few files on the host (tab pid files, the tmux config).
    static let cacheDir = "\"$HOME/.cache/next-term\""

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
    /// `token` is new for every connection: written beside the pid once the host runs this script (past
    /// ssh's login), it is how this tab, and only it, learns that its own connection is up.
    /// `completionHook`: the user allowed Tab completion's hook on this host (RemoteCompletionHook), so a plain
    /// or tmux tab starts its shell through the hook's start command while the hook's files are there.
    /// `herdrSession`: a herdr tab's named herdr session, opened only while herdr lists it, so a restored tab never makes
    /// one by its name; nil for herdr's default.
    public static func tabScript(keep: KeepMode, directory: String, session: String, tabID: String, token: String = "",
                                 completionHook: Bool = false, herdrSession: String? = nil) -> String {
        // K: this tab's files on the host. K.plain: tmux or herdr was missing, so this is a plain shell (it holds why,
        // when a copy was there but did not run). K.nodir: the folder was not there.
        var lines = [
            "C=\(cacheDir)",
            "K=\"$C/tabs/\(safeName(tabID))\"",
            "mkdir -p \"$C/tabs\" 2>/dev/null; rm -f \"$K.plain\" \"$K.nodir\"",
            "if ! cd \(folder(directory)) 2>/dev/null; then",
            "  : > \"$K.nodir\" 2>/dev/null",
            "  printf 'Next Term: %s is not a folder on this host; this tab opened in your home folder.\\r\\n' \(quote(directory))",
            "  cd",
            "fi",
            // The pid and token; where ~/.cache cannot be written (root-owned, read-only home, full disk), in
            // a private folder of the user's in /tmp instead, which the status check reads too.
            "if ! printf '%s %s\\n' \"$$\" \(quote(safeName(token))) > \"$K\" 2>/dev/null; then",
            "  A=/tmp/nt-$(id -u)-tabs; mkdir -p \"$A\" 2>/dev/null; chmod 700 \"$A\" 2>/dev/null",
            "  [ -O \"$A\" ] && printf '%s %s\\n' \"$$\" \(quote(safeName(token))) > \"$A/\(safeName(tabID))\" 2>/dev/null",
            "fi",
        ]
        switch keep {
        case .off:
            lines.append(completionHook ? RemoteCompletionHook.offLaunch : plainShell(nil))
        case .tmux:
            lines += [
                tmuxFinder(checked: true),
                "if [ -z \"$T\" ]; then",
                "  : > \"$K.plain\" 2>/dev/null",
                plainShell("tmux is not installed on this host: this is a plain shell, and what runs in it stops if the connection drops."),
                "fi",
                "printf '%s\\n' \(quote(completionHook ? RemoteCompletionHook.tmuxConfig : tmuxConfig)) > \"$C/tmux.conf\" 2>/dev/null",
                completionHook ? RemoteCompletionHook.tmuxLaunch(session: session)
                    : "exec \"$T\" -L nextterm -f \"$C/tmux.conf\" new-session -A -s \(quote(safeName(session))) -c \"$PWD\"",
            ]
        case .herdr:
            // herdr's own socket variables (its running server's, or the login shell's) are exported by the finder, so
            // the tab attaches to the session the user has. A copy that answered --version is what runs.
            lines += [
                herdrTabFinder(),
                "if [ -z \"$H\" ]; then",
                herdrMissingNote,
                "  exec \"${SHELL:-/bin/sh}\" -l",
                "fi",
            ]
            if let herdrSession {
                // A named session: herdr's own socket variables name the default session's, so they go.
                lines.append(herdrSessionCheck(herdrSession))
                lines.append("unset HERDR_SOCKET_PATH HERDR_SESSION; exec \"$H\" --session \(quote(herdrSession))")
            } else {
                lines.append("exec \"$H\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A herdr tab's named session is opened only when `herdr session list --json` lists it: else (removed since the tab
    /// was saved, or a herdr without named sessions) the tab is a plain shell that says why, as for a missing herdr, and
    /// K.plain holds the reason for the status check. A name outside herdr's rules is never listed, and a herdr that
    /// gives no list within 5 seconds lists none.
    static func herdrSessionCheck(_ name: String) -> String {
        let stops = "so this tab is a plain shell: what runs in it stops if the connection drops."
        let listed = HerdrTarget.isSession(name)
            ? "printf '%s' \"$nt_sl\" | tr -d '\\n\\r' | grep -Eq \(quote("\"name\"[[:space:]]*:[[:space:]]*\"\(name)\""))" : "false"
        let shown = String(name.unicodeScalars.filter { !ShellQuote.isControl($0) }.map(Character.init).prefix(64))
        return [
            "nt_sl=$(nt_hd 5 \"$H\" session list --json 2>&1 </dev/null); nt_slx=$?",
            "if [ \"$nt_slx\" -ne 0 ] || ! \(listed); then",
            "  printf 'herdr on this host lists no session %s\\n' \(quote(shown)) > \"$K.plain\" 2>/dev/null",
            "  printf '%s\\r\\n' \(quote("Next Term: herdr on this host lists no session “\(shown)” (it may have been removed, or this herdr has no named sessions), " + stops))",
            "  exec \"${SHELL:-/bin/sh}\" -l",
            "fi",
        ].joined(separator: "\n")
    }

    /// One status check for every tab on a host: what runs in front of each tab's shell, its folder, and
    /// (if a tab uses herdr) herdr's list of agents. `herdr`: a tab was opened with herdr, even one that fell back to a
    /// plain shell (checked as one), which then learns when herdr is there: herdr's default session is asked.
    public static func pollScript(tabs: [(id: String, keep: KeepMode, session: String)], herdr: Bool = false) -> String {
        let asked = herdr || tabs.contains { $0.keep == .herdr }
        return pollScript(tabs: tabs, herdrSessions: asked ? [HerdrPollSession(name: nil)] : [])
    }

    /// The same, asking each of `herdrSessions` (HerdrPollSession.plan: the herdr sessions the host's tabs show, at most
    /// `HerdrPollSession.perPoll`) for its agents, one section each.
    public static func pollScript(tabs: [(id: String, keep: KeepMode, session: String)], herdrSessions: [HerdrPollSession]) -> String {
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
            "  a=$(ps -o args= -p \"$g\" 2>/dev/null)",
            "  if [ -z \"$c\" ] && [ -r \"/proc/$g/comm\" ]; then c=$(cat \"/proc/$g/comm\"); a=$(tr '\\000' ' ' < \"/proc/$g/cmdline\" 2>/dev/null); fi",
            "  c=$(nt_clean \"$c\" 64); a=$(nt_clean \"$a\" 400)",
            "  if [ -z \"$c\" ]; then echo '?'; else printf 'fg\\t%s\\t%s\\n' \"$c\" \"$a\"; fi",
            "}",
            // What a host reports goes on one line of its own: no control characters (a newline in a
            // folder or command line could otherwise forge another tab's line), and a bounded length.
            "nt_clean() { printf '%s' \"$1\" | tr -d '\\001-\\037\\177' | cut -c \"1-$2\"; }",
            // Jobs the tab's shell holds besides the one in front: suspended or in the background.
            "nt_jobs() {",
            "  ps -A -o ppid= -o pgid= -o stat= -o comm= 2>/dev/null | awk -v p=\"$1\" -v g=\"$2\" '$1 == p && $2 != g { n++; s = s $4 ($3 ~ /T/ ? \" (suspended)\" : \" (running)\") \";\" } END { if (n) printf \"%d\\t%s\", n, s }' | tr -d '\\001-\\010\\012-\\037\\177'",
            "}",
            "printf '\\n%s\\n' \(quote(marker))",
        ]
        for tab in tabs {
            let id = safeName(tab.id)
            // The pid file: "<shell pid> <this connection's token>".
            lines.append("set -- $(cat \"$C/tabs/\(id)\" 2>/dev/null); [ -n \"$1\" ] || { A=/tmp/nt-$(id -u)-tabs; [ -O \"$A\" ] && set -- $(cat \"$A/\(id)\" 2>/dev/null); }")
            lines.append("s=$1; t=$(printf '%s' \"$2\" | tr -cd '0-9A-Za-z_-'); p=$s; d=")
            switch tab.keep {
            case .herdr:
                break // herdr reports its agents itself; the pid file shows the tab got past ssh's login
            case .tmux:
                let pane = quote("=" + safeName(tab.session) + ":")
                lines += [
                    "if [ -n \"$T\" ]; then",
                    "  q=$(\"$T\" -L nextterm display-message -p -t \(pane) '#{pane_pid}' 2>/dev/null)",
                    "  [ -n \"$q\" ] && p=$q",
                    "  d=$(\"$T\" -L nextterm display-message -p -t \(pane) '#{pane_current_path}' 2>/dev/null)",
                    // The pane in one of tmux's modes (copy mode, which the mouse wheel enters): keys go to tmux.
                    "  m=$(\"$T\" -L nextterm display-message -p -t \(pane) '#{pane_in_mode}' 2>/dev/null)",
                    "  [ \"$m\" = 1 ] && printf '%s\\tmode\\n' \(quote(id))",
                    "fi",
                ]
            case .off:
                lines.append("[ -n \"$p\" ] && d=$(readlink \"/proc/$p/cwd\" 2>/dev/null)")
            }
            lines += [
                "[ -n \"$t\" ] && printf '%s\\tup\\t%s\\n' \(quote(id)) \"$t\"",
                "printf '%s\\t' \(quote(id)); nt_fg \"$p\"",
                "d=$(nt_clean \"$d\" 1024); [ -n \"$d\" ] && printf '%s\\tdir\\t%s\\n' \(quote(id)) \"$d\"",
                "if [ -n \"$p\" ] && [ -n \"$g\" ]; then j=$(nt_jobs \"$p\" \"$g\"); [ -n \"$j\" ] && printf '%s\\tjobs\\t%s\\n' \(quote(id)) \"$j\"; fi",
                // Why it fell back, when a copy was there but did not run (one line, cut).
                "[ -e \"$C/tabs/\(id).plain\" ] && printf '%s\\tplain\\t%s\\n' \(quote(id)) \"$(nt_clean \"$(head -n 1 \"$C/tabs/\(id).plain\" 2>/dev/null)\" 300)\"",
                "[ -e \"$C/tabs/\(id).nodir\" ] && printf '%s\\tnodir\\n' \(quote(id))",
            ]
        }
        if !herdrSessions.isEmpty {
            lines.append(findHerdr)
            for session in herdrSessions {
                let section = herdrSection(session: session.name, wantsFocus: session.wantsFocus)
                guard session.overview else {
                    lines.append(section)
                    continue
                }
                // No herdr tab on this connection: only a herdr that runs, or one a tab found before.
                lines += ["if [ -n \"$H\" ] && { [ \"$HW\" = running ] || [ -f \"$C/herdr\" ]; }; then", section, "fi"]
            }
        }
        return lines.joined(separator: "\n")
    }

    /// An `agent` line for each agent a tab on the host could start, by the command that starts it. OpenCode is also
    /// looked for where its installer (`~/.opencode/bin`), Bun, npm and Linuxbrew put it: a command over ssh doesn't get
    /// the PATH those add at the end of .bashrc, past the guard that stops a shell that is not interactive, but a tab
    /// does. OpenCode 2's `opencode2` counts when there is no `opencode`.
    static let agentLines = """
        for a in claude codex gemini; do command -v "$a" >/dev/null 2>&1 && printf 'agent\\t%s\\n' "$a"; done
        O=
        for n in opencode opencode2; do
          if command -v "$n" >/dev/null 2>&1; then O=$n; break; fi
          for d in "$HOME/.opencode/bin" "$HOME/.bun/bin" "$HOME/.npm-global/bin" /home/linuxbrew/.linuxbrew/bin; do
            if [ -x "$d/$n" ]; then O=$n; break 2; fi
          done
        done
        [ -n "$O" ] && printf 'agent\\t%s\\n' "$O"
        """

    /// What the host has: for check_host and the sheet. herdr is looked for as a tab looks (the login shell's PATH
    /// too), and the cache the status checks read is written again.
    public static var probeScript: String { """
        C=\(cacheDir)
        printf '\\n%s\\n' \(quote(marker))
        printf 'os\\t%s\\n' "$(uname -sm 2>/dev/null)"
        printf 'shell\\t%s\\n' "${SHELL:-}"
        printf 'home\\t%s\\n' "$HOME"
        \(findTmux)
        [ -n "$T" ] && printf 'tmux\\t%s\\n' "$("$T" -V 2>/dev/null)"
        \(herdrTabFinder())
        if [ -n "$H" ]; then
          v=$("$H" --version 2>/dev/null </dev/null | head -n 1 | tr -d '\\000-\\037\\177' | cut -c 1-200)
          printf 'herdr\\t%s\\t%s\\t%s\\n' "$v" "$(printf '%s' "$H" | tr -d '\\000-\\037\\177' | cut -c 1-1024)" "$HW"
        else
          printf 'herdr-missing\\t%s\\n' "${nt_bad:+$nt_bad did not run (herdr --version said: $nt_said)}"
        fi
        command -v git >/dev/null 2>&1 && printf 'git\\t%s\\n' "$(git --version 2>/dev/null)"
        \(agentLines)
        command -v loginctl >/dev/null 2>&1 && printf 'linger\\t%s\\n' "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
        [ -n "$T" ] && "$T" -L nextterm list-sessions -F 'session\t#{session_name}\t#{session_attached}\t#{pane_current_path}\t#{pane_current_command}' 2>/dev/null
        true
        """
    }

    /// The kept sessions on a host: Next Term's tmux sessions, herdr's agents in its default session, herdr's sessions
    /// (`herdr-sessions<TAB>` and what `herdr session list --json` said, on one line), and the agents of up to
    /// `herdrSessionsListed` of its other running sessions, a section each. Their names are taken from herdr's JSON only
    /// as herdr's rule for a name allows (letters, digits, `_` and `-`), so splitting the list on spaces is safe.
    public static let sessionsScript = """
        C=\(cacheDir)
        printf '\\n%s\\n' \(quote(marker))
        \(findTmux)
        [ -n "$T" ] && "$T" -L nextterm list-sessions -F 'session\t#{session_name}\t#{session_attached}\t#{pane_current_path}\t#{pane_current_command}' 2>/dev/null
        \(findHerdr)
        \(herdrSection)
        if [ -n "$H" ]; then
          nt_sl=$(nt_hd \(herdrCallLimit) "$H" session list --json 2>/dev/null </dev/null)
          printf 'herdr-sessions\t'; printf '%s' "$nt_sl" | tr '\\n\\r\\t' '   ' | tr -d '\\000-\\037\\177' | head -c 200000; echo
          nt_names=$(printf '%s' "$nt_sl" | tr '{}\\n' '\\n\\n ' | grep -E '"running"[[:space:]]*:[[:space:]]*true' | grep -vE '"default"[[:space:]]*:[[:space:]]*true' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9_-]\\{1,64\\}\\)".*/\\1/p' | head -n \(herdrSessionsListed))
          for nt_n in $nt_names; do
        \(herdrSection(word: "\"$nt_n\"", wantsFocus: false))
          done
        fi
        true
        """

    /// The most of herdr's other running sessions whose agents sessionsScript lists.
    public static let herdrSessionsListed = 8

    /// Ends one of Next Term's tmux sessions (End Session on close, MCP close_tab with force).
    public static func killSessionScript(session: String) -> String {
        "\(findTmux)\n[ -n \"$T\" ] && \"$T\" -L nextterm kill-session -t \(quote("=" + safeName(session))) 2>/dev/null\nprintf '\\n%s\\n' \(quote(marker))"
    }

    /// What changed in a git work tree on the host: status, a diffstat, and the diff (cut at `maxBytes`).
    /// Never takes git's index lock, and no fsmonitor hook runs.
    public static func changesScript(directory: String, maxBytes: Int) -> String {
        """
        cd \(folder(directory)) 2>/dev/null || { echo 'No such folder on the host.' >&2; exit 3; }
        G='git -c core.fsmonitor=false -c core.pager=cat'
        export GIT_OPTIONAL_LOCKS=0
        $G rev-parse --show-toplevel >/dev/null 2>&1 || { echo 'Not a git work tree.' >&2; exit 4; }
        printf '\\n%s\\n' \(quote(marker))
        $G status --porcelain=v1 -b 2>/dev/null
        printf '%s\\n' \(quote(statMarker))
        B=HEAD; $G rev-parse --verify -q HEAD >/dev/null || B=$($G hash-object -t tree /dev/null)
        $G diff "$B" --stat --no-color 2>/dev/null
        printf '%s\\n' \(quote(diffMarker))
        $G diff "$B" --no-color --no-ext-diff 2>/dev/null | head -c \(max(0, maxBytes))
        printf '\\n%s\\n' \(quote(endMarker))
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
    /// The marker is printed on a line of its own, after a newline, but rc-file noise before it may lack
    /// one, and lines may end in CRLF: split on "\n" alone (a Character split keeps "\r\n" whole) and
    /// take the first line that ends with the marker.
    public static func payload(_ output: String, after mark: String = marker) -> [Substring]? {
        let lines = output.components(separatedBy: "\n").map { line -> Substring in
            let cut = line.hasSuffix("\r") ? line.dropLast() : Substring(line)
            return cut
        }
        guard let start = lines.firstIndex(where: { $0.hasSuffix(mark) }) else { return nil }
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
    /// The connection token the tab's script wrote: equal to the tab's own only for its current connection.
    public var token: String?
    /// Jobs the shell holds besides the one in front (suspended or in the background).
    public var jobs = 0
    public var jobSummary = ""
    /// tmux or herdr was missing: the tab is a plain shell, kept by nothing.
    public var plain = false
    /// Why, when a copy was there but did not run ("herdr at /x did not run (…)"); nil when none was found.
    public var plainReason: String?
    /// The folder asked for was not there; the tab opened in the home folder.
    public var folderMissing = false
    /// A tmux tab's pane is in one of tmux's modes (copy mode): what is typed goes to tmux, not to the shell.
    public var inMode = false
}

public struct RemotePoll: Equatable, Sendable {
    public var tabs: [String: RemoteTabReport] = [:]
    /// What herdr said, when a tab on this host was opened with herdr: its agents, or why there are none, by herdr session
    /// ("" for herdr's default, and for a section from before sessions, which named none).
    public var herdrSessions: [String: HerdrReport] = [:]
    /// herdr's default session's report.
    public var herdr: HerdrReport? { herdrSessions[""] }

    public init() {}

    public static func parse(_ output: String) -> RemotePoll? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var poll = RemotePoll()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line == RemoteShell.herdrMarker {
                let (report, consumed) = HerdrReport.parse(section: lines[index...])
                poll.herdrSessions[report.session ?? ""] = report
                index += consumed
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { continue }
            var report = poll.tabs[fields[0]] ?? RemoteTabReport()
            switch fields[1] {
            case "up" where fields.count >= 3:
                report.token = fields[2]
            case "jobs" where fields.count >= 3:
                report.jobs = Int(fields[2]) ?? 0
                report.jobSummary = fields.count > 3 ? fields[3].split(separator: ";").map(String.init).joined(separator: "\n") : ""
            case "plain":
                report.plain = true
                if fields.count >= 3, !fields[2].isEmpty { report.plainReason = fields[2...].joined(separator: " ") }
            case "nodir":
                report.folderMissing = true
            case "mode":
                report.inMode = true
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

/// What check_host found.
public struct RemoteProbe: Equatable, Sendable {
    public var os = ""
    public var shell = ""
    public var home = ""
    public var tmux: String?
    /// herdr's version ("herdr 0.9.4"), where it is, and how it was found (see HerdrReport.how).
    public var herdr: String?
    public var herdrPath: String?
    public var herdrHow: String?
    /// No herdr was found; `herdrBroken` names a copy that was there but did not run.
    public var herdrMissing = false
    public var herdrBroken: String?
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

    /// How the finder found herdr, in words for check_host.
    public static func foundHow(_ how: String?) -> String? {
        switch how {
        case "running": return "the executable of your running herdr server"
        case "login": return "on your login shell’s PATH"
        case "path": return "on /bin/sh’s PATH"
        case "known": return "in one of herdr’s usual install folders"
        case "cache": return "where a tab found it before"
        default: return nil
        }
    }

    /// check_host's line on herdr: "herdr 0.9.4 at /home/u/.local/bin/herdr (found on your login shell’s PATH)", or
    /// where Next Term looked; nil when the host said nothing of herdr (an older Next Term's check).
    public var herdrSummary: String? {
        if let herdr {
            let at = herdrPath.map { " at \($0)" } ?? ""
            let how = Self.foundHow(herdrHow).map { " (found \($0))" } ?? ""
            return (herdr.isEmpty ? "herdr" : herdr) + at + how
        }
        guard herdrMissing else { return nil }
        let broken = herdrBroken.map { "\($0); " } ?? ""
        return broken + "herdr not found: looked on your login shell’s PATH and /bin/sh’s PATH, and in ~/.local/bin, ~/bin, "
            + "~/.cargo/bin and the Homebrew, mise, asdf and Nix folders"
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
            case "herdr":
                probe.herdr = fields[1]
                probe.herdrPath = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
                probe.herdrHow = fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil
            case "herdr-missing":
                probe.herdrMissing = true
                probe.herdrBroken = fields[1].isEmpty ? nil : fields[1]
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

    /// sessionsScript's answer: the tmux sessions, herdr's default session's report, herdr's sessions (nil when it listed
    /// none: herdr is missing, or has no named sessions), and the reports of the other running sessions it asked, by name.
    public static func parseList(_ output: String)
        -> (sessions: [RemoteSession], herdr: HerdrReport?, herdrSessions: [HerdrSession]?, herdrReports: [String: HerdrReport])? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var sessions: [RemoteSession] = []
        var reports: [String: HerdrReport] = [:]
        var herdrSessions: [HerdrSession]?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line == RemoteShell.herdrMarker {
                let (report, consumed) = HerdrReport.parse(section: lines[index...])
                reports[report.session ?? ""] = report
                index += consumed
                continue
            }
            if line.hasPrefix("herdr-sessions\t") {
                herdrSessions = HerdrSession.parse(String(line.dropFirst("herdr-sessions\t".count)))
                continue
            }
            if let session = RemoteSession(fields: line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)) {
                sessions.append(session)
            }
        }
        let named = reports.filter { !$0.key.isEmpty }
        return (sessions, reports[""], herdrSessions, named)
    }
}

/// What host_changes found in a work tree.
public struct RemoteChanges: Equatable, Sendable {
    public var branch = ""
    /// `XY path` lines from `git status --porcelain`.
    public var files: [String] = []
    public var stat = ""
    /// The diff as the host sent it, carriage returns and all: `head -c` counted them. host_changes shows it through
    /// `shownDiff`, which masks it, cuts it and drops each line's carriage return.
    public var diff = ""
    /// The script's end came: the connection cut nothing (its 8 MB cap, a timeout or a drop cuts anywhere).
    public var ended = false

    public static func parse(_ output: String) -> RemoteChanges? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        var changes = RemoteChanges()
        var inStat = false
        var status: [Substring] = [], stat: [Substring] = []
        var diffStart: Int?
        for (index, line) in lines.enumerated() {
            if line == RemoteShell.statMarker { inStat = true; continue }
            if line == RemoteShell.diffMarker { diffStart = index + 1; break }
            if inStat { stat.append(line) } else { status.append(line) }
        }
        if let diffStart {
            // The diff's lines as the output has them, before payload dropped their carriage returns.
            let text = lastLines(lines.count - diffStart, of: output)
            let end = Array("\n\(RemoteShell.endMarker)\n".utf8)
            changes.ended = text.utf8.count >= end.count && text.utf8.suffix(end.count).elementsEqual(end)
            // A connection cut inside the end line leaves its start, which is no part of the diff.
            let dropped = changes.ended ? end.count : startOfEnd(end, in: text)
            changes.diff = dropped == 0 ? text : String(decoding: text.utf8.dropLast(dropped), as: UTF8.self)
        } else if inStat {
            if !stat.isEmpty { stat.removeLast() } // the line the connection was cut in
        } else if !status.isEmpty {
            status.removeLast()
        }
        for line in status {
            if line.hasPrefix("## ") { changes.branch = String(line.dropFirst(3)) } else if !line.isEmpty { changes.files.append(String(line)) }
        }
        changes.stat = stat.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return changes
    }

    /// The last `count` of the lines `components(separatedBy: "\n")` would give, joined again: what follows the
    /// `count`th line feed from the end. One pass back over the bytes, with no copy of the lines.
    static func lastLines(_ count: Int, of output: String) -> String {
        guard count > 0 else { return "" }
        let bytes = output.utf8
        var start = bytes.endIndex
        var feeds = 0
        while start > bytes.startIndex {
            let before = bytes.index(before: start)
            if bytes[before] == 0x0A {
                feeds += 1
                if feeds == count { break }
            }
            start = before
        }
        return String(output[start...])
    }

    /// How many bytes at the end of `text` are the start of `end` (none of it: 0, all of it: not asked).
    static func startOfEnd(_ end: [UInt8], in text: String) -> Int {
        let bytes = text.utf8
        for length in stride(from: end.count - 1, through: 1, by: -1) where bytes.count >= length {
            if bytes.suffix(length).elementsEqual(end.prefix(length)) { return length }
        }
        return 0
    }
}
