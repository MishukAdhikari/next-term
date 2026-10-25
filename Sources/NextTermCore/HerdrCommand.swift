import Foundation

/// The herdr commands Next Term runs, and nothing else: data here, rendered as a script for a host (Remote.swift's rule:
/// fixed text and quoted values, sent base64) or as argument lists for herdr on this Mac, which no shell reads. Each one
/// tries herdr's current verb first and, when herdr answers that it lacks it (HerdrResult.saysUnsupported), the verb an
/// older herdr has, in the same run: never by herdr's version string. Next Term never starts, stops, updates or installs
/// herdr, never ends one of its agents, and never makes a workspace, tab, pane or session.
///
/// Text for an agent never sits on this Mac's command lines: the script reads it from its stdin (`T=$(cat)`), and the
/// argument lists take it as one element. On the host it is herdr's argument while herdr runs.
///
/// herdr on this Mac also reaches the machines saved in it (`herdr --machine <id> agent …`, over herdr's own SSH
/// connection): only its agent commands, only in the argument lists, never with `--session`. Its list of machines is
/// only read (`machine list --json`), never changed.
public enum HerdrCommand: Equatable, Sendable {
    /// `agent list`, or `pane list` before herdr 0.5.10.
    case list
    /// `tab list`: which tab has herdr's focus.
    case tabs
    /// `session list --json`.
    case sessions
    /// A pane's text: `agent read`, else `pane read`, else `pane read` without a source (herdr before 0.7.5). `lines` is
    /// at most `maxLines`.
    case read(pane: String, source: ReadSource, lines: Int?)
    /// Text and Return, as one prompt: `agent prompt` (which herdr refuses while the agent waits on a decision), else
    /// `pane send-text` then `pane send-keys … enter`. The text comes on stdin.
    case prompt(pane: String)
    /// Text without Return: `pane send-text`. The text comes on stdin.
    case text(pane: String)
    /// Keys, as MCP's press_keys names them (HerdrKeys maps them): `agent send-keys`, else `pane send-keys`. All of one
    /// call's keys go in one command, which herdr checks whole before it writes any.
    case keys(pane: String, [String])
    /// herdr's view to the pane: `agent focus`, else (herdr before 0.7.5) `tab focus` of its tab, which moves to the tab
    /// only; with no tab id, nothing older is tried.
    case focus(pane: String, tab: String?)
    /// `--version`: which herdr it is, to say so when it lacks a verb.
    case version
    /// Why herdr gives the agent its state (`agent explain --json`, herdr 0.6.9 and later): the manifest its detection
    /// used, the rule that matched and any fallback. Nothing older is tried.
    case explain(pane: String)
    /// The machines saved in herdr (`machine list --json`, herdr 0.9.0 and later), read only. Not a session's: it never
    /// takes `--session`.
    case machines

    /// What `read` reads, in herdr's words.
    public enum ReadSource: String, Sendable {
        /// What the pane shows now.
        case visible
        /// Its recent output, wrapped as shown.
        case recent
        /// Its recent output with soft wraps joined.
        case recentUnwrapped = "recent-unwrapped"
    }

    /// The most lines one read asks for.
    public static let maxLines = 2000
    /// The most text one prompt carries.
    public static let maxTextBytes = 64 * 1024

    /// The verbs herdr is ever asked, besides showing its own screen in a tab (bare, or with `--session`). A test walks
    /// every command's rendering against this list.
    public static let allowed: [[String]] = [
        ["--version"], ["agent", "list"], ["agent", "read"], ["agent", "prompt"], ["agent", "send-keys"], ["agent", "focus"],
        ["agent", "explain"], ["pane", "list"], ["pane", "read"], ["pane", "send-text"], ["pane", "send-keys"],
        ["tab", "list"], ["tab", "focus"], ["session", "list"], ["machine", "list"],
    ]

    /// The verbs that may go to one of herdr's saved machines (`--machine`): its agent commands, and no other.
    public static let allowedOnMachine: [[String]] = [
        ["agent", "list"], ["agent", "read"], ["agent", "prompt"], ["agent", "send-keys"], ["agent", "focus"], ["agent", "explain"],
    ]

    /// Stands for the text (stdin) in `attempts`.
    static let textMark = "$T"

    /// herdr takes these words for its own wherever they stand on its command line, before any verb reads them: text
    /// that is one of them (or starts with one that has `=`) would not reach the agent.
    static let globalWords = ["--handoff", "--session", "--remote", "--remote-keybindings"]
    static let globalPrefixes = ["--session=", "--remote=", "--remote-keybindings="]

    /// Why text cannot go to one of herdr's agents, or nil: over `maxTextBytes`, one of herdr's own global options,
    /// or holding a stored key's value, which on a host would be herdr's argument while herdr runs, where others there
    /// can see it in `ps`.
    public static func textRefusal(_ text: String, mask: SecretMask = .current) -> String? {
        if text.utf8.count > maxTextBytes { return "The text is longer than 64 KB; send it in parts. Nothing was sent." }
        if let word = globalWords.first(where: { $0 == text }) ?? globalPrefixes.first(where: { text.hasPrefix($0) }) {
            return "herdr takes \(word) for one of its own options wherever it stands, so that text would not reach the agent. Nothing was sent."
        }
        if !mask.isEmpty, mask.mask(text) != text {
            return "The text holds a stored key's value: for a herdr agent it would be herdr's argument on the host while it runs, where others can see it in ps. run_with_secrets runs a command with keys in a tab instead. Nothing was sent."
        }
        return nil
    }

    /// The command's first verb, as its answer names it ("agent read").
    public var verb: String {
        let call = attempts[0][0]
        return call.prefix(call.first == "--version" ? 1 : 2).joined(separator: " ")
    }

    /// The verb of one call `argv` made ("tab focus"): what follows the executable, and `--session` or `--machine` with
    /// its value.
    public static func verb(of call: [String]) -> String {
        var words = call.dropFirst()
        if let first = words.first, first == "--session" || first == "--machine" { words = words.dropFirst(2) }
        return words.prefix(words.first == "--version" ? 1 : 2).joined(separator: " ")
    }

    /// herdr answers it with text, not JSON: a pane's, or its version.
    public var readsText: Bool {
        switch self {
        case .read, .version: return true
        default: return false
        }
    }

    /// It sends text, which comes on stdin.
    public var takesText: Bool {
        switch self {
        case .prompt, .text: return true
        default: return false
        }
    }

    /// It changes what herdr shows (a prompt, keys, its view), so the tab checks again soon after.
    public var changesHerdr: Bool {
        switch self {
        case .prompt, .text, .keys, .focus: return true
        case .list, .tabs, .sessions, .read, .version, .explain, .machines: return false
        }
    }

    /// It may go to one of herdr's saved machines: one of its agent commands.
    public var goesToMachines: Bool {
        switch self {
        case .list, .read, .prompt, .keys, .focus, .explain: return true
        case .tabs, .sessions, .text, .version, .machines: return false
        }
    }

    /// The herdr calls, by attempt: each attempt is one call or more (a prompt's older form is text, then Return), tried
    /// when every call before it said this herdr lacks its verb. `textMark` stands for the text.
    var attempts: [[[String]]] {
        switch self {
        case .list:
            return [[["agent", "list"]], [["pane", "list"]]]
        case .tabs:
            return [[["tab", "list"]]]
        case .sessions:
            return [[["session", "list", "--json"]]]
        case let .read(pane, source, lines):
            let count = lines.map { ["--lines", String(min(Self.maxLines, max(1, $0)))] } ?? []
            return [
                [["agent", "read", pane, "--source", source.rawValue] + count],
                [["pane", "read", pane, "--source", source.rawValue] + count],
                [["pane", "read", pane]],
            ]
        case .prompt(let pane):
            // herdr reads the text by its place, so text that starts with "-" is text (a `--` would be the text itself).
            // Built so, and with textRefusal keeping herdr's own options out, `agent prompt` has no usage error to give;
            // should it give one, the older form, which types and presses Return with no check for a decision, is not
            // tried after it (HerdrResult.usage).
            return [
                [["agent", "prompt", pane, Self.textMark]],
                [["pane", "send-text", pane, Self.textMark], ["pane", "send-keys", pane, "enter"]],
            ]
        case .text(let pane):
            return [[["pane", "send-text", pane, Self.textMark]]]
        case let .keys(pane, names):
            let keys = names.compactMap(HerdrKeys.map)
            return [[["agent", "send-keys", pane] + keys], [["pane", "send-keys", pane] + keys]]
        case let .focus(pane, tab):
            guard let tab else { return [[["agent", "focus", pane]]] }
            return [[["agent", "focus", pane]], [["tab", "focus", tab]]]
        case .version:
            return [[["--version"]]]
        case .explain(let pane):
            return [[["agent", "explain", pane, "--json"]]]
        case .machines:
            return [[["machine", "list", "--json"]]]
        }
    }

    /// Why the command cannot be built, or nil: an id, a session name, a machine id or a key outside herdr's rules
    /// (HerdrTarget), never rewritten to fit. `machine`: one of herdr's saved machines, which takes only herdr's agent
    /// commands and never a session.
    public func refusal(session: String?, machine: String? = nil) -> String? {
        if let session, !HerdrTarget.isSession(session) {
            return "“\(session)” is not a herdr session name (letters, digits, _ and -, 64 at most)."
        }
        if let machine {
            if !HerdrTarget.isMachine(machine) { return "“\(machine)” is not one of herdr's machine ids." }
            if session != nil { return "herdr takes a machine or a session, not both." }
            if !goesToMachines { return "herdr sends only its agent commands to a saved machine." }
        }
        switch self {
        case .list, .tabs, .sessions, .version:
            return nil
        case .machines:
            return session == nil ? nil : "herdr's machines are not a session's: ask without one."
        case .read(let pane, _, _), .prompt(let pane), .text(let pane), .explain(let pane):
            return Self.paneRefusal(pane)
        case let .keys(pane, names):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            guard !names.isEmpty else { return "Give at least one key." }
            if let unknown = names.first(where: { HerdrKeys.map($0) == nil }) { return "herdr takes no key “\(unknown)”." }
            return nil
        case let .focus(pane, tab):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            if let tab, !HerdrTarget.isTab(tab) { return "“\(tab)” is not a herdr tab id." }
            return nil
        }
    }

    private static func paneRefusal(_ pane: String) -> String? {
        HerdrTarget.isPane(pane) ? nil : "“\(pane)” is not a herdr pane id."
    }

    // MARK: on a host

    /// The script for a host (RemoteShell.command sends it): herdr found as the status check finds it, then each attempt's
    /// calls through `nt_h`, which adds `--session` for a named session in a subshell that drops herdr's own socket
    /// variables (else they would name the default session's). It prints HerdrResult's form after
    /// RemoteShell.marker: where herdr is, each call's exit, and the last call's output and errors in base64. nil when
    /// `refusal` says why not. A saved machine is never asked from a host: `--machine` is for herdr on this Mac.
    /// `limit`: the most seconds one herdr call may take there (RemoteShell's nt_hd), just under the connection's own
    /// time limit, so a herdr that never answers leaves nothing running on the host.
    public func script(session: String?, limit: Int = 14) -> String? {
        guard refusal(session: session) == nil else { return nil }
        var lines = [
            "C=\(RemoteShell.cacheDir)",
            RemoteShell.findHerdr,
            "printf '\\n%s\\n' \(RemoteShell.quote(RemoteShell.marker))",
            "if [ -z \"$H\" ]; then",
            "  printf 'missing\\t%s\\n' \(RemoteShell.quote(RemoteShell.herdrPlaces))",
            "  printf '%s\\n' \(RemoteShell.quote(RemoteShell.herdrEndMarker))",
            "  exit 0",
            "fi",
            "printf 'where\\t%s\\t%s\\n' \"$(printf '%s' \"$H\" | tr -d '\\000-\\037\\177' | cut -c 1-1024)\" \"$HW\"",
            "S=\(session.map(RemoteShell.quote) ?? "")",
            "nt_limit=\(max(1, limit))",
            // The text, once, from stdin: never in the script, so never on a command line here.
            takesText ? "T=$(cat)" : "T=",
            Self.callFunctions,
        ]
        for (index, attempt) in attempts.enumerated() {
            let calls = attempt.map { call -> String in
                let label = RemoteShell.quote(call.prefix(call.first == "--version" ? 1 : 2).joined(separator: " "))
                let words = call.map { $0 == Self.textMark ? "\"$T\"" : RemoteShell.quote($0) }
                return "nt_call \(label) " + words.joined(separator: " ")
            }
            // A call after the first in an attempt runs only when the one before it worked.
            let body = calls.joined(separator: "; [ \"$nt_x\" -ne 0 ] || ")
            lines.append(index == 0 ? body : "if nt_missing; then \(body); fi")
        }
        lines.append("nt_end")
        return lines.joined(separator: "\n")
    }

    /// nt_h: herdr, for the session asked, for nt_limit seconds at most. nt_call LABEL ARGS…: one call, its output and
    /// errors kept in a private folder, its exit printed. nt_says WORDS: they are in what the last call said.
    /// nt_missing: the last call said this herdr lacks its verb (exit 2, a usage error, or herdr's "unknown command"),
    /// never when its words say this herdr has it (HerdrResult.usage). nt_end: the last call's output (2 MB at most) and
    /// errors (64 KB) in base64, and the end marker. With no private folder for them (no /tmp, a full disk), it says so
    /// and asks herdr nothing.
    static let callFunctions = #"""
        nt_d=$(mktemp -d 2>/dev/null) || nt_d=$(mktemp -d -t nt-herdr 2>/dev/null) || nt_d=
        if [ -z "$nt_d" ] || [ ! -d "$nt_d" ]; then
          printf 'fail\t%s\n' 'Next Term could not make a private folder on the host for herdr'"'"'s answer'
          printf '%s\n' \#(RemoteShell.quote(RemoteShell.herdrEndMarker))
          exit 0
        fi
        trap 'rm -rf "$nt_d"' EXIT
        nt_h() {
          if [ -n "$S" ]; then ( unset HERDR_SOCKET_PATH HERDR_SESSION; nt_hd "$nt_limit" "$H" --session "$S" "$@" ); else nt_hd "$nt_limit" "$H" "$@"; fi
        }
        nt_call() {
          nt_v=$1; shift
          nt_h "$@" >"$nt_d/out" 2>"$nt_d/err" </dev/null
          nt_x=$?
          printf 'exit\t%s\t%s\n' "$nt_x" "$nt_v"
        }
        nt_says() {
          cat "$nt_d/err" "$nt_d/out" 2>/dev/null | head -c 65536 | grep -qiE "$1"
        }
        nt_missing() {
          [ "$nt_x" -ne 0 ] || return 1
          case $nt_v in
        \#(ownUsage)
          esac
          [ "$nt_x" -eq 2 ] && return 0
          nt_says 'unknown command|unrecognized subcommand|unexpected argument'
        }
        nt_end() {
          printf 'bytes\t%s\n' "$(wc -c < "$nt_d/out" 2>/dev/null | tr -d ' ')"
          printf 'out\t'; head -c 2000000 "$nt_d/out" 2>/dev/null | base64 | tr -d '\n'; echo
          printf 'err\t'; head -c 65536 "$nt_d/err" 2>/dev/null | base64 | tr -d '\n'; echo
          printf '%s\n' \#(RemoteShell.quote(RemoteShell.herdrEndMarker))
        }
        """#

    /// nt_missing's cases, one per verb whose words say this herdr has it (HerdrResult.usage).
    private static var ownUsage: String {
        HerdrResult.usage.sorted { $0.key < $1.key }.map { verb, words in
            let said = RemoteShell.quote(words.joined(separator: "|"))
            return "    \(RemoteShell.quote(verb))) if nt_says \(said); then return 1; fi ;;"
        }.joined(separator: "\n")
    }

    // MARK: on this Mac

    /// The argument lists for herdr at `executable` on this Mac, by attempt as `attempts` has them: `--session` first for
    /// a named session, or `--machine` first for one of herdr's saved machines (its agent verb only: herdr forwards none
    /// of the older ones), and the text as one element where `textMark` stands. nil when `refusal` says why not.
    public func argv(executable: String, session: String?, machine: String? = nil, text: String?) -> [[[String]]]? {
        guard refusal(session: session, machine: machine) == nil else { return nil }
        var global = [executable]
        if let machine {
            global += ["--machine", machine]
        } else if let session {
            global += ["--session", session]
        }
        let tried = machine == nil ? attempts : Array(attempts.prefix(1))
        return tried.map { attempt in
            attempt.map { call in global + call.map { $0 == Self.textMark ? (text ?? "") : $0 } }
        }
    }
}

/// press_keys' key names, as herdr's `send-keys` takes them. Anything else is refused before anything is sent.
public enum HerdrKeys {
    public static func map(_ name: String) -> String? {
        switch name.lowercased() {
        case "escape", "esc": return "esc"
        case "enter", "return": return "enter"
        case "shift+tab", "backtab": return "shift+tab"
        case "tab", "up", "down", "left", "right", "backspace", "space", "ctrl+c", "ctrl+d": return name.lowercased()
        default:
            // One printable character goes as itself; a space by its name.
            guard name.count == 1, let scalar = name.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7f,
                  name.unicodeScalars.count == 1 else { return nil }
            return scalar == " " ? "space" : name
        }
    }
}
