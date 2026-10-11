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
}

/// Decides each remote tool call before it runs, and shapes its result before it goes back (the plan's U5). Pure:
/// the door calls `decide` before the main thread, and `shape` on whatever thread the result comes back on.
///
/// The control options' own rules (text, keys, commands, the control rate limit) join this policy with the control
/// options. The Secrets options are a stub until the secret tools are in this base: they name no tool, so the
/// secret tools get "not available" like any tool no option names. The import tools stay local the same way.
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
        return .allow(clamped(arguments, tool: name, properties: properties))
    }

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
    /// - JSON is masked string by string, keys included: the door's own tokens, then `MCPRedaction`. What was
    ///   masked is added to `"redacted"`, or to the count a tool gave already. Text that comes back from
    ///   `MCPRedaction` as it went in counts nothing, and neither does a mask made before (`stale`), so a tool's own
    ///   masks are not counted twice.
    /// - get_editor_selection's `text` is cut to 16,000 characters.
    /// - Then the whole result is held to 64,000 characters by cutting its longest strings at a line break, with
    ///   `"truncated": true` and a note on how to read the rest. A screen keeps its last lines; anything else
    ///   keeps its start.
    /// - Text that is not JSON, error results included, is masked and cut as text.
    ///
    /// Characters are Unicode scalars, as JSON Schema counts them. A result that needs nothing keeps its text as it
    /// came, and a shaped result shaped again stays the same. An error that says a tab id is unknown gets the
    /// remote text, which says why that may be.
    public static func shape(_ result: MCPServer.CallResult, tool: String) -> MCPServer.CallResult {
        var text = result.text
        if result.isError, text.hasPrefix(tabGone) { text = RemoteAccessText.oldTab }
        let shaped: String
        if let value = parsedJSON(text) {
            shaped = shapeJSON(value, text: text, tool: tool)
        } else {
            shaped = shapeText(text)
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

    static func shapeJSON(_ value: Any, text original: String, tool: String) -> String {
        let keepEnd = keepsEnd(tool)
        var count = 0
        var shaped = masked(value, keepEnd: keepEnd, count: &count)
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
        // Nothing masked or cut, and short enough: the text goes as it came.
        let cap = RemoteAccessLimits.resultChars
        if count == 0, notes.isEmpty, original.unicodeScalars.count <= cap { return original }
        if count > 0 { shaped = counted(shaped, count) }
        return capped(shaped, notes: notes, tool: tool)
    }

    /// Every string masked, keys included, with how many were.
    static func masked(_ value: Any, keepEnd: Bool, count: inout Int) -> Any {
        switch value {
        case let text as String:
            let found = mask(ahead(text, keepEnd: keepEnd))
            count += found.count
            return found.text
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, item) in object {
                let name = mask(key)
                count += name.count
                result[name.text] = masked(item, keepEnd: keepEnd, count: &count)
            }
            return result
        case let array as [Any]:
            return array.map { masked($0, keepEnd: keepEnd, count: &count) }
        default:
            return value
        }
    }

    /// Text past the cap is never sent, so a long string is read only this far past it before it is masked: the
    /// cut it gets later always falls inside what was masked, so a secret at the cut is masked whole, not shown
    /// in part.
    static func ahead(_ text: String, keepEnd: Bool) -> String {
        let limit = RemoteAccessLimits.resultChars + RemoteAccessAuditMask.readLength
        guard text.utf8.count > limit else { return text }
        return keepEnd ? suffix(text, scalars: limit) : RemoteAccessOAuth.prefix(text, scalars: limit)
    }

    /// The text with secrets masked, and how many were: the door's own tokens first, so no pattern of
    /// `MCPRedaction` can split one, then `MCPRedaction`. When a pattern could not read the whole text, the text
    /// goes as one mask. The audit log masks with it too (`RemoteAccessAuditMask.whole`).
    static func mask(_ text: String) -> (text: String, count: Int) {
        var masked = text
        var complete = true
        let tokens = MCPRedaction.replace(RemoteAccessAuditMask.remoteToken, in: &masked, complete: &complete) { _, _ in
            MCPRedaction.mask
        }
        let redacted = MCPRedaction.redact(masked, maskingRun: { (run: String) -> String? in
            MCPRedaction.looksRandom(run) ? MCPRedaction.mask : nil
        })
        guard complete, redacted.complete else { return (MCPRedaction.mask, 1) }
        guard redacted.text != masked else { return (masked, tokens) }
        // The text changed, so something new was masked: at least one, so a masked result is never sent as it came.
        let found = max(1, redacted.count - stale(in: masked))
        return (redacted.text, tokens + found)
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
        value = noted(value, notes + [capNote(tool)])
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

    /// Text that is not JSON, masked and held to 64,000 characters with a note at its end.
    static func shapeText(_ text: String) -> String {
        let found = mask(ahead(text, keepEnd: false))
        let cap = RemoteAccessLimits.resultChars
        guard found.text.unicodeScalars.count > cap else { return found.text }
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

/// R27's general limits: per grant, 120 calls in any 60 seconds and 3 at a time; all grants together, 6 at a time.
/// They hold on every connection, whatever its options (R61). Over a limit, the call gets
/// `RemoteAccessText.tooManyCalls` and takes no slot, so a refused call counts toward nothing.
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
        for (other, starts) in started {
            let recent = starts.filter { start in
                let age = now.timeIntervalSince(start)
                return age >= 0 && age < Self.window
            }
            started[other] = recent.isEmpty ? nil : recent
        }
        let recent = started[grant] ?? []
        guard recent.count < Self.callsPerMinute else { return nil }
        let mine = running.values.filter { $0 == grant }.count
        guard mine < Self.callsAtOnce, running.count < Self.allCallsAtOnce else { return nil }
        lastNumber += 1
        running[lastNumber] = grant
        started[grant] = recent + [now]
        return Slot(number: lastNumber, grant: grant)
    }

    /// Gives the slot back.
    public mutating func release(_ slot: Slot) {
        running[slot.number] = nil
    }

    /// How many calls run now.
    public var runningCount: Int { running.count }
}
