import Foundation

/// Tab completion's private channel between a zsh tab and Next Term (see ZshCompletionScript and
/// CompletionState).
///
/// Shell to app: more kinds on OSC 6973, behind the tab's nonce (ShellIntegration.parse). Every text field is
/// percent-encoded UTF-8 (each byte outside `!`…`~`, and `%`, `;` and `,`); a list's items are split by spaces.
///
///     arm ; version ; keymap ; context ; bound ; completion system ; ^I widget ; its definition ; plugins ; quieted
///     tab ; id ; folder ; LBUFFER ; RBUFFER ; PREBUFFER ; words ; word ; word unquoted ; head ; head resolved
///     comp ; id ; total ; chunk ; chunks ; stem ; stem unquoted ; text,description,group,kind …
///     done ; id ; native | inserted
///     line ; id ; left ; word ; word unquoted
///
/// App to shell: the private key `prefix`, then a kind letter, a 6-digit id, a 6-digit length and the payload
/// (`frame`). The payload is ASCII: its fields are split by `;`, and every byte outside `!`…`~`, `\` itself
/// and `;` go as `\xHH`, which the shell decodes with `printf %b`. So no control byte, no raw `\c` and no
/// byte above 0x7E ever reaches the shell's decoder.
///
/// Ids are Next Term's, per tab, increasing: it can answer "native" for its own id even when a `tab` mark
/// can't be read at all.
public enum CompletionProtocol {
    /// ESC [ 6973 ~: unbound in stock keymaps, not the start of any reply a terminal sends (DA, CPR,
    /// DECRQSS, window reports, kitty keyboard flags), and a key tmux can name with `user-keys`. Fixed once
    /// shipped: a hook on a server may be older than the app.
    public static let prefix = "\u{1b}[6973~"
    /// The hook's version, reported by `arm`.
    public static let version = 1
    /// How long the hook waits for an answer (seconds), and how long Next Term takes at most to give one.
    public static let shellWait = 0.15
    public static let answerWithin = 0.12
    /// The line and its words, in bytes, over which the hook steps back at once.
    public static let maxLineBytes = 16_384
    /// Matches sent in `comp` marks (the total is sent too), and each mark's share of them in bytes.
    public static let maxMatches = 2000
    public static let chunkBytes = 48_000
    /// How long the hook waits for anything it reads after the private key (seconds).
    public static let frameWait = 0.5
    static let idWidth = 6

    public static let markKinds: Set<Substring> = ["arm", "tab", "comp", "done", "line"]

    // MARK: shell to app

    public enum Message: Equatable, Sendable {
        case arm(Arm)
        case tab(TabReport)
        case comp(CompChunk)
        case done(id: Int, outcome: Outcome)
        case line(LineReport)
    }

    /// What the shell can take, sent at each new line and keymap change.
    public struct Arm: Equatable, Sendable {
        public var version: Int
        public var keymap: String
        public var context: String
        /// The private key is bound in this keymap.
        public var bound: Bool
        /// zsh's completion system (compinit) is loaded: zsh's own candidates fill the list.
        public var completionSystem: Bool
        /// What ^I runs, and that widget's definition ("completion:.complete-word:_main_complete", "user:…").
        public var tabWidget: String
        public var tabWidgetDefinition: String
        /// Plugins loaded that own Tab or list as you type: "autocomplete", "fzf-tab", "fzf".
        public var plugins: [String]
        /// zsh-autocomplete's as-you-type list is off in this shell.
        public var quieted: Bool

        public init(version: Int = CompletionProtocol.version, keymap: String = "main", context: String = "start", bound: Bool = true,
                    completionSystem: Bool = false, tabWidget: String = "expand-or-complete", tabWidgetDefinition: String = "builtin",
                    plugins: [String] = [], quieted: Bool = false) {
            self.version = version
            self.keymap = keymap
            self.context = context
            self.bound = bound
            self.completionSystem = completionSystem
            self.tabWidget = tabWidget
            self.tabWidgetDefinition = tabWidgetDefinition
            self.plugins = plugins
            self.quieted = quieted
        }

        /// The same as `other` but for zsh-autocomplete's state: what a config key changes mid-line.
        public func sameLine(as other: Arm?) -> Bool {
            guard var other else { return false }
            other.quieted = quieted
            return other == self
        }

        /// A line is being edited in emacs or vi insert mode, and the private key is bound there.
        public var takesKey: Bool {
            bound && ["main", "emacs", "viins"].contains(keymap) && ["start", "cont"].contains(context)
        }
    }

    /// The line, when the private Tab key reached Next Term's own engine.
    public struct TabReport: Equatable, Sendable {
        public var id: Int
        public var directory: String
        public var lbuffer: String
        public var rbuffer: String
        public var prebuffer: String
        /// zsh's own words for the command so far (PREBUFFER and LBUFFER), as typed.
        public var words: [String]
        /// The word before the cursor, as typed ("" after a blank), and unquoted by zsh.
        public var word: String
        public var unquoted: String
        /// A leading `~/` or `$NAME/` as typed, and what it names ("" when there is none).
        public var head: String
        public var resolvedHead: String
        /// A field was not valid UTF-8: Next Term steps back at once rather than wait out the time.
        public var unreadable: Bool

        public init(id: Int, directory: String, lbuffer: String, rbuffer: String = "", prebuffer: String = "", words: [String],
                    word: String, unquoted: String, head: String = "", resolvedHead: String = "", unreadable: Bool = false) {
            self.id = id
            self.directory = directory
            self.lbuffer = lbuffer
            self.rbuffer = rbuffer
            self.prebuffer = prebuffer
            self.words = words
            self.word = word
            self.unquoted = unquoted
            self.head = head
            self.resolvedHead = resolvedHead
            self.unreadable = unreadable
        }
    }

    public enum MatchKind: String, Sendable {
        case folder = "d"
        case file = "f"
        case other = ""
    }

    /// One of zsh's own matches.
    public struct Match: Equatable, Sendable {
        public var text: String
        public var description: String
        public var group: String
        public var kind: MatchKind
        /// Its place in zsh's order (1-based): what a `take` names.
        public var index: Int

        public init(text: String, description: String = "", group: String = "", kind: MatchKind = .other, index: Int) {
            self.text = text
            self.description = description
            self.group = group
            self.kind = kind
            self.index = index
        }

        /// zsh's display string for a match ("main  -- the default branch") without the match itself: what
        /// the popup shows beside it. Empty when it says nothing more.
        static func description(_ display: String, of text: String) -> String {
            var rest = Substring(display)
            if rest.hasPrefix(text) { rest = rest.dropFirst(text.count) }
            rest = rest.drop { $0 == " " }
            if rest.hasPrefix("--") { rest = rest.dropFirst(2) }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            return trimmed == text ? "" : trimmed
        }
    }

    public struct CompChunk: Equatable, Sendable {
        public var id: Int
        public var total: Int
        public var number: Int
        public var count: Int
        /// The word before the matches, as typed and unquoted: `Sources/` for `ls Sources/in`, `$` for `$HO`.
        public var stem: String
        public var stemUnquoted: String
        public var matches: [Match]

        public init(id: Int, total: Int, number: Int, count: Int, stem: String = "", stemUnquoted: String = "", matches: [Match]) {
            self.id = id
            self.total = total
            self.number = number
            self.count = count
            self.stem = stem
            self.stemUnquoted = stemUnquoted
            self.matches = matches
        }
    }

    public enum Outcome: String, Sendable {
        case native
        case inserted
    }

    /// While a list is open: the word now, or that the cursor left it.
    public struct LineReport: Equatable, Sendable {
        public var id: Int
        public var left: Bool
        public var word: String
        public var unquoted: String

        public init(id: Int, left: Bool, word: String = "", unquoted: String = "") {
            self.id = id
            self.left = left
            self.word = word
            self.unquoted = unquoted
        }
    }

    /// Parses a completion mark's value (after `kind;`). nil: malformed.
    public static func parse(kind: Substring, value: String) -> Message? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        switch kind {
        case "arm": return parseArm(fields)
        case "tab": return parseTab(fields)
        case "comp": return parseComp(fields)
        case "done":
            guard fields.count == 2, let id = number(fields[0]), let outcome = Outcome(rawValue: String(fields[1])) else { return nil }
            return .done(id: id, outcome: outcome)
        case "line": return parseLine(fields)
        default: return nil
        }
    }

    private static func parseArm(_ fields: [Substring]) -> Message? {
        guard fields.count == 9, let version = number(fields[0]) else { return nil }
        let texts = fields.map { text($0).value }
        let plugins = texts[7].split(separator: " ").map(String.init)
        return .arm(Arm(version: version, keymap: texts[1], context: texts[2], bound: fields[3] == "1",
                        completionSystem: fields[4] == "1", tabWidget: texts[5], tabWidgetDefinition: texts[6],
                        plugins: plugins, quieted: fields[8] == "1"))
    }

    private static func parseTab(_ fields: [Substring]) -> Message? {
        guard fields.count == 10, let id = number(fields[0]) else { return nil }
        var unreadable = false
        func field(_ index: Int) -> String {
            let decoded = text(fields[index])
            if !decoded.valid { unreadable = true }
            return decoded.value
        }
        let words = fields[5].split(separator: " ", omittingEmptySubsequences: false).map { item -> String in
            let decoded = text(item)
            if !decoded.valid { unreadable = true }
            return decoded.value
        }
        let report = TabReport(id: id, directory: field(1), lbuffer: field(2), rbuffer: field(3), prebuffer: field(4),
                               words: fields[5].isEmpty ? [] : words, word: field(6), unquoted: field(7), head: field(8),
                               resolvedHead: field(9))
        var marked = report
        marked.unreadable = unreadable
        return .tab(marked)
    }

    private static func parseComp(_ fields: [Substring]) -> Message? {
        guard fields.count == 7, let id = number(fields[0]), let total = number(fields[1]), let chunk = number(fields[2]),
              let count = number(fields[3]), chunk >= 1, chunk <= count, count <= 1000 else { return nil }
        var matches: [Match] = []
        if !fields[6].isEmpty {
            for item in fields[6].split(separator: " ") {
                let parts = item.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 4 else { return nil }
                let kind = MatchKind(rawValue: String(parts[3])) ?? .other
                let shown = text(parts[0]).value
                let description = Match.description(text(parts[1]).value, of: shown)
                matches.append(Match(text: shown, description: description, group: text(parts[2]).value, kind: kind, index: 0))
            }
        }
        return .comp(CompChunk(id: id, total: total, number: chunk, count: count, stem: text(fields[4]).value,
                               stemUnquoted: text(fields[5]).value, matches: matches))
    }

    private static func parseLine(_ fields: [Substring]) -> Message? {
        guard fields.count >= 2, let id = number(fields[0]) else { return nil }
        if fields[1] == "1" { return .line(LineReport(id: id, left: true)) }
        guard fields[1] == "0", fields.count == 4 else { return nil }
        let word = text(fields[2]), unquoted = text(fields[3])
        // A word Next Term can't read is one it can't filter by: the cursor may as well have left it.
        guard word.valid, unquoted.valid else { return .line(LineReport(id: id, left: true)) }
        return .line(LineReport(id: id, left: false, word: word.value, unquoted: unquoted.value))
    }

    private static func number(_ field: Substring) -> Int? {
        guard !field.isEmpty, field.count <= 9, field.allSatisfy(\.isASCII), let value = Int(field), value >= 0 else { return nil }
        return value
    }

    /// A percent-encoded field: its text, and whether its bytes were valid UTF-8 (when not, the text shows
    /// U+FFFD in their place).
    static func text(_ field: Substring) -> (value: String, valid: Bool) {
        let bytes = percentDecode(field)
        if let value = String(bytes: bytes, encoding: .utf8) { return (value, true) }
        return (String(decoding: bytes, as: UTF8.self), false)
    }

    /// `%HH` becomes its byte; anything else is kept as it is, as the shell never sends it unencoded.
    static func percentDecode(_ field: Substring) -> [UInt8] {
        let bytes = Array(field.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: app to shell

    public enum Key: UInt8, Sendable {
        /// A real Tab.
        case tab = 0x74 // t
        /// The answer to `tab`: native, open, or insert with the new word (Next Term's own engine only).
        case answer = 0x61 // a
        /// A row chosen, or the list closed; or Suggest a Command's line.
        case take = 0x6B // k
        /// zsh's own list can't be shown: zsh runs its own Tab.
        case native = 0x6E // n
        /// A plugin choice changed: zsh-autocomplete's list off (q1) or on (q0) in this shell. On a server: how long
        /// a Tab waits for an answer (w<ms>, 150 to 600).
        case config = 0x63 // c
    }

    /// The bytes for one private key: the prefix, the kind, the id, the payload's length and the payload.
    public static func frame(_ key: Key, id: Int, fields: [String] = []) -> [UInt8] {
        var payload: [UInt8] = []
        for (index, field) in fields.enumerated() {
            if index > 0 { payload.append(UInt8(ascii: ";")) }
            payload += escape(field)
        }
        var out = Array(prefix.utf8)
        out.append(key.rawValue)
        out += Array(padded(id % 1_000_000).utf8)
        out += Array(padded(payload.count).utf8)
        return out + payload
    }

    private static func padded(_ value: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, idWidth - digits.count)) + digits
    }

    /// Every byte outside `!`…`~`, and `\` and `;`, as `\xHH`.
    static func escape(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        for byte in text.utf8 {
            if byte >= 0x21, byte <= 0x7E, byte != UInt8(ascii: "\\"), byte != UInt8(ascii: ";") {
                out.append(byte)
            } else {
                out += Array("\\x".utf8)
                out += Array(hex(byte).utf8)
            }
        }
        return out
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    /// The answers to a `tab` report (Next Term's own engine).
    public static func nativeAnswer(id: Int) -> [UInt8] { frame(.answer, id: id, fields: ["n"]) }
    public static func openAnswer(id: Int) -> [UInt8] { frame(.answer, id: id, fields: ["o"]) }
    public static func insertAnswer(id: Int, word: String) -> [UInt8] { frame(.answer, id: id, fields: ["i", word]) }

    /// A row of Next Term's own list: the word the shell last reported, and the word that replaces it.
    public static func takeWord(id: Int, old: String, new: String) -> [UInt8] { frame(.take, id: id, fields: ["w", old, new]) }
    /// A row of zsh's own list, by its index, with the word the shell last reported.
    public static func takeMatch(id: Int, old: String, index: Int) -> [UInt8] { frame(.take, id: id, fields: ["m", old, String(index)]) }
    /// The list closed with nothing chosen: the shell stops reporting the line.
    public static func close(id: Int) -> [UInt8] { frame(.take, id: id, fields: ["c"]) }
    /// Suggest a Command's answer: the whole line, replaced (one line or several). It never runs.
    public static func takeLine(_ line: String) -> [UInt8] { frame(.take, id: 0, fields: ["l", line]) }
    /// A server's round trip: how long its hook waits for an answer to a `tab` report (150 to 600 ms).
    public static func wait(seconds: Double) -> [UInt8] {
        let milliseconds = min(600, max(150, Int((seconds * 1000).rounded())))
        return frame(.config, id: 0, fields: ["w\(milliseconds)"])
    }
}

/// zsh's matches arrive in chunks; a list is shown only once every chunk for its id is in.
public struct CompAssembler: Sendable {
    public private(set) var id: Int?
    public private(set) var total = 0
    private var chunks: [Int: [CompletionProtocol.Match]] = [:]
    private var count = 0

    public init() {}

    /// Adds a chunk; returns the whole list, numbered in zsh's order, once the last chunk is in. A chunk for
    /// another id starts over.
    public mutating func add(_ chunk: CompletionProtocol.CompChunk) -> [CompletionProtocol.Match]? {
        if chunk.id != id || chunk.count != count {
            id = chunk.id
            count = chunk.count
            total = chunk.total
            chunks = [:]
        }
        chunks[chunk.number] = chunk.matches
        guard chunks.count == count else { return nil }
        var all: [CompletionProtocol.Match] = []
        for number in 1...count {
            guard let part = chunks[number] else { return nil }
            all += part
        }
        for index in all.indices { all[index].index = index + 1 }
        return all
    }

    /// Whether some chunks for `id` came but not all of them.
    public func isIncomplete(_ id: Int) -> Bool { self.id == id && chunks.count < count }

    public mutating func reset() {
        id = nil
        chunks = [:]
        count = 0
        total = 0
    }
}
