import Foundation

/// The texts the remote door answers with that are not one control option's own (the plan's Error texts). They are
/// written for a phone. A refusal by an option ends with `turnOn`, which names the option to turn on at the Mac.
public enum RemoteAccessText {
    /// "Turn on “A” for this connection in Settings › Remote Access on your Mac.", with "and" between two options.
    public static func turnOn(_ options: [RemoteAccessOption.ID]) -> String {
        let quoted = options.map { "“\(RemoteAccessOption.option($0).label)”" }
        return "Turn on \(listed(quoted)) for this connection in Settings › Remote Access on your Mac."
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A Next Term tool the connection's options leave out (R20).
    public static func cantUse(_ tool: String, needing options: [RemoteAccessOption.ID]) -> String {
        "This connection can't use \(tool). " + turnOn(options)
    }

    /// A Next Term tool no option names (allow by name, R21).
    public static let notAvailable = "This tool is not available remotely."

    /// A name Next Term does not know: the JSON-RPC error `nxtrm mcp` gives.
    public static func unknownTool(_ name: String) -> String { "Unknown tool: \(name)" }

    /// An argument the connection's schema for the tool does not list (JSON-RPC error -32602). `force` on
    /// close_tab is listed only with "Close busy tabs" (R53), so its text names that option.
    public static func notAnArgument(_ argument: String, of tool: String) -> String {
        let text = "Invalid params: \(argument) is not an argument of \(tool)."
        guard tool == "close_tab", argument == "force" else { return text }
        return text + " " + turnOn([.closeBusyTabs])
    }

    /// A call revoked, or Remote access turned off, while it ran (R38).
    public static let turnedOff = "Access was turned off on the Mac."
    /// Declined at the Mac, when "Ask on this Mac before changes" asked (R59).
    public static let declined = "Declined on your Mac."
    /// Over R27's limits.
    public static let tooManyCalls = "Too many calls; try again in a few seconds."
    /// For a remote caller, in place of MCPControl's "No tab with that id; list_tabs shows them.".
    public static let oldTab = "That tab is gone, maybe because Next Term restarted. Call list_tabs."
    /// The Mac did not answer within the door's 100 seconds (R25).
    public static let deadline = "Next Term on the Mac did not answer in time. A dialog may be open there. Try again."
    /// send_to_tab's text over R27's limit, which holds whatever the options.
    public static let textTooLong = "Text is limited to 8,000 characters remotely."

    // MARK: the control options' texts (U14)

    /// "Or turn on “A” … on your Mac.": the last sentence when the text first offers another way out.
    public static func orTurnOn(_ options: [RemoteAccessOption.ID]) -> String { "Or t" + turnOn(options).dropFirst() }

    /// R50.
    public static let shellTab = "That is a shell tab. " + turnOn([.typeShells])
    /// R57: a mode that never asks, or a bypass flag on the command line.
    public static let neverAsks = "That agent runs without asking you first (a bypass or auto-approve mode). " + turnOn([.typeNeverAsking])
    /// R57: an agent not on the list.
    public static let modeUnknown = "Next Term can't read this agent's permission mode. " + turnOn([.typeNeverAsking])
    /// R57: a listed agent whose mode or input state Next Term can't see now.
    public static let modeHidden = "Next Term can't see this agent's permission mode right now. Try again when its input line shows. "
        + orTurnOn([.typeNeverAsking])
    /// R57: a mode that asks, with "Type into agents that ask before acting" off.
    public static let asksFirst = "That agent asks before it acts. " + turnOn([.typeAsking])
    /// R51.
    public static let shellAndMemoryOff = "Text that starts with ! or # is off for this connection. " + turnOn([.shellAndMemory])
    /// R51: an allowlist word with its option off, or any other slash command.
    public static func slashOff(_ option: RemoteAccessOption.ID) -> String { "That slash command is off for this connection. " + turnOn([option]) }
    /// R51, R52.
    public static let alwaysReturn = "On this connection, text is always sent with Return. " + turnOn([.everyKey])
    /// R51: the input line holds text, or can't be found.
    public static let inputLine = "That agent's input line has text in it, or Next Term can't see it. Clear it on your Mac. "
        + orTurnOn([.anySlash, .shellAndMemory])
    /// R52.
    public static let keyOff = "That key is off for this connection. " + turnOn([.everyKey])
    /// R52: the safe keys while a question or a screen Next Term can't classify shows.
    public static let keysScreen = "That tab shows a question or a screen Next Term can't read. Answer a question with answer_agent. "
        + orTurnOn([.everyKey])
    /// R52: Return while the input line has text.
    public static let enterWithText = "Return is off while the agent's input line has text. Clear it on your Mac. " + orTurnOn([.everyKey])
    /// R58.
    public static let standingChoice = "That choice isn't a one-time choice Next Term knows. " + turnOn([.answerStanding])
    /// R54.
    public static let commandOff = "That command is off for this connection. A new tab can run one agent name with no arguments, "
        + "such as claude. " + turnOn([.openAnyTab])
    /// R54, R62.
    public static let folderOff = "That folder is not in an open project. " + turnOn([.showOnMac])
    /// R53.
    public static let busyTab = "That tab is busy. Close it on your Mac. " + orTurnOn([.closeBusyTabs])
    /// R55: "Or turn off", since that option sets a limit.
    public static let controlRate = "Too many control calls; try again in a minute. Or turn off “"
        + RemoteAccessOption.option(.rateLimit).label + "” for this connection in Settings › Remote Access on your Mac."
}

/// The agents whose permission mode Next Term reads on their screen (R57's list): a remote new_tab may start one by
/// name under "Open a tab that runs a listed agent" (R54), and typing reaches one in a mode that asks under "Type into
/// agents that ask before acting". Claude Code only, until hand check H16 records Codex's, Gemini CLI's and Qwen
/// Code's mode strings.
public enum RemoteAccessAgents {
    public static var listed: [String] { RemoteAccessAgentRules.listed.keys.sorted() }
}

/// Decides each remote tool call before it runs, and shapes its result before it goes back (the plan's U5). Pure:
/// the door calls `decide` before the main thread, and `shape` on whatever thread the result comes back on.
///
/// The control options' own rules (text, keys, commands, the control rate limit) join this policy with the control
/// options. The import tools stay local: no option names them, so they get "not available" like any tool no option
/// names.
public enum RemoteAccessPolicy {
    public enum Decision {
        /// Run the tool with these arguments: the given ones, clamped to the remote limits.
        case allow([String: Any])
        /// Answer with this text as an error result, and run nothing.
        case refuse(String)
        /// Answer with JSON-RPC error -32602 and this text, and run nothing.
        case invalidParams(String)
        /// Not a Next Term tool: `MCPServer.respond` answers it as it does locally, with this text.
        case unknownTool(String)
    }

    /// The decision for one call, in order: a name Next Term does not know is unknown; a tool the options leave
    /// out is refused, naming the option to turn on (or "not available" when no option names it); an argument
    /// the tool's remote schema does not list is invalid; a value over a limit that refuses is refused. Otherwise
    /// the call is allowed, with each limited argument clamped and wait_for_tab's and host_changes' remote
    /// defaults filled in. Values are otherwise the tool's own to check.
    ///
    /// Whether a tool is admitted is the catalogue's answer (`RemoteAccessTools.tools(for:)`), so this check and
    /// tools/list never disagree. `rows` only names the options in a refusal.
    public static func decide(tool name: String, arguments: [String: Any], options: RemoteAccessOptions,
                              tools table: [MCPServer.Tool] = MCPServer.tools,
                              rows: [RemoteAccessOption] = RemoteAccessOption.all) -> Decision {
        guard table.contains(where: { $0.name == name }) else {
            return .unknownTool(RemoteAccessText.unknownTool(name))
        }
        let offered = RemoteAccessTools.tools(for: options, from: table)
        guard let tool = offered.first(where: { $0.name == name }) else {
            return .refuse(refusal(for: name, options: options, rows: rows))
        }
        let properties = schemaProperties(of: tool)
        let unlisted = arguments.keys.sorted().first { properties[$0] == nil }
        if let unlisted {
            return .invalidParams(RemoteAccessText.notAnArgument(unlisted, of: name))
        }
        if let text = overLimit(name, arguments) { return .refuse(text) }
        if let text = controlRefusal(name, arguments, options: options) { return .refuse(text) }
        return .allow(clamped(arguments, tool: name, properties: properties))
    }

    // MARK: the control options' rules before the main thread (U14)

    /// The control options' rules that need no screen: send_to_tab without Return needs "Every key" (R51, R52);
    /// without it press_keys takes the safe keys alone (R52); without "Open a tab with any command, or a plain shell" a
    /// new tab runs one listed agent by name, with no arguments and no first prompt typed after it (R54). The door's
    /// checks on the main thread come after.
    public static func controlRefusal(_ tool: String, _ arguments: [String: Any], options: RemoteAccessOptions) -> String? {
        switch tool {
        case "send_to_tab":
            if arguments["submit"] as? Bool == false, !options[.everyKey] { return RemoteAccessText.alwaysReturn }
        case "press_keys":
            guard !options[.everyKey] else { return nil }
            let keys: [String] = arguments["keys"] as? [String] ?? []
            if keys.contains(where: { !RemoteAccessTools.safeKeys.contains($0.lowercased()) }) { return RemoteAccessText.keyOff }
        case "new_tab":
            guard !options[.openAnyTab] else { return nil }
            let command: String = (arguments["command"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let prompt: String = (arguments["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !RemoteAccessAgents.listed.contains(command) || !prompt.isEmpty { return RemoteAccessText.commandOff }
        default:
            break
        }
        return nil
    }

    /// The slash commands "/ commands on the allowlist" admits (R51): an allowlist, so commands agents add later stay off.
    public static let slashAllowlist: Set<String> = ["/clear", "/compact", "/status", "/cost", "/usage", "/context", "/help"]

    /// What text sent into an agent tab may start with, after leading whitespace (R51): the door calls it on the main
    /// thread once it knows the tab is an agent tab. `!` and `#` need "! shell lines and # memory lines"; a first word
    /// on the allowlist, exactly, needs "/ commands on the allowlist" or "Any / command"; any other `/` needs "Any /
    /// command". Nil when the text may go.
    public static func textRefusal(_ text: String, options: RemoteAccessOptions) -> String? {
        let trimmed = text.drop { $0.isWhitespace }
        guard let first = trimmed.first else { return nil }
        if first == "!" || first == "#" { return options[.shellAndMemory] ? nil : RemoteAccessText.shellAndMemoryOff }
        guard first == "/", !options[.anySlash] else { return nil }
        let word = String(trimmed.prefix { !$0.isWhitespace })
        guard slashAllowlist.contains(word) else { return RemoteAccessText.slashOff(.anySlash) }
        return options[.slashAllowlist] ? nil : RemoteAccessText.slashOff(.slashAllowlist)
    }

    /// A control call (R55): one to a tool tagged write, which acts on the Mac. Reading never counts: settings_get,
    /// list_skills, get_skill and list_secrets included.
    public static func isControlCall(_ tool: String) -> Bool { MCPServer.scopeTags[tool] == .write }

    // MARK: options

    /// The options a tool needs, in halves: it is admitted when each half has an option on. A tool has one half,
    /// the options that name it, except press_keys, which also needs a Keys option (R20). A tool no option names
    /// needs nothing and is never admitted.
    public static func needs(_ tool: String,
                             rows: [RemoteAccessOption] = RemoteAccessOption.all) -> [[RemoteAccessOption.ID]] {
        let naming = rows.filter { $0.tools.contains(tool) }.map(\.id)
        guard !naming.isEmpty else { return [] }
        guard let group = alsoNeeds[tool] else { return [naming] }
        let second = rows.filter { $0.group == group }.map(\.id)
        return second.isEmpty ? [] : [naming, second]
    }

    /// Tools that need an option of a second group too.
    static let alsoNeeds: [String: RemoteAccessOption.Group] = ["press_keys": .keys]

    /// The refusal for a tool the options leave out: the first option of each half that has none on, or "not
    /// available" when no option names it.
    static func refusal(for tool: String, options: RemoteAccessOptions, rows: [RemoteAccessOption]) -> String {
        let halves = needs(tool, rows: rows)
        let missing = halves.filter { half in !half.contains { options[$0] } }
        let named = missing.compactMap(\.first)
        guard !named.isEmpty else { return RemoteAccessText.notAvailable }
        return RemoteAccessText.cantUse(tool, needing: named)
    }

    // MARK: limits

    /// R27's limits that refuse a call rather than clamp it. They hold whatever the options (R61). send_to_tab's
    /// text is counted as JSON Schema counts a string's length: in Unicode scalars.
    public static func overLimit(_ tool: String, _ arguments: [String: Any]) -> String? {
        guard tool == "send_to_tab", let text = arguments["text"] as? String else { return nil }
        guard text.unicodeScalars.count > RemoteAccessLimits.sendText else { return nil }
        return RemoteAccessText.textTooLong
    }

    /// An argument held to a remote maximum, and the value the door fills in when a call leaves it out.
    struct Clamp {
        let tool: String
        let argument: String
        let maximum: Int
        let fill: Int?
    }

    /// The Remote limits table's clamps: the remote schemas' maxima (U1) and find_in_files' 200.
    static let clamps: [Clamp] = {
        var clamps: [Clamp] = []
        for limit in RemoteAccessTools.schemaLimits {
            let fill = limit.doorFills ? limit.defaultValue : nil
            clamps.append(Clamp(tool: limit.tool, argument: limit.argument, maximum: limit.maximum, fill: fill))
        }
        let found = RemoteAccessLimits.findResults
        clamps.append(Clamp(tool: "find_in_files", argument: "max_results", maximum: found, fill: nil))
        return clamps
    }()

    /// The arguments with each limited one between its schema's minimum and its remote maximum, rounded down. A
    /// value that is not a number is left for the tool to refuse, unless the door fills that argument: then it
    /// gets the remote default, as a call that left it out does.
    static func clamped(_ arguments: [String: Any], tool: String, properties: [String: Any]) -> [String: Any] {
        var result = arguments
        for clamp in clamps where clamp.tool == tool {
            let schema = properties[clamp.argument] as? [String: Any]
            let minimum = Double(schema?["minimum"] as? Int ?? 1)
            if let value = number(arguments[clamp.argument]) {
                let held = min(max(value, minimum), Double(clamp.maximum))
                result[clamp.argument] = Int(held.rounded(.down))
            } else if let fill = clamp.fill {
                result[clamp.argument] = fill
            }
        }
        return result
    }

    /// A JSON number, true and false aside.
    static func number(_ value: Any?) -> Double? {
        guard let value, !MCPServer.isBoolean(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// The tool's schema properties by name.
    static func schemaProperties(of tool: MCPServer.Tool) -> [String: Any] {
        let parsed = try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))
        let schema = parsed as? [String: Any]
        return schema?["properties"] as? [String: Any] ?? [:]
    }

    // MARK: shaping

    /// Where a cut result says how to read the rest.
    static let noteKey = "truncated_note"
    static let tabGone = "No tab with that id"

    /// The result as a remote client gets it (R23, KTD14).
    ///
    /// - JSON is masked string by string, keys included: the door's own tokens, then, in terminal text, the shapes
    ///   secrets take on a command line (`CommandSecrets`), then `MCPRedaction`. A file's text keeps
    ///   `MCPRedaction` alone, as it has locally (`readsCode`). A screen is also masked across the rows the
    ///   terminal wrapped (`unwrapped`). What was masked is added to `"redacted"`, or to the count a tool gave
    ///   already. Text that comes back from `MCPRedaction` as it went in counts nothing, and neither does a mask
    ///   made before (`stale`), so a tool's own masks are not counted twice. Two keys that mask alike both stay.
    /// - get_editor_selection's `text` is cut to 16,000 characters.
    /// - Then the whole result is held to 64,000 characters by cutting its longest strings at a line break, with
    ///   `"truncated": true` and a note on how to read the rest. A screen keeps its last lines; anything else
    ///   keeps its start. A string too long to read whole says so too, however short masking made it.
    /// - Text that is not JSON, error results included, is masked and cut as text.
    ///
    /// Characters are Unicode scalars, as JSON Schema counts them. JSON goes out as it was read and masked,
    /// written by `MCPServer.json`, never as it came: a key given twice is read once, and many clients would read
    /// the other. Every tool writes its result with `MCPServer.json`, so one that needs nothing keeps its text, and
    /// a shaped result shaped again stays the same. An error that says a tab id is unknown gets the remote text,
    /// which says why that may be.
    public static func shape(_ result: MCPServer.CallResult, tool: String) -> MCPServer.CallResult {
        var text = result.text
        if result.isError, text.hasPrefix(tabGone) { text = RemoteAccessText.oldTab }
        let shaped: String
        if let value = parsedJSON(text) {
            shaped = shapeJSON(value, tool: tool)
        } else {
            shaped = shapeText(text, tool: tool)
        }
        return MCPServer.CallResult(text: shaped, isError: result.isError)
    }

    static func parsedJSON(_ text: String) -> Any? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return value is [String: Any] || value is [Any] ? value : nil
    }

    /// Screens keep their end when cut: read_tab's lines count from the end, and the last lines are the newest.
    static func keepsEnd(_ tool: String) -> Bool {
        tool == "read_tab" || tool == "wait_for_tab"
    }

    /// Tools whose strings are files' text: code, where `password=` is as often an argument's name as a secret.
    /// They keep `MCPRedaction`'s masking alone, as they have locally. Any other tool's text is terminal text, such
    /// as screens, commands and titles, and the command-line rules mask it too.
    static let codeTools: Set<String> = [
        "read_file", "find_in_files", "get_diff", "host_changes", "get_editor_selection",
    ]

    static func readsCode(_ tool: String) -> Bool {
        codeTools.contains(tool)
    }

    /// How a tool's strings are read.
    struct Reading {
        /// Cut, a string keeps its end (`keepsEnd`).
        let keepEnd: Bool
        /// Terminal text: the command-line rules mask it too (`readsCode`).
        let commands: Bool

        init(tool: String) {
            keepEnd = RemoteAccessPolicy.keepsEnd(tool)
            commands = !RemoteAccessPolicy.readsCode(tool)
        }
    }

    /// What masking a result's strings found.
    struct Tally {
        /// How many secrets were masked.
        var count = 0
        /// A string was too long to read whole (`ahead`).
        var cut = false
    }

    static func shapeJSON(_ value: Any, tool: String) -> String {
        var tally = Tally()
        var shaped = masked(value, key: nil, reading: Reading(tool: tool), tally: &tally)
        var notes: [String] = []
        if tool == "get_editor_selection", var object = shaped as? [String: Any],
           let selected = object["text"] as? String {
            let limit = RemoteAccessLimits.selectionChars
            if selected.unicodeScalars.count > limit {
                object["text"] = RemoteAccessOAuth.prefix(selected, scalars: limit)
                shaped = object
                notes.append("The selection is cut to its first 16,000 characters remotely.")
            }
        }
        // A string read only in part says so, however short masking made it. A cut selection says so already.
        if tally.cut, notes.isEmpty { notes.append(capNote(tool)) }
        if tally.count > 0 { shaped = counted(shaped, tally.count) }
        return capped(shaped, notes: notes, tool: tool)
    }

    /// Every string masked, keys included, with how many were. `key` is the original name the value is under: a
    /// screen is masked across its wrapped rows too.
    static func masked(_ value: Any, key: String?, reading: Reading, tally: inout Tally) -> Any {
        switch value {
        case let text as String:
            let read = ahead(text, keepEnd: reading.keepEnd)
            var found = mask(read.text, commands: reading.commands)
            if key == screenKey {
                let rows = unwrapped(read, masked: found.text, commands: reading.commands, keepEnd: reading.keepEnd)
                found = (rows.text, found.count + rows.count)
            }
            tally.count += found.count
            tally.cut = tally.cut || read.cut
            return found.text
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            // In order, so which of two keys that mask alike gets the plain mask is the same each time.
            for name in object.keys.sorted() {
                guard let item = object[name] else { continue }
                let shown = mask(name, commands: reading.commands)
                tally.count += shown.count
                result[unused(shown.text, in: result)] = masked(item, key: name, reading: reading, tally: &tally)
            }
            return result
        case let array as [Any]:
            return array.map { masked($0, key: key, reading: reading, tally: &tally) }
        default:
            return value
        }
    }

    /// `name`, or `name (2)`, `name (3)` and so on when the object has it already, so two keys that mask alike
    /// both keep their values.
    static func unused(_ name: String, in object: [String: Any]) -> String {
        guard object[name] != nil else { return name }
        var number = 2
        while object["\(name) (\(number))"] != nil { number += 1 }
        return "\(name) (\(number))"
    }

    /// A string as far as it is read: `cut` when part of it was left unread, and `joins` when the row left out next
    /// to what was read ends (or, for a start, starts) in text, so it may have wrapped into the row kept.
    struct Read {
        var text: String
        var cut = false
        var joins = false
    }

    /// Text past the cap is never sent, so a long string is read only this far past it before it is masked: the
    /// cut it gets later falls inside what was masked, so a secret at that cut is masked whole, not shown in part.
    /// The line the read stops in is left out (`edged`): masking can shrink what was read far below the cap, and
    /// then a secret the read stopped in would be inside it.
    static func ahead(_ text: String, keepEnd: Bool) -> Read {
        let limit = RemoteAccessLimits.resultChars + RemoteAccessAuditMask.readLength
        guard text.utf8.count > limit else { return Read(text: text) }
        let window = keepEnd ? suffix(text, scalars: limit) : RemoteAccessOAuth.prefix(text, scalars: limit)
        guard window.utf8.count < text.utf8.count else { return Read(text: text) }
        return edged(window, keepEnd: keepEnd)
    }

    /// What was read, without the part the read stopped in: up to the nearest line break, when one is within
    /// `readLength` of where the read stopped, as a secret is never cut by one. Without one, up to the nearest
    /// character no key is made of (`isKeyScalar`). When every one of them is, the read stopped in a run longer
    /// than any key, which masking takes whole if it looks random (MCPRedaction's long runs).
    static func edged(_ window: String, keepEnd: Bool) -> Read {
        let scalars = window.unicodeScalars
        let reach = RemoteAccessAuditMask.readLength
        if keepEnd {
            let region = scalars.prefix(reach)
            if let lineBreak = region.firstIndex(of: "\n") {
                let left = scalars[..<lineBreak]
                let joins = left.last.map { !$0.properties.isWhitespace } ?? true
                return Read(text: String(scalars[scalars.index(after: lineBreak)...]), cut: true, joins: joins)
            }
            if let other = region.firstIndex(where: { !isKeyScalar($0) }) {
                return Read(text: String(scalars[other...]), cut: true)
            }
            return Read(text: window, cut: true)
        }
        let region = scalars.suffix(reach)
        if let lineBreak = region.lastIndex(of: "\n") {
            let left = scalars[scalars.index(after: lineBreak)...]
            let joins = left.first.map { !$0.properties.isWhitespace } ?? true
            return Read(text: String(scalars[..<lineBreak]), cut: true, joins: joins)
        }
        if let other = region.lastIndex(where: { !isKeyScalar($0) }) {
            return Read(text: String(scalars[...other]), cut: true)
        }
        return Read(text: window, cut: true)
    }

    /// A character of MCPRedaction's long runs, which keys and tokens are made of.
    static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "_", "-": return true
        default: return false
        }
    }

    /// The text with secrets masked, and how many were: the door's own tokens first, so no other pattern can split
    /// one, then with `commands` the shapes secrets take on a command line (`CommandSecrets`: a flag's or a
    /// variable's value, a password after -p, an auth header), then `MCPRedaction`. When a pattern could not read
    /// the whole text, the text goes as one mask. The audit log masks with it too, with `commands`
    /// (`RemoteAccessAuditMask.whole`).
    static func mask(_ text: String, commands: Bool = false) -> (text: String, count: Int) {
        var masked = text
        var complete = true
        var found = MCPRedaction.replace(RemoteAccessAuditMask.remoteToken, in: &masked, complete: &complete) { _, _ in
            MCPRedaction.mask
        }
        if commands {
            for rule in CommandSecrets.rules {
                found += CommandSecrets.apply(rule, to: &masked, complete: &complete)
            }
        }
        let redacted = MCPRedaction.redact(masked, maskingRun: { (run: String) -> String? in
            MCPRedaction.looksRandom(run) ? MCPRedaction.mask : nil
        })
        guard complete, redacted.complete else { return (MCPRedaction.mask, 1) }
        guard redacted.text != masked else { return (masked, found) }
        // The text changed, so something new was masked: at least one.
        let more = max(1, redacted.count - stale(in: masked))
        return (redacted.text, found + more)
    }

    /// The masks made before that `MCPRedaction` finds and counts again, leaving them as they are: a URL whose
    /// password is a mask, and a private key block whose lines inside are masks (its first line, if it shows, is
    /// masked and counted on its own). A screen shows them when an agent prints a result masked earlier, and a
    /// tool's own masks come back the same way; they hide nothing new.
    static func stale(in text: String) -> Int {
        let mask = MCPRedaction.mask
        guard text.contains(mask) else { return 0 }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var count = 0
        for match in MCPRedaction.urlPassword.matches(in: text, range: whole) {
            if ns.substring(with: match.range(at: 2)) == mask { count += 1 }
        }
        for match in MCPRedaction.privateKey.matches(in: text, range: whole) {
            let lines = ns.substring(with: match.range).split(separator: "\n", omittingEmptySubsequences: false)
            if lines.allSatisfy({ $0.hasPrefix("-----") || $0 == mask }) { count += 1 }
        }
        return count
    }

    /// The result with `count` added to its `"redacted"`. A list is put under `"items"` to carry it.
    static func counted(_ value: Any, _ count: Int) -> Any {
        var object = value as? [String: Any] ?? ["items": value]
        let given = object["redacted"].flatMap { MCPServer.isBoolean($0) ? nil : $0 as? Int } ?? 0
        object["redacted"] = given + count
        return object
    }

    /// The result saying it was cut, and how to read the rest.
    static func noted(_ value: Any, _ notes: [String]) -> Any {
        var object = value as? [String: Any] ?? ["items": value]
        object["truncated"] = true
        object[noteKey] = notes.joined(separator: " ")
        return object
    }

    /// What a cut result says about reading the rest.
    static func capNote(_ tool: String) -> String {
        let lead = "Cut to fit 64,000 characters"
        switch tool {
        case "read_tab": return "\(lead): the screen's first lines are left out. Ask for fewer lines."
        case "wait_for_tab": return "\(lead): the screen's first lines are left out. read_tab can ask for fewer lines."
        case "read_file": return "\(lead), so the text stops before end_line. Ask again with a smaller limit."
        case "get_diff": return "\(lead). Ask for one file with path, or for a smaller max_chars."
        case "host_changes": return "\(lead). Ask for a smaller max_bytes."
        case "find_in_files": return "\(lead). Narrow the query or glob, or lower max_results."
        default: return "\(lead). Ask for less at a time."
        }
    }

    /// The result as JSON of at most 64,000 characters. While it is longer, its longest strings are cut, at a line
    /// break, down to one length, by as much in all as it is over. Each character cut shortens the JSON by at least
    /// one, so one round is enough however many strings it holds; when the strings can't shrink enough, it says so.
    static func capped(_ value: Any, notes: [String], tool: String) -> String {
        let cap = RemoteAccessLimits.resultChars
        var value = notes.isEmpty ? value : noted(value, notes)
        var text = MCPServer.json(value)
        guard text.unicodeScalars.count > cap else { return text }
        let cutNote = capNote(tool)
        value = noted(value, notes.contains(cutNote) ? notes : notes + [cutNote])
        let keepEnd = keepsEnd(tool)
        // A second round only when the first cut every string to nothing, and then only to find that out.
        for _ in 0..<3 {
            text = MCPServer.json(value)
            let over = text.unicodeScalars.count - cap
            if over <= 0 { return text }
            guard let length = level(cutting: over, from: lengths(in: value)) else { break }
            value = cutting(value, to: length, fromEnd: keepEnd)
        }
        let note = "The result is too long to send remotely. Ask for less at a time."
        let tooLong: [String: Any] = ["truncated": true, noteKey: note]
        return MCPServer.json(tooLong)
    }

    /// The longest length every string can keep so that, cut to it, they lose at least `over` characters in all.
    /// Nil when no string is left to cut.
    static func level(cutting over: Int, from lengths: [Int]) -> Int? {
        guard let longest = lengths.max(), longest > 0 else { return nil }
        func lost(_ level: Int) -> Int { lengths.reduce(0) { $0 + max(0, $1 - level) } }
        guard lost(0) >= over else { return 0 }
        var low = 0
        var high = longest - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lost(middle) >= over { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The length of every string in the value, by Unicode scalars. The cut note is never cut, so it isn't counted.
    static func lengths(in value: Any, top: Bool = true) -> [Int] {
        switch value {
        case let text as String:
            return [text.unicodeScalars.count]
        case let object as [String: Any]:
            return object.flatMap { key, item in top && key == noteKey ? [] : lengths(in: item, top: false) }
        case let array as [Any]:
            return array.flatMap { lengths(in: $0, top: false) }
        default:
            return []
        }
    }

    /// The value with every string longer than `length` cut to it (see `cut`), the cut note aside.
    static func cutting(_ value: Any, to length: Int, fromEnd: Bool, top: Bool = true) -> Any {
        switch value {
        case let text as String:
            return cut(text, keeping: length, fromEnd: fromEnd)
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, item) in object {
                result[key] = top && key == noteKey ? item : cutting(item, to: length, fromEnd: fromEnd, top: false)
            }
            return result
        case let array as [Any]:
            return array.map { cutting($0, to: length, fromEnd: fromEnd, top: false) }
        default:
            return value
        }
    }

    /// Text that is not JSON, masked and held to 64,000 characters with a note at its end. Text too long to read
    /// whole gets the note too, however short masking made it.
    static func shapeText(_ text: String, tool: String) -> String {
        let read = ahead(text, keepEnd: false)
        let found = mask(read.text, commands: !readsCode(tool))
        let cap = RemoteAccessLimits.resultChars
        guard read.cut || found.text.unicodeScalars.count > cap else { return found.text }
        let note = "\n… (truncated: cut to fit 64,000 characters)"
        let room = cap - note.unicodeScalars.count
        return cut(found.text, keeping: room, fromEnd: false) + note
    }

    /// The text cut to at most `limit` Unicode scalars, in whole characters, at a line break: its start up to the
    /// last line break that fits, or its end from the first line break. A line break that would keep less than
    /// half of `limit` is passed over, and the text is cut where the limit falls.
    static func cut(_ text: String, keeping limit: Int, fromEnd: Bool) -> String {
        guard limit > 0 else { return "" }
        guard text.unicodeScalars.count > limit else { return text }
        if fromEnd {
            let tail = suffix(text, scalars: limit)
            guard let lineBreak = tail.firstIndex(where: \.isNewline) else { return tail }
            let kept = String(tail[tail.index(after: lineBreak)...])
            return kept.unicodeScalars.count * 2 >= limit ? kept : tail
        }
        let head = RemoteAccessOAuth.prefix(text, scalars: limit)
        guard let lineBreak = head.lastIndex(where: \.isNewline) else { return head }
        let kept = String(head[..<lineBreak])
        return kept.unicodeScalars.count * 2 >= limit ? kept : head
    }

    /// The end of the text, at most `limit` Unicode scalars, in whole characters.
    static func suffix(_ text: String, scalars limit: Int) -> String {
        var used = 0
        var start = text.endIndex
        while start > text.startIndex {
            let before = text.index(before: start)
            let width = text[before].unicodeScalars.count
            guard used + width <= limit else { break }
            used += width
            start = before
        }
        return String(text[start...])
    }
}

// MARK: wrapped rows

extension RemoteAccessPolicy {
    /// The key a screen is under in read_tab's and wait_for_tab's results.
    static let screenKey = "screen"
    /// A masked end of a row that hides this many characters ends a whole secret: a long run is masked from 32.
    static let hiddenWhole = 32

    /// A screen with what the terminal wrapped masked too. A line longer than the terminal goes on at the start of
    /// the next row, and the screen has a line break there, so a token can come in halves each too short for its
    /// pattern. Rows that may go on (`ScreenRows.goesOn`) are joined into the line they would be and masked again,
    /// and where that hides what the rows alone don't, the words at the breaks are masked (`ScreenRows.join`).
    /// Joined, they are masked for the secrets with a shape of their own (`maskShapes`); for what a name or a flag
    /// makes a secret too only when the screen shows rows that wide wrap (`ScreenRows.wrapsSeen`), since joined,
    /// `PASSWORD=` would take in the next row's first word, a prompt's as well. A row the read cut away may have
    /// gone on into the first row kept (`Read.joins`), so its first word is masked too, and the same for a start's
    /// last row. Counts one for each line in which it found a secret no row showed.
    static func unwrapped(_ read: Read, masked: String, commands: Bool, keepEnd: Bool) -> (text: String, count: Int) {
        var rows = ScreenRows(raw: read.text, masked: masked, commands: commands)
        // Masking keeps each line break; when it gave up and masked the whole text, nothing is left to find.
        guard rows.raw.count == rows.shown.count else { return (masked, 0) }
        rows.joinWrappedLines()
        if read.joins { rows.maskEdge(atEnd: !keepEnd) }
        return (rows.shown.joined(separator: "\n"), rows.count)
    }

    /// The text with only the secrets that have a shape of their own masked: the door's tokens, MCPRedaction's key
    /// formats and its long random runs.
    static func maskShapes(_ text: String) -> String {
        var masked = text
        var complete = true
        let mask = { (_: NSTextCheckingResult, _: NSString) -> String? in MCPRedaction.mask }
        _ = MCPRedaction.replace(RemoteAccessAuditMask.remoteToken, in: &masked, complete: &complete, mask)
        for token in MCPRedaction.tokens {
            _ = MCPRedaction.replace(token, in: &masked, complete: &complete, mask)
        }
        _ = MCPRedaction.replace(MCPRedaction.longRun, in: &masked, complete: &complete) { match, ns in
            MCPRedaction.looksRandom(ns.substring(with: match.range)) ? MCPRedaction.mask : nil
        }
        return complete ? masked : MCPRedaction.mask
    }

    /// How many cells a row takes in the terminal: two for a wide character, none for a combining mark.
    static func cells(_ row: String) -> Int {
        row.unicodeScalars.reduce(0) { total, scalar in total + cells(of: scalar) }
    }

    static func cells(of scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

/// A screen's rows as read, and as masked, for `RemoteAccessPolicy.unwrapped`.
struct ScreenRows {
    let raw: [String]
    /// As the whole screen was masked: what each decision goes by.
    let masked: [String]
    /// As they go out, with the words at the breaks masked.
    var shown: [String]
    let commands: Bool
    let widths: [Int]
    let widest: Int
    /// Two rows or more are as wide as the widest: the terminal is that wide, and rows that wide wrapped.
    let wrapsSeen: Bool
    /// Lines in which a secret no row showed was found.
    var count = 0

    init(raw text: String, masked whole: String, commands: Bool) {
        raw = text.components(separatedBy: "\n")
        masked = whole.components(separatedBy: "\n")
        shown = masked
        self.commands = commands
        widths = raw.map(RemoteAccessPolicy.cells)
        let widest = widths.max() ?? 0
        self.widest = widest
        wrapsSeen = widths.filter { $0 + 1 >= widest }.count >= 2
    }

    /// Whether the row may go on at the start of the next: it is as wide as the widest row (one cell short when a
    /// wide character went on to the next row), it ends in text, and the next row starts in text. A shorter row
    /// ended where its line did.
    func goesOn(_ row: Int) -> Bool {
        guard row + 1 < raw.count, widths[row] + 1 >= widest else { return false }
        return Self.endsInText(raw[row]) && Self.startsInText(raw[row + 1])
    }

    /// Joins each run of rows that go on into one line (`join`).
    mutating func joinWrappedLines() {
        var first = 0
        while first + 1 < raw.count {
            guard goesOn(first) else {
                first += 1
                continue
            }
            var last = first + 1
            while goesOn(last) { last += 1 }
            var found = join(first...last, masking: RemoteAccessPolicy.maskShapes)
            if wrapsSeen {
                let commands = commands
                let all = { (text: String) -> String in RemoteAccessPolicy.mask(text, commands: commands).text }
                found = join(first...last, masking: all) || found
            }
            if found { count += 1 }
            first = last
        }
    }

    /// The rows as one line. When masked together they hide what masked one by one they don't, the breaks where
    /// two rows together already do get their words masked, or every break when it takes three rows or more.
    /// True when it masked a secret no row showed masked at a break.
    mutating func join(_ lines: ClosedRange<Int>, masking mask: (String) -> String) -> Bool {
        let breaks = Array(lines.dropLast())
        guard breaks.contains(where: { mayMask(at: $0) }) else { return false }
        let alone = lines.map { mask(raw[$0]) }
        let together = mask(lines.map { raw[$0] }.joined())
        guard together != alone.joined() else { return false }
        let paired = breaks.filter { row in
            let first = row - lines.lowerBound
            return mask(raw[row] + raw[row + 1]) != alone[first] + alone[first + 1]
        }
        var found = false
        for row in paired.isEmpty ? breaks : paired {
            found = maskBreak(at: row) || found
        }
        return found
    }

    /// The word at one side of a break: the end of the row before it, or the start of the row after it.
    struct Side {
        /// The masked word ends (or starts) with a mask.
        let masked: Bool
        /// That mask hides a whole secret (`hiddenWhole`): the other side is a new line, not the rest of it.
        let hidesWhole: Bool

        init(raw: Substring, masked shown: Substring, atEnd: Bool) {
            let mask = MCPRedaction.mask
            masked = atEnd ? shown.hasSuffix(mask) : shown.hasPrefix(mask)
            let hidden = raw.unicodeScalars.count - shown.unicodeScalars.count + mask.unicodeScalars.count
            hidesWhole = masked && hidden >= RemoteAccessPolicy.hiddenWhole
        }
    }

    func sides(at row: Int) -> (end: Side, start: Side) {
        let end = Side(raw: Self.lastWord(raw[row]), masked: Self.lastWord(masked[row]), atEnd: true)
        let start = Side(raw: Self.firstWord(raw[row + 1]), masked: Self.firstWord(masked[row + 1]), atEnd: false)
        return (end, start)
    }

    /// Whether masking the break could change anything.
    func mayMask(at row: Int) -> Bool {
        let (end, start) = sides(at: row)
        return (!end.hidesWhole && !start.masked) || (!start.hidesWhole && !end.masked)
    }

    /// Masks the next row's first word, unless the row's masked end hides a whole secret, and the row's last word,
    /// unless the next row's masked start does; a word masked at the break already stays. True when it masked a
    /// secret neither row showed masked there.
    mutating func maskBreak(at row: Int) -> Bool {
        let (end, start) = sides(at: row)
        var changed = false
        if !end.hidesWhole, !start.masked {
            shown[row + 1] = Self.masking(firstWordOf: shown[row + 1])
            changed = true
        }
        if !start.hidesWhole, !end.masked {
            shown[row] = Self.masking(lastWordOf: shown[row])
            changed = true
        }
        return changed && !end.masked && !start.masked
    }

    /// The row the read stopped next to may have gone on into this edge's row: its word at that edge is masked.
    mutating func maskEdge(atEnd: Bool) {
        guard let row = atEnd ? raw.indices.last : raw.indices.first else { return }
        let mask = MCPRedaction.mask
        if atEnd, Self.endsInText(raw[row]), !masked[row].hasSuffix(mask) {
            shown[row] = Self.masking(lastWordOf: shown[row])
        } else if !atEnd, Self.startsInText(raw[row]), !masked[row].hasPrefix(mask) {
            shown[row] = Self.masking(firstWordOf: shown[row])
        }
    }

    static func endsInText(_ row: String) -> Bool {
        row.last.map { !$0.isWhitespace } ?? false
    }

    static func startsInText(_ row: String) -> Bool {
        row.first.map { !$0.isWhitespace } ?? false
    }

    static func firstWord(_ row: String) -> Substring {
        row.prefix { !$0.isWhitespace }
    }

    static func lastWord(_ row: String) -> Substring {
        let start = row.lastIndex(where: \.isWhitespace).map { row.index(after: $0) } ?? row.startIndex
        return row[start...]
    }

    static func masking(firstWordOf row: String) -> String {
        MCPRedaction.mask + row.dropFirst(firstWord(row).count)
    }

    static func masking(lastWordOf row: String) -> String {
        row.dropLast(lastWord(row).count) + MCPRedaction.mask
    }
}

/// R27's general limits: per grant, 120 calls in any 60 seconds and 3 at a time; all grants together, 6 at a time.
/// They hold on every connection, whatever its options (R61). Over a limit, the call gets
/// `RemoteAccessText.tooManyCalls` and takes no slot, so a call refused for the limits counts toward nothing. A call
/// the door refuses for another reason (its options, its arguments) takes no slot either, but `count` adds it to
/// its grant's minute.
///
/// A value with the clock passed in, as the OAuth authority is: the door keeps one under its lock. A call takes a
/// slot when it is admitted and gives it back when its answer goes out, or when its late result comes in after the
/// deadline. A slot gives back once; giving it back again frees nothing.
public struct RemoteAccessRateLimiter: Sendable {
    public static let callsPerMinute = 120
    public static let callsAtOnce = 3
    public static let allCallsAtOnce = 6
    public static let window: TimeInterval = 60

    /// A running call's place.
    public struct Slot: Hashable, Sendable {
        let number: UInt64
        public let grant: String
    }

    /// When each grant's calls of the last minute started.
    private var started: [String: [Date]] = [:]
    /// The running calls, by slot number.
    private var running: [UInt64: String] = [:]
    private var lastNumber: UInt64 = 0

    public init() {}

    /// A slot for a call from this grant, or nil when a limit is reached. A start more than a minute ago no longer
    /// counts, and neither does one after `now`, as when the clock was set back.
    public mutating func acquire(grant: String, now: Date) -> Slot? {
        let recent = recentStarts(of: grant, now: now)
        guard recent.count < Self.callsPerMinute else { return nil }
        let mine = running.values.filter { $0 == grant }.count
        guard mine < Self.callsAtOnce, running.count < Self.allCallsAtOnce else { return nil }
        lastNumber += 1
        running[lastNumber] = grant
        started[grant] = recent + [now]
        return Slot(number: lastNumber, grant: grant)
    }

    /// Counts a call that takes no slot toward its grant's calls of the last minute: one the door answers without
    /// running it, such as a tool the options leave off. So a token that sends only such calls is held to the same
    /// 120 a minute. False, counting nothing, when the grant has made 120 already.
    public mutating func count(grant: String, now: Date) -> Bool {
        let recent = recentStarts(of: grant, now: now)
        guard recent.count < Self.callsPerMinute else { return false }
        started[grant] = recent + [now]
        return true
    }

    /// The grant's starts of the last minute, after every grant's older ones are forgotten.
    private mutating func recentStarts(of grant: String, now: Date) -> [Date] {
        for (other, starts) in started {
            let recent = starts.filter { start in
                let age = now.timeIntervalSince(start)
                return age >= 0 && age < Self.window
            }
            started[other] = recent.isEmpty ? nil : recent
        }
        return started[grant] ?? []
    }

    /// Gives the slot back.
    public mutating func release(_ slot: Slot) {
        running[slot.number] = nil
    }

    /// How many calls run now.
    public var runningCount: Int { running.count }
}
