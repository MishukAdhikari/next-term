import Foundation

// A static scan of a Lua config (WezTerm's wezterm.lua, Kaku's kaku.lua): the file is parsed, never run, and only
// values written out as literals are kept: strings, numbers, booleans, tables of them, and calls such as
// `wezterm.font('Fira Code')` or `act.SplitHorizontal { … }` whose arguments are literals. A value that needs Lua
// to work out (a variable, an operator, a function, anything inside an `if`, a loop or a function body) is only
// named, as set by code. Limits keep a hostile file small: its size, its tokens and how deep it nests.

/// A value in a Lua config as far as reading it (not running it) can tell.
indirect enum LuaValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case none
    /// A table: its positional items in order, and its named fields.
    case table(items: [LuaValue], fields: [String: LuaValue])
    /// A dotted name, aliases resolved: `wezterm.action.ToggleFullScreen`.
    case name(String)
    /// A call of a dotted name: `wezterm.font` with its arguments.
    case call(String, [LuaValue])
    /// Anything that needs Lua to work out.
    case computed

    var string: String? { if case .string(let value) = self { return value } else { return nil } }
    var number: Double? { if case .number(let value) = self { return value } else { return nil } }
    var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }

    var items: [LuaValue]? { if case .table(let items, _) = self { return items } else { return nil } }
    var fields: [String: LuaValue]? { if case .table(_, let fields) = self { return fields } else { return nil } }

    subscript(_ field: String) -> LuaValue? { fields?[field] }

    /// Written out in the file: no variable, no operator, and no call or name but WezTerm's own (`wezterm.font`,
    /// `wezterm.action.Copy`).
    var isWrittenOut: Bool {
        switch self {
        case .computed: return false
        case .table(let items, let fields): return items.allSatisfy(\.isWrittenOut) && fields.values.allSatisfy(\.isWrittenOut)
        case .name(let name): return name.hasPrefix("wezterm.")
        case .call(let name, let args): return name.hasPrefix("wezterm.") && args.allSatisfy(\.isWrittenOut)
        default: return true
        }
    }
}

/// What a Lua config file sets, read without running it.
struct LuaConfigScan {
    /// The config table's fields written out as literals (`config.font_size = 14`, or a `return { … }` table).
    var fields: [String: LuaValue] = [:]
    /// Fields set by code: a value worked out by Lua, or an assignment inside a block. In the order seen.
    var computed: [String] = []
    /// Tables added to the config's key list with `table.insert(config.keys, { … })` (Kaku's way).
    var addedKeys: [LuaValue] = []
    /// Tables written out with some code inside (a key list with one `action_callback`).
    var partlyComputed: [String] = []
    /// The file couldn't be read as Lua (then nothing else is set).
    var unreadable = false

    static let maxBytes = 1 << 20
    static let maxTokens = 200_000
    static let maxDepth = 100

    init(_ text: String) {
        guard text.utf8.count <= Self.maxBytes, let tokens = LuaTokens.read(text), tokens.count <= Self.maxTokens else {
            unreadable = true
            return
        }
        var parser = LuaParser(tokens: tokens)
        do {
            try parser.chunk()
        } catch {
            unreadable = true
            return
        }
        self = parser.result()
    }

    private init(fields: [String: LuaValue], computed: [String], addedKeys: [LuaValue]) {
        self.fields = fields
        self.computed = computed
        self.addedKeys = addedKeys
    }

    fileprivate static func made(fields: [String: LuaValue], computed: [String], addedKeys: [LuaValue]) -> LuaConfigScan {
        LuaConfigScan(fields: fields, computed: computed, addedKeys: addedKeys)
    }
}

// MARK: tokens

enum LuaToken: Equatable {
    case name(String)
    case string(String)
    case number(Double)
    case symbol(String)
}

enum LuaTokens {
    static let keywords: Set<String> = ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                                        "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]

    /// The tokens of `text`, comments dropped; nil when a string or comment is left open or a character isn't Lua's.
    static func read(_ text: String) -> [LuaToken]? {
        let scalars = Array(text.unicodeScalars)
        var tokens: [LuaToken] = []
        var index = 0
        func at(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{C}" || scalar == "\u{B}" {
                index += 1
                continue
            }
            if scalar == "-" && at(1) == "-" {
                index += 2
                if let level = longBracket(scalars, at: index) {
                    guard let end = closeLongBracket(scalars, from: index + level + 2, level: level) else { return nil }
                    index = end
                } else {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                }
                continue
            }
            if scalar == "[", let level = longBracket(scalars, at: index) {
                var start = index + level + 2
                if start < scalars.count, scalars[start] == "\r" { start += 1 }
                if start < scalars.count, scalars[start] == "\n" { start += 1 }
                guard let end = closeLongBracket(scalars, from: start, level: level) else { return nil }
                var value = String.UnicodeScalarView()
                value.append(contentsOf: scalars[start..<(end - level - 2)])
                tokens.append(.string(String(value)))
                index = end
                continue
            }
            if scalar == "\"" || scalar == "'" {
                guard let (value, end) = quoted(scalars, from: index) else { return nil }
                tokens.append(.string(value))
                index = end
                continue
            }
            if scalar.properties.isAlphabetic || scalar == "_" {
                var name = String.UnicodeScalarView()
                while index < scalars.count, scalars[index].properties.isAlphabetic || scalars[index] == "_"
                    || scalars[index].properties.numericType != nil {
                    name.append(scalars[index])
                    index += 1
                }
                tokens.append(.name(String(name)))
                continue
            }
            if scalar.properties.numericType != nil && scalar.isASCII || (scalar == "." && at(1)?.properties.numericType != nil) {
                var text = ""
                while index < scalars.count {
                    let next = scalars[index]
                    let exponentSign = (next == "+" || next == "-") && text.last.map { "eEpP".contains($0) } == true && !text.hasPrefix("0x")
                        || (next == "+" || next == "-") && text.last.map { "pP".contains($0) } == true
                    guard next.isASCII, next.properties.isAlphabetic || next.properties.numericType != nil || next == "." || exponentSign else { break }
                    text.unicodeScalars.append(next)
                    index += 1
                }
                guard let value = number(text) else { return nil }
                tokens.append(.number(value))
                continue
            }
            let three = String(String.UnicodeScalarView(scalars[index..<min(index + 3, scalars.count)]))
            if three == "..." {
                tokens.append(.symbol("..."))
                index += 3
                continue
            }
            let two = String(three.prefix(2))
            if ["==", "~=", "<=", ">=", "..", "::", "//", "<<", ">>"].contains(two) {
                tokens.append(.symbol(two))
                index += 2
                continue
            }
            guard "+-*/%^#&~|<>=(){}[];:,.".unicodeScalars.contains(scalar) else { return nil }
            tokens.append(.symbol(String(scalar)))
            index += 1
            if tokens.count > LuaConfigScan.maxTokens { return nil }
        }
        return tokens
    }

    /// The level of a long bracket opening at `index` (`[[` is 0, `[==[` is 2), or nil.
    static func longBracket(_ scalars: [Unicode.Scalar], at index: Int) -> Int? {
        guard index < scalars.count, scalars[index] == "[" else { return nil }
        var level = 0
        var cursor = index + 1
        while cursor < scalars.count, scalars[cursor] == "=" {
            level += 1
            cursor += 1
        }
        return cursor < scalars.count && scalars[cursor] == "[" ? level : nil
    }

    /// Just past the `]==]` that closes a long bracket of `level`, or nil when it is never closed.
    static func closeLongBracket(_ scalars: [Unicode.Scalar], from start: Int, level: Int) -> Int? {
        var index = start
        while index < scalars.count {
            if scalars[index] == "]" {
                var cursor = index + 1
                var count = 0
                while cursor < scalars.count, scalars[cursor] == "=" {
                    count += 1
                    cursor += 1
                }
                if count == level, cursor < scalars.count, scalars[cursor] == "]" { return cursor + 1 }
            }
            index += 1
        }
        return nil
    }

    /// A '…' or "…" string with Lua's escapes; nil when it isn't closed on its line.
    static func quoted(_ scalars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        let quote = scalars[start]
        var index = start + 1
        var value = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == quote { return (String(value), index + 1) }
            if scalar == "\n" { return nil }
            if scalar == "\\" {
                index += 1
                guard index < scalars.count else { return nil }
                let escaped = scalars[index]
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "a": value.append("\u{7}")
                case "b": value.append("\u{8}")
                case "f": value.append("\u{C}")
                case "v": value.append("\u{B}")
                case "\n": value.append("\n")
                case "z":
                    while index + 1 < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index + 1]) { index += 1 }
                default:
                    // \\ \" \' as themselves; \ddd, \xhh and \u{…} are kept as written (no setting needs them).
                    value.append(escaped)
                }
                index += 1
                continue
            }
            value.append(scalar)
            index += 1
        }
        return nil
    }

    static func number(_ text: String) -> Double? {
        let lower = text.lowercased()
        if lower.hasPrefix("0x") {
            guard let value = UInt64(lower.dropFirst(2), radix: 16) else { return nil }
            return Double(value)
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

// MARK: parsing

private struct LuaError: Error {}

/// A Lua 5.4 parser that keeps literal values and only notes the rest. Blocks are parsed (so their ends are
/// found exactly) but their assignments only count as set by code.
private struct LuaParser {
    let tokens: [LuaToken]
    var index = 0
    var depth = 0
    /// Nested blocks we are inside (0: the file's own top level).
    var blocks = 0
    /// Top-level locals that stand for other names: `local act = wezterm.action`, `local w = require 'wezterm'`.
    var aliases: [String: String] = [:]
    /// Literal fields set on each top-level table name, by dotted path, and the tables they started as.
    var assigned: [String: [(path: [String], value: LuaValue)]] = [:]
    var initial: [String: LuaValue] = [:]
    /// Fields set by code, by table name.
    var computed: [String: [String]] = [:]
    var added: [String: [LuaValue]] = [:]
    var returned: LuaValue?
    /// The local the file returns, when it returns one by name (`return config`).
    var returnedName: String?

    init(tokens: [LuaToken]) { self.tokens = tokens }

    var peek: LuaToken? { index < tokens.count ? tokens[index] : nil }

    func peekIs(_ symbol: String) -> Bool {
        switch peek {
        case .symbol(let value)?, .name(let value)?: return value == symbol
        default: return false
        }
    }

    mutating func next() -> LuaToken? {
        defer { index += 1 }
        return peek
    }

    mutating func expect(_ symbol: String) throws {
        guard peekIs(symbol) else { throw LuaError() }
        index += 1
    }

    mutating func accept(_ symbol: String) -> Bool {
        guard peekIs(symbol) else { return false }
        index += 1
        return true
    }

    mutating func name() throws -> String {
        guard case .name(let value)? = peek, !LuaTokens.keywords.contains(value) else { throw LuaError() }
        index += 1
        return value
    }

    mutating func enter() throws {
        depth += 1
        guard depth <= LuaConfigScan.maxDepth else { throw LuaError() }
    }

    // MARK: statements

    mutating func chunk() throws {
        try block()
        guard peek == nil else { throw LuaError() }
    }

    func blockEnds() -> Bool {
        guard let token = peek else { return true }
        if case .name(let value) = token { return ["end", "else", "elseif", "until"].contains(value) }
        return false
    }

    mutating func block() throws {
        try enter()
        defer { depth -= 1 }
        while !blockEnds() {
            if peekIs("return") {
                index += 1
                if blocks == 0, case .name(let name)? = peek, index + 1 >= tokens.count || tokens[index + 1] == .symbol(";") {
                    returnedName = name
                }
                var values: [LuaValue] = []
                if !blockEnds() && !peekIs(";") { values = try expressionList() }
                _ = accept(";")
                if blocks == 0 { returned = values.first }
                break
            }
            try statement()
        }
    }

    /// A block inside the file (an `if`, a loop, a function body): parsed, its assignments counted as code.
    mutating func innerBlock() throws {
        blocks += 1
        defer { blocks -= 1 }
        try block()
    }

    mutating func statement() throws {
        guard let token = peek else { throw LuaError() }
        if case .symbol(";") = token {
            index += 1
            return
        }
        if case .symbol("::") = token {
            index += 1
            _ = try name()
            try expect("::")
            return
        }
        guard case .name(let word) = token, LuaTokens.keywords.contains(word) else { return try expressionStatement() }
        index += 1
        switch word {
        case "break": return
        case "goto": _ = try name()
        case "do":
            try innerBlock()
            try expect("end")
        case "while":
            _ = try expression()
            try expect("do")
            try innerBlock()
            try expect("end")
        case "repeat":
            try innerBlock()
            try expect("until")
            _ = try expression()
        case "if":
            _ = try expression()
            try expect("then")
            try innerBlock()
            while accept("elseif") {
                _ = try expression()
                try expect("then")
                try innerBlock()
            }
            if accept("else") { try innerBlock() }
            try expect("end")
        case "for":
            _ = try name()
            if accept("=") {
                _ = try expressionList()
            } else {
                while accept(",") { _ = try name() }
                try expect("in")
                _ = try expressionList()
            }
            try expect("do")
            try innerBlock()
            try expect("end")
        case "function":
            var target = [try name()]
            while accept(".") { target.append(try name()) }
            if accept(":") { target.append(try name()) }
            try functionBody()
            note(target, .computed)
        case "local":
            if accept("function") {
                _ = try name()
                return try functionBody()
            }
            var names = [try name()]
            _ = attribute()
            while accept(",") {
                names.append(try name())
                _ = attribute()
            }
            guard accept("=") else { return }
            let values = try expressionList()
            if blocks == 0, names.count == 1, let value = values.first { local(names[0], value) }
        default:
            throw LuaError()
        }
    }

    /// `<const>` or `<close>` after a local's name.
    mutating func attribute() -> Bool {
        guard peekIs("<") else { return false }
        index += 1
        _ = try? name()
        _ = accept(">")
        return true
    }

    /// A top-level local: an alias of another name, or a table the config may be.
    mutating func local(_ name: String, _ value: LuaValue) {
        switch value {
        case .name(let target): aliases[name] = target
        case .call("require", let args) where args.first?.string == "wezterm": aliases[name] = "wezterm"
        case .table: initial[name] = value
        case .call("wezterm.config_builder", _): initial[name] = .table(items: [], fields: [:])
        default: break
        }
    }

    /// An assignment or a call.
    mutating func expressionStatement() throws {
        var targets: [Target] = [try suffixed()]
        guard peekIs("=") || peekIs(",") else {
            if let call = targets.first?.call { insertion(call) }
            return
        }
        while accept(",") { targets.append(try suffixed()) }
        try expect("=")
        let values = try expressionList()
        for (offset, target) in targets.enumerated() {
            guard let path = target.path, path.count >= 2 else { continue }
            note(path, offset < values.count ? values[offset] : .computed)
        }
    }

    /// `table.insert(config.keys, { … })`.
    mutating func insertion(_ call: (name: String, args: [LuaValue], targets: [[String]])) {
        guard call.name == "table.insert", call.targets.count >= 1, let list = call.targets.first, list.count == 2 else { return }
        if blocks == 0, call.args.count == 2 {
            added[list[0], default: []].append(call.args[1])
        } else {
            computed[list[0], default: []].append(list[1])
        }
    }

    /// A value set at `path` (`["config", "colors", "foreground"]`): kept when it is a literal at the top level.
    mutating func note(_ path: [String], _ value: LuaValue) {
        guard let table = path.first else { return }
        let field = Array(path.dropFirst())
        guard !field.isEmpty else { return }
        // A table is kept whole even with code in it; the result names it as partly code.
        var isTable = false
        if case .table = value { isTable = true }
        if blocks == 0, isTable || value.isWrittenOut {
            assigned[table, default: []].append((field, value))
        } else {
            computed[table, default: []].append(field.joined(separator: "."))
        }
    }

    // MARK: expressions

    /// What an assignment's left side or a call statement is: a dotted path of names (`config.colors`), and the
    /// call it makes, with each argument's dotted path when it is one.
    struct Target {
        var path: [String]?
        var call: (name: String, args: [LuaValue], targets: [[String]])?
    }

    mutating func suffixed() throws -> Target {
        var path: [String]?
        var dotted: String?
        if accept("(") {
            _ = try expression()
            try expect(")")
        } else {
            let first = try name()
            path = [first]
            dotted = resolve(first)
        }
        var call: (name: String, args: [LuaValue], targets: [[String]])?
        while true {
            if accept(".") {
                let field = try name()
                path?.append(field)
                dotted = dotted.map { $0 + "." + field }
                call = nil
            } else if accept("[") {
                let key = try expression()
                try expect("]")
                if let text = key.string { path?.append(text) } else { path = nil }
                dotted = nil
                call = nil
            } else if accept(":") {
                _ = try name()
                _ = try arguments()
                path = nil
                dotted = nil
                call = nil
            } else if startsArguments() {
                let (args, targets) = try argumentsWithPaths()
                call = dotted.map { ($0, args, targets) }
                path = nil
                dotted = nil
            } else {
                break
            }
        }
        return Target(path: path, call: call)
    }

    func startsArguments() -> Bool {
        switch peek {
        case .symbol("(")?, .symbol("{")?, .string?: return true
        default: return false
        }
    }

    mutating func arguments() throws -> [LuaValue] { try argumentsWithPaths().0 }

    /// A call's arguments, and for each a dotted path when it is one (for `table.insert(config.keys, …)`).
    mutating func argumentsWithPaths() throws -> ([LuaValue], [[String]]) {
        if case .string(let text)? = peek {
            index += 1
            return ([.string(text)], [])
        }
        if peekIs("{") { return ([try table()], []) }
        try expect("(")
        var values: [LuaValue] = []
        var paths: [[String]] = []
        if !peekIs(")") {
            repeat {
                let start = index
                values.append(try expression())
                paths.append(dottedPath(from: start, to: index) ?? [])
            } while accept(",")
        }
        try expect(")")
        return (values, paths)
    }

    /// The names of `a.b.c` when the tokens from `start` to `end` are exactly that.
    func dottedPath(from start: Int, to end: Int) -> [String]? {
        var names: [String] = []
        var expectName = true
        for token in tokens[start..<end] {
            switch token {
            case .name(let value) where expectName && !LuaTokens.keywords.contains(value):
                names.append(value)
                expectName = false
            case .symbol(".") where !expectName:
                expectName = true
            default:
                return nil
            }
        }
        return expectName ? nil : names
    }

    func resolve(_ name: String) -> String { aliases[name] ?? name }

    mutating func expressionList() throws -> [LuaValue] {
        var values = [try expression()]
        while accept(",") { values.append(try expression()) }
        return values
    }

    static let binary: [String: (left: Int, right: Int)] = [
        "or": (1, 1), "and": (2, 2), "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3), "~=": (3, 3), "==": (3, 3),
        "|": (4, 4), "~": (5, 5), "&": (6, 6), "<<": (7, 7), ">>": (7, 7), "..": (9, 8), "+": (10, 10), "-": (10, 10),
        "*": (11, 11), "/": (11, 11), "//": (11, 11), "%": (11, 11), "^": (14, 13),
    ]

    mutating func expression(limit: Int = 0) throws -> LuaValue {
        try enter()
        defer { depth -= 1 }
        var value: LuaValue
        if peekIs("not") || peekIs("#") || peekIs("~") || peekIs("-") {
            let negative = peekIs("-")
            index += 1
            let operand = try expression(limit: 12)
            if negative, case .number(let number) = operand { value = .number(-number) } else { value = .computed }
        } else {
            value = try simple()
        }
        while let op = binaryOperator(), let priority = Self.binary[op], priority.left > limit {
            index += 1
            _ = try expression(limit: priority.right)
            value = .computed
        }
        return value
    }

    func binaryOperator() -> String? {
        switch peek {
        case .symbol(let value)?: return Self.binary[value] != nil ? value : nil
        case .name(let value)?: return value == "and" || value == "or" ? value : nil
        default: return nil
        }
    }

    mutating func simple() throws -> LuaValue {
        guard let token = peek else { throw LuaError() }
        switch token {
        case .number(let value):
            index += 1
            return .number(value)
        case .string(let value):
            index += 1
            return .string(value)
        case .symbol("{"):
            return try table()
        case .symbol("..."):
            index += 1
            return .computed
        case .name("nil"):
            index += 1
            return .none
        case .name("true"):
            index += 1
            return .bool(true)
        case .name("false"):
            index += 1
            return .bool(false)
        case .name("function"):
            index += 1
            try functionBody()
            return .computed
        default:
            let target = try suffixedValue()
            return target
        }
    }

    /// A name, a call or an index as a value.
    mutating func suffixedValue() throws -> LuaValue {
        if accept("(") {
            let inner = try expression()
            try expect(")")
            return try suffixes(on: inner, dotted: nil)
        }
        let first = try name()
        return try suffixes(on: .name(resolve(first)), dotted: resolve(first))
    }

    mutating func suffixes(on start: LuaValue, dotted start2: String?) throws -> LuaValue {
        var value = start
        var dotted = start2
        while true {
            if accept(".") {
                let field = try name()
                dotted = dotted.map { $0 + "." + field }
                value = dotted.map(LuaValue.name) ?? .computed
            } else if accept("[") {
                _ = try expression()
                try expect("]")
                dotted = nil
                value = .computed
            } else if accept(":") {
                _ = try name()
                _ = try arguments()
                dotted = nil
                value = .computed
            } else if startsArguments() {
                let args = try arguments()
                value = dotted.map { .call($0, args) } ?? .computed
                dotted = nil
            } else {
                return value
            }
        }
    }

    mutating func table() throws -> LuaValue {
        try enter()
        defer { depth -= 1 }
        try expect("{")
        var items: [LuaValue] = []
        var fields: [String: LuaValue] = [:]
        var literal = true
        while !peekIs("}") {
            if accept("[") {
                let key = try expression()
                try expect("]")
                try expect("=")
                let value = try expression()
                if let text = key.string { fields[text] = value } else { literal = false }
            } else if case .name(let field)? = peek, !LuaTokens.keywords.contains(field),
                      index + 1 < tokens.count, tokens[index + 1] == .symbol("=") {
                index += 2
                fields[field] = try expression()
            } else {
                items.append(try expression())
            }
            guard accept(",") || accept(";") else { break }
        }
        try expect("}")
        return literal ? .table(items: items, fields: fields) : .computed
    }

    /// `(params) block end`: parsed for its end, its assignments counted as code.
    mutating func functionBody() throws {
        try expect("(")
        if !peekIs(")") {
            repeat {
                if accept("...") { break }
                _ = try name()
            } while accept(",")
        }
        try expect(")")
        try innerBlock()
        try expect("end")
    }

    // MARK: result

    /// The config's fields: the table the file returns, as written out and then as assigned field by field.
    func result() -> LuaConfigScan {
        var fields: [String: LuaValue] = [:]
        var computedFields: [String] = []
        var addedKeys: [LuaValue] = []
        if let name = returnedName {
            fields = initial[name]?.fields ?? [:]
            for (path, value) in assigned[name] ?? [] { LuaParser.set(&fields, path, value) }
            computedFields = computed[name] ?? []
            addedKeys = added[name] ?? []
        } else if case .table(_, let literal)? = returned {
            fields = literal
        } else if returned != nil {
            computedFields = ["the config itself"]
        }
        // A field whose value needs Lua is named, not kept; a table with code in it is kept, and named as partly so.
        var partly: [String] = []
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) where !value.isWrittenOut {
            if case .table = value {
                partly.append(field)
            } else {
                fields[field] = nil
                computedFields.append(field)
            }
        }
        var unique: [String] = []
        for field in computedFields where !unique.contains(field) { unique.append(field) }
        // A field code may change too counts as set by code, whatever it was written as first.
        for field in unique {
            fields[String(field.prefix { $0 != "." })] = nil
        }
        var scan = LuaConfigScan.made(fields: fields, computed: unique, addedKeys: addedKeys)
        scan.partlyComputed = partly.filter { fields[$0] != nil }
        return scan
    }

    static func set(_ fields: inout [String: LuaValue], _ path: [String], _ value: LuaValue) {
        guard let first = path.first else { return }
        guard path.count > 1 else {
            fields[first] = value
            return
        }
        var inner = fields[first]?.fields ?? [:]
        let items = fields[first]?.items ?? []
        set(&inner, Array(path.dropFirst()), value)
        fields[first] = .table(items: items, fields: inner)
    }
}
