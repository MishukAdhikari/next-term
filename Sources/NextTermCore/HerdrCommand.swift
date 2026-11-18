import Foundation

/// The herdr commands Next Term runs, and nothing else: data here, rendered as a script for a host (Remote.swift's rule:
/// fixed text and quoted values, sent base64) or as argument lists for herdr on this Mac, which no shell reads. Each one
/// tries herdr's current verb first and, when herdr answers that it lacks it (HerdrResult.saysUnsupported), the verb an
/// older herdr has, in the same run: never by herdr's version string. Next Term never starts, stops, updates or installs
/// herdr, never stops or deletes one of its sessions, and never makes a workspace or session. Only once the user
/// approves on the Mac (plan 010a U5b, U6b) does it start one of herdr's agents in a new herdr tab (`tab create`, then
/// `agent start`) or end one (`pane close`, which closes the pane's herdr tab too when it was that tab's only pane), and
/// never on one of herdr's saved machines.
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
    /// `pane list`: every pane with its herdr tab, counted (HerdrPanes) before an agent's pane is closed.
    case panes
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
    /// Ends one agent: `pane close` of its pane, after Approve on the Mac. Nothing older is tried, and it never goes to one
    /// of herdr's machines.
    case closePane(pane: String)
    /// The agent kinds `agent start` takes, as herdr's own help lists them ("possible values"), read before a start so a
    /// kind herdr adds is there with no change here (010a K3).
    case startKinds
    /// A new herdr tab for an agent, not focused, in `directory` (herdr's own folder when nil), after Approve on the Mac.
    case newTab(directory: String?, label: String)
    /// One of herdr's kinds started in `pane`, at its shell prompt, after Approve on the Mac: herdr types the kind's
    /// command there and waits up to `startWait` for the agent.
    case startAgent(name: String, kind: String, pane: String, words: [String])
    /// A new pane beside `pane` (`pane split --direction right|down`), not focused, in `directory` (the pane's own when
    /// nil), after Approve on the Mac: for an agent or a command next to the one the user has (plan 040 U1, U4).
    case split(pane: String, direction: SplitDirection, directory: String?)
    /// Until the agent in `pane` is in one of `states` (`agent wait --until`), for at most `timeout` ms (plan 040 U2).
    case waitAgent(pane: String, states: [String], timeout: Int)
    /// Until `pane` shows `pattern` (`pane wait-output --match`, or `--regex` for a regular expression), for at most
    /// `timeout` ms. The pattern comes on stdin, as text does (plan 040 U2).
    case waitOutput(pane: String, regex: Bool, timeout: Int)
    /// The agent in `pane` renamed (`agent rename`), or its name cleared with nil (plan 040 U3).
    case rename(pane: String, name: String?)
    /// A command typed and run in `pane`, at its shell prompt (`pane run`), after Approve on the Mac. The command comes
    /// on stdin, as text does (plan 040 U4).
    case run(pane: String)
    /// A pane zoomed in its herdr tab (`pane zoom --on|--off`), or toggled with nil (plan 040 U5).
    case zoom(pane: String, on: Bool?)
    /// herdr's focus to the pane next to `pane` (`pane focus --direction`) (U5).
    case focusNeighbor(pane: String, direction: Neighbor)
    /// A pane moved to another herdr tab beside its panes (`pane move --tab --split right`), or to a new tab of its
    /// own with nil (`pane move --new-tab`), not focused (U5).
    case move(pane: String, toTab: String?)
    /// Everything herdr shows, in one read (`api snapshot`): workspaces, tabs, panes, their layouts, agents (U6, U9).
    case snapshot
    /// A herdr tab renamed (`tab rename`) (U6).
    case renameTab(tab: String, label: String)
    /// A herdr tab closed, with every pane in it (`tab close`), after Approve on the Mac (U6).
    case closeTab(tab: String)
    /// herdr's view to one of its tabs (`tab focus`) (U6).
    case focusTab(tab: String)
    /// herdr's view to a workspace (`workspace focus`) (U6).
    case focusWorkspace(workspace: String)
    /// A herdr workspace renamed (`workspace rename`) (U6).
    case renameWorkspace(workspace: String, label: String)
    /// A herdr workspace closed, with its tabs and panes (`workspace close`), after Approve on the Mac (U6).
    case closeWorkspace(workspace: String)
    /// A new herdr workspace in `directory`, not focused (`workspace create`), after Approve on the Mac (U6).
    case newWorkspace(directory: String, label: String)
    /// The git worktrees of the repository at `directory`, as herdr sees them (`worktree list`) (U7).
    case worktrees(directory: String)
    /// A new git worktree on `branch` of the repository at `directory`, in a workspace of its own, not focused
    /// (`worktree create`), after Approve on the Mac. herdr trusts the repository for that one request (U7).
    case newWorktree(directory: String, branch: String)
    /// A linked worktree's workspace removed, and its checkout with it (`worktree remove`), after Approve on the Mac,
    /// never with `--force` (U7).
    case removeWorktree(workspace: String)

    /// A neighbour's side, as herdr names it.
    public enum Neighbor: String, Sendable {
        case left, right, up, down
    }

    /// Where a split puts the new pane, as herdr names it.
    public enum SplitDirection: String, Sendable {
        case right, down
    }

    /// The states `agent wait --until` takes.
    public static let waitStates = ["idle", "working", "blocked", "done", "unknown"]

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
    /// How long `agent start` waits for the agent, in milliseconds (herdr takes more than 3,000).
    public static let startWait = 20_000
    /// An agent's start words: at most 16, each one argument of letters, digits and `. _ = : / @ + , -`.
    public static let maxWords = 16

    /// The verbs herdr is ever asked, besides showing its own screen in a tab (bare, or with `--session`). A test walks
    /// every command's rendering against this list.
    public static let allowed: [[String]] = [
        ["--version"], ["agent", "list"], ["agent", "read"], ["agent", "prompt"], ["agent", "send-keys"], ["agent", "focus"],
        ["agent", "explain"], ["pane", "list"], ["pane", "read"], ["pane", "send-text"], ["pane", "send-keys"],
        ["tab", "list"], ["tab", "focus"], ["session", "list"], ["machine", "list"], ["pane", "close"], ["agent", "start"],
        ["tab", "create"], ["pane", "split"], ["agent", "wait"], ["pane", "wait-output"], ["agent", "rename"], ["pane", "run"],
        ["pane", "zoom"], ["pane", "focus"], ["pane", "move"], ["api", "snapshot"], ["tab", "rename"], ["tab", "close"],
        ["workspace", "focus"], ["workspace", "rename"], ["workspace", "close"], ["workspace", "create"], ["worktree", "list"],
        ["worktree", "create"], ["worktree", "remove"],
    ]

    /// The verbs that may go to one of herdr's saved machines (`--machine`): its agent commands, and no other.
    public static let allowedOnMachine: [[String]] = [
        ["agent", "list"], ["agent", "read"], ["agent", "prompt"], ["agent", "send-keys"], ["agent", "focus"], ["agent", "explain"],
        ["agent", "wait"],
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
        case .read, .version, .startKinds: return true
        default: return false
        }
    }

    /// It sends text, which comes on stdin.
    public var takesText: Bool {
        switch self {
        case .prompt, .text, .waitOutput, .run: return true
        default: return false
        }
    }

    /// It changes what herdr shows (a prompt, keys, its view), so the tab checks again soon after.
    public var changesHerdr: Bool {
        switch self {
        case .prompt, .text, .keys, .focus, .closePane, .newTab, .startAgent, .split, .rename, .run, .zoom, .focusNeighbor, .move,
             .renameTab, .closeTab, .focusTab, .focusWorkspace, .renameWorkspace, .closeWorkspace, .newWorkspace, .newWorktree, .removeWorktree:
            return true
        case .list, .panes, .tabs, .sessions, .read, .version, .explain, .machines, .startKinds, .waitAgent, .waitOutput, .snapshot,
             .worktrees:
            return false
        }
    }

    /// It may go to one of herdr's saved machines: one of its agent commands.
    public var goesToMachines: Bool {
        switch self {
        case .list, .read, .prompt, .keys, .focus, .explain, .waitAgent: return true
        default: return false
        }
    }

    /// The herdr calls, by attempt: each attempt is one call or more (a prompt's older form is text, then Return), tried
    /// when every call before it said this herdr lacks its verb. `textMark` stands for the text.
    var attempts: [[[String]]] {
        switch self {
        case .list:
            return [[["agent", "list"]], [["pane", "list"]]]
        case .panes:
            return [[["pane", "list"]]]
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
        case .closePane(let pane):
            return [[["pane", "close", pane]]]
        case .startKinds:
            return [[["agent", "start", "--help"]]]
        case let .newTab(directory, label):
            let folder: [String] = directory.map { ["--cwd", $0] } ?? []
            return [[["tab", "create"] + folder + ["--label", label, "--no-focus"]]]
        case let .startAgent(name, kind, pane, words):
            let rest: [String] = words.isEmpty ? [] : ["--"] + words
            return [[["agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", String(Self.startWait)] + rest]]
        case let .split(pane, direction, directory):
            let folder: [String] = directory.map { ["--cwd", $0] } ?? []
            return [[["pane", "split", pane, "--direction", direction.rawValue] + folder + ["--no-focus"]]]
        case let .waitAgent(pane, states, timeout):
            let until: [String] = states.flatMap { ["--until", $0] }
            return [[["agent", "wait", pane] + until + ["--timeout", String(Self.waitTimeout(timeout))]]]
        case let .waitOutput(pane, regex, timeout):
            return [[["pane", "wait-output", pane, regex ? "--regex" : "--match", Self.textMark, "--source", "recent",
                      "--timeout", String(Self.waitTimeout(timeout))]]]
        case let .rename(pane, name):
            return [[["agent", "rename", pane, name ?? "--clear"]]]
        case .run(let pane):
            return [[["pane", "run", pane, Self.textMark]]]
        case let .zoom(pane, on):
            return [[["pane", "zoom", pane, on.map { $0 ? "--on" : "--off" } ?? "--toggle"]]]
        case let .focusNeighbor(pane, direction):
            return [[["pane", "focus", "--direction", direction.rawValue, "--pane", pane]]]
        case let .move(pane, toTab):
            guard let toTab else { return [[["pane", "move", pane, "--new-tab", "--no-focus"]]] }
            return [[["pane", "move", pane, "--tab", toTab, "--split", "right", "--no-focus"]]]
        case .snapshot:
            return [[["api", "snapshot"]]]
        case let .renameTab(tab, label):
            return [[["tab", "rename", tab, label]]]
        case .closeTab(let tab):
            return [[["tab", "close", tab]]]
        case .focusTab(let tab):
            return [[["tab", "focus", tab]]]
        case .focusWorkspace(let workspace):
            return [[["workspace", "focus", workspace]]]
        case let .renameWorkspace(workspace, label):
            return [[["workspace", "rename", workspace, label]]]
        case .closeWorkspace(let workspace):
            return [[["workspace", "close", workspace]]]
        case let .newWorkspace(directory, label):
            return [[["workspace", "create", "--cwd", directory, "--label", label, "--no-focus"]]]
        case .worktrees(let directory):
            return [[["worktree", "list", "--cwd", directory]]]
        case let .newWorktree(directory, branch):
            return [[["worktree", "create", "--cwd", directory, "--branch", branch, "--no-focus", "--trust-repository"]]]
        case .removeWorktree(let workspace):
            return [[["worktree", "remove", "--workspace", workspace]]]
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
        case .list, .panes, .tabs, .sessions, .version:
            return nil
        case .machines:
            return session == nil ? nil : "herdr's machines are not a session's: ask without one."
        case .read(let pane, _, _), .prompt(let pane), .text(let pane), .explain(let pane), .closePane(let pane), .run(let pane):
            return Self.paneRefusal(pane)
        case let .split(pane, _, directory):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            if let directory, let refusal = Self.folderRefusal(directory) { return refusal }
            return nil
        case let .waitAgent(pane, states, _):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            if states.isEmpty { return "Give at least one state to wait for." }
            if let state = states.first(where: { !Self.waitStates.contains($0) }) {
                return "herdr waits for \(Self.waitStates.joined(separator: ", ")), not “\(state)”."
            }
            return nil
        case .waitOutput(let pane, _, _), .zoom(let pane, _), .focusNeighbor(let pane, _):
            return Self.paneRefusal(pane)
        case let .move(pane, toTab):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            if let toTab, !HerdrTarget.isTab(toTab) { return "“\(toTab)” is not a herdr tab id." }
            return nil
        case .snapshot:
            return nil
        case let .renameTab(tab, label):
            return HerdrTarget.isTab(tab) ? Self.labelRefusal(label) : "“\(tab)” is not a herdr tab id."
        case .closeTab(let tab), .focusTab(let tab):
            return HerdrTarget.isTab(tab) ? nil : "“\(tab)” is not a herdr tab id."
        case .focusWorkspace(let workspace), .closeWorkspace(let workspace), .removeWorktree(let workspace):
            return HerdrTarget.isTab(workspace) ? nil : "“\(workspace)” is not a herdr workspace id."
        case let .renameWorkspace(workspace, label):
            return HerdrTarget.isTab(workspace) ? Self.labelRefusal(label) : "“\(workspace)” is not a herdr workspace id."
        case let .newWorkspace(directory, label):
            return Self.folderRefusal(directory) ?? Self.labelRefusal(label)
        case .worktrees(let directory):
            return Self.folderRefusal(directory)
        case let .newWorktree(directory, branch):
            if let refusal = Self.folderRefusal(directory) { return refusal }
            return Self.isBranch(branch) ? nil : "“\(branch)” is not a branch name Next Term passes to herdr: letters, digits and . _ / -, 100 at most, not starting with - or ending with / or .lock."

        case let .rename(pane, name):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            if let name, !HerdrTarget.isAgentName(name) {
                return "“\(name)” is not a name herdr takes for an agent: a lower-case letter, then up to 31 lower-case letters, digits, _ and -."
            }
            return nil
        case .startKinds:
            return nil
        case let .newTab(directory, label):
            if let directory, let refusal = Self.folderRefusal(directory) { return refusal }
            return HerdrTarget.isAgentName(label) ? nil : "“\(label)” is not a name herdr takes for an agent."
        case let .startAgent(name, kind, pane, words):
            if let refusal = Self.paneRefusal(pane) { return refusal }
            if !HerdrTarget.isAgentName(name) { return "“\(name)” is not a name herdr takes for an agent." }
            if !Self.isKind(kind) { return "“\(kind)” is not one of herdr's agent kinds." }
            return Self.wordsRefusal(words)
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

    /// A kind as herdr names one ("claude", "qodercli"): lowercase letters and digits, and `-`, 32 at most.
    public static func isKind(_ kind: String) -> Bool {
        guard let first = kind.unicodeScalars.first, kind.unicodeScalars.count <= 32, ("a"..."z").contains(first) else { return false }
        return kind.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The kinds in herdr's `agent start --help`: its "[possible values: pi, claude, codex, …]", each checked as a kind.
    public static func kinds(fromHelp help: String) -> [String] {
        guard let start = help.range(of: "[possible values:") else { return [] }
        let rest = help[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return [] }
        return rest[..<end].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(isKind)
    }

    /// Why an agent's start words cannot go, or nil: more than 16, or one that is not a plain argument (spaces, `;`, `|`,
    /// `$(`, quotes and line breaks are never one), or holds a stored key.
    public static func wordsRefusal(_ words: [String], mask: SecretMask = .current) -> String? {
        if words.count > maxWords { return "At most \(maxWords) words go to the agent." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._=:/@+,-")
        for word in words {
            guard !word.isEmpty, word.count <= 200, word.unicodeScalars.allSatisfy(allowed.contains) else {
                return "“\(String(word.prefix(40)))” is not a plain word: letters, digits and . _ = : / @ + , - only, 200 at most."
            }
            // herdr's own options (--session…) wherever they stand, and stored keys, as for text.
            if let refusal = textRefusal(word, mask: mask) { return refusal }
        }
        return nil
    }

    /// `tab create`'s answer: the new tab's id and its pane's (`"result": {"root_pane": {"pane_id", "tab_id"}}`); nil when
    /// it names no pane herdr's rule takes.
    public static func createdPane(_ json: String) -> (tab: String, pane: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any], let root = result["root_pane"] as? [String: Any],
              let pane = root["pane_id"] as? String, HerdrTarget.isPane(pane) else { return nil }
        let named: String? = root["tab_id"] as? String ?? (result["tab"] as? [String: Any])?["tab_id"] as? String
        return (named ?? "", pane)
    }

    /// A label for a herdr tab or workspace: one line of up to 60 characters that show as themselves, never one of
    /// herdr's own options.
    static func labelRefusal(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60, !trimmed.hasPrefix("-"), !trimmed.unicodeScalars.contains(where: ShellQuote.isControl) else {
            return "A herdr label is one line of up to 60 characters, not starting with -."
        }
        return nil
    }

    /// A branch name Next Term hands herdr for a new worktree: letters, digits and `. _ / -`, at most 100, never one
    /// that git or herdr would read as an option.
    public static func isBranch(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard !name.isEmpty, name.count <= 100, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix(".lock"),
              !name.contains(".."), !name.contains("//"), name.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return true
    }

    /// The longest wait herdr is asked for, in milliseconds: MCP's own most (300 s).
    public static let maxWait = 300_000

    /// A wait's time, in milliseconds, between 1 s and `maxWait`.
    static func waitTimeout(_ milliseconds: Int) -> Int { min(maxWait, max(1000, milliseconds)) }

    /// The workspace a `workspace create` or `worktree create` answer names (`"result": {"workspace": {"workspace_id"}}`).
    public static func createdWorkspace(_ json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any], let id = (result["workspace"] as? [String: Any])?["workspace_id"] as? String,
              HerdrTarget.isTab(id) else { return nil }
        return id
    }

    /// `pane split`'s answer: the new pane's id (`"result": {"pane": {"pane_id"}}`); nil when it names none herdr's rule
    /// takes.
    public static func splitPane(_ json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any], let pane = (result["pane"] as? [String: Any])?["pane_id"] as? String,
              HerdrTarget.isPane(pane) else { return nil }
        return pane
    }

    /// A folder for a new herdr tab: absolute (herdr reads it as it is, with no shell to expand `~`), one line.
    static func folderRefusal(_ folder: String) -> String? {
        guard folder.hasPrefix("/"), folder.count <= 1024, !folder.unicodeScalars.contains(where: ShellQuote.isControl) else {
            return "The folder must be an absolute path, such as /srv/app."
        }
        return nil
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
