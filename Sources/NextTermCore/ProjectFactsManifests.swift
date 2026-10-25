import Foundation

// Dependency names from a project's manifests, and the scripts in them that run a tool. Versions, URLs, paths and
// whole script lines are never kept.

extension ProjectFacts {
    /// Python's manifests, then `package.json`, `Gemfile` and `mix.exs`, each read once.
    mutating func readManifests(_ reader: inout FactReader, startWords: [String]) {
        readRequirements(&reader)
        readPyproject(&reader, startWords: startWords)
        if let text = reader.text("Pipfile"), case .success(let root) = TOMLReader.parse(text) {
            let tables = ["packages", "dev-packages"].compactMap { (name: String) -> [String: TOMLValue]? in root[name]?.table }
            let names = tables.flatMap { (table: [String: TOMLValue]) -> [String] in table.keys.sorted() }
            addDependencies(names.compactMap(Self.packageKey), file: "Pipfile", ecosystem: .pypi)
        }
        readPackageJSON(&reader, startWords: startWords)
        if let text = reader.text("Gemfile") {
            addDependencies(Self.matches(Self.gemPattern, in: text), file: "Gemfile", ecosystem: .rubygems)
        }
        if let text = reader.text("mix.exs") {
            addDependencies(Self.matches(Self.hexPattern, in: text), file: "mix.exs", ecosystem: .hex)
        }
    }

    /// `gem "rails"` at the start of a line; a commented-out gem is not one.
    static let gemPattern = try? NSRegularExpression(pattern: #"(?m)^[ \t]*gem[ \t]+["']([A-Za-z0-9._-]{1,100})["']"#)
    /// `{:phoenix, "~> 1.7"}` in `deps`.
    static let hexPattern = try? NSRegularExpression(pattern: #"\{\s*:([a-z_][a-z0-9_]{0,99})\s*,"#)

    static func matches(_ pattern: NSRegularExpression?, in text: String) -> [String] {
        guard let pattern else { return [] }
        let found = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return found.compactMap { (match: NSTextCheckingResult) -> String? in
            Range(match.range(at: 1), in: text).map { (range: Range<String.Index>) -> String in String(text[range]) }
        }
    }

    /// One manifest's names, each once, in order; nothing when it lists none.
    mutating func addDependencies(_ names: [String], file: String, ecosystem: Ecosystem) {
        var seen = Set<String>()
        let unique = names.filter { (name: String) -> Bool in !name.isEmpty && seen.insert(name).inserted }
        guard !unique.isEmpty else { return }
        dependencies.append(ManifestNames(file: file, ecosystem: ecosystem, names: unique))
    }

    /// `requirements*.txt` at the top, then `requirements/*.txt`, twenty files at most.
    mutating func readRequirements(_ reader: inout FactReader) {
        let top = reader.topLevelNames().filter { (name: String) -> Bool in
            name.hasPrefix("requirements") && name.hasSuffix(".txt")
        }
        let nested = reader.names(in: "requirements").filter { (name: String) -> Bool in name.hasSuffix(".txt") }
        let files = top + nested.map { (name: String) -> String in "requirements/" + name }
        for file in files.prefix(20) {
            guard let text = reader.text(file) else { continue }
            let lines = text.split(whereSeparator: { (c: Character) -> Bool in c == "\n" || c == "\r\n" || c == "\r" })
            let names = lines.compactMap { (line: Substring) -> String? in Self.requirementName(String(line)) }
            addDependencies(names, file: file, ecosystem: .pypi)
        }
    }

    /// The package a requirement line names, normalised (`Qdrant_Client==1.15` gives `qdrant-client`); nil for an
    /// option (`-r`, `-e`, `--index-url`), a URL, a path or a comment.
    static func requirementName(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.unicodeScalars.first, first.isASCII,
              CharacterSet.alphanumerics.contains(first) else { return nil }
        let name = text.prefix { (c: Character) -> Bool in c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c)) }
        let rest = text.dropFirst(name.count)
        let ends: Bool = rest.isEmpty || " \t[<>=!~;@(,".contains(rest.first ?? " ")
        let url: Bool = rest.hasPrefix("://") || rest.hasPrefix("+")
        guard ends, !url, name.count <= 100 else { return nil }
        return normalisedPyPI(String(name))
    }

    /// A package's name as a table's key gives it (Pipfile's, Poetry's), normalised: 1 to 100 of ASCII letters,
    /// digits, `.`, `_` and `-`, from a letter or digit. Nil for any other key.
    static func packageKey(_ key: String) -> String? {
        let plain = key.allSatisfy { (c: Character) -> Bool in
            c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c))
        }
        guard plain, let first = key.first, first.isLetter || first.isNumber, key.count <= 100 else { return nil }
        return normalisedPyPI(key)
    }

    /// As PyPI compares names: lower case, with each run of `-`, `_` and `.` made one `-`.
    static func normalisedPyPI(_ name: String) -> String {
        var result = ""
        var inRun = false
        for c in name.lowercased() {
            if c == "-" || c == "_" || c == "." {
                if !inRun { result.append("-") }
                inRun = true
            } else {
                result.append(c)
                inRun = false
            }
        }
        return result
    }
}

// MARK: - pyproject.toml and package.json

extension ProjectFacts {
    /// `[project]`'s dependencies and optional ones, `[dependency-groups]`, Poetry's tables, the `[tool]` tables there
    /// are, and the tasks of poe and taskipy that run a tool. A file the TOML reader refuses gives nothing.
    mutating func readPyproject(_ reader: inout FactReader, startWords: [String]) {
        guard let text = reader.text("pyproject.toml"), case .success(let table) = TOMLReader.parse(text) else { return }
        let root = TOMLValue.table(table)
        // Tables in key order, so a scan of the same file gives the same facts.
        var specs: [String] = Self.strings(root["project", "dependencies"])
        for list in Self.sortedValues(root["project", "optional-dependencies"]) { specs += Self.strings(list) }
        for list in Self.sortedValues(root["dependency-groups"]) { specs += Self.strings(list) }
        var names = specs.compactMap { (spec: String) -> String? in Self.requirementName(spec) }
        let poetry = root["tool", "poetry"]
        let groups = Self.sortedValues(poetry?["group"]).map { (group: TOMLValue) -> TOMLValue? in group["dependencies"] }
        let poetryTables: [TOMLValue?] = [poetry?["dependencies"], poetry?["dev-dependencies"]] + groups
        for table in poetryTables {
            let keys: [String] = (table?.table ?? [:]).keys.sorted()
            let packages = keys.filter { (name: String) -> Bool in name.lowercased() != "python" }
            names += packages.compactMap { (name: String) -> String? in Self.packageKey(name) }
        }
        addDependencies(names, file: "pyproject.toml", ecosystem: .pypi)
        pyprojectTools = Set((root["tool"]?.table ?? [:]).keys)
        for runner in ["poe", "taskipy"] {
            let tasks = root["tool", runner, "tasks"]?.table ?? [:]
            for name in tasks.keys.sorted() {
                for line in Self.taskLines(tasks[name]) {
                    startCommands += Self.startCommands(in: line, file: "pyproject.toml", script: name, words: startWords)
                }
            }
        }
    }

    /// A TOML table's values in the order of their keys.
    static func sortedValues(_ value: TOMLValue?) -> [TOMLValue] {
        let table = value?.table ?? [:]
        return table.keys.sorted().compactMap { (key: String) -> TOMLValue? in table[key] }
    }

    /// The strings of a TOML array; a table in it (`{include-group = "x"}`) is not one.
    static func strings(_ value: TOMLValue?) -> [String] {
        (value?.array ?? []).compactMap { (item: TOMLValue) -> String? in item.string }
    }

    /// The command lines of a poe or taskipy task: a string, a table's `cmd` or `shell`, or each of a list's.
    static func taskLines(_ task: TOMLValue?) -> [String] {
        guard let task else { return [] }
        if let line = task.string { return [line] }
        if let table = task.table {
            return ["cmd", "shell"].compactMap { (key: String) -> String? in table[key]?.string }
        }
        return (task.array ?? []).flatMap { (item: TOMLValue) -> [String] in taskLines(item) }
    }

    /// `dependencies` and `devDependencies` by name, and the `scripts` that run a tool.
    mutating func readPackageJSON(_ reader: inout FactReader, startWords: [String]) {
        guard let text = reader.text("package.json"),
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        var names: [String] = []
        for key in ["dependencies", "devDependencies"] {
            let table = json[key] as? [String: Any] ?? [:]
            names += table.keys.sorted().filter { (name: String) -> Bool in Self.isNPMName(name) }
        }
        addDependencies(names, file: "package.json", ecosystem: .npm)
        let scripts = json["scripts"] as? [String: Any] ?? [:]
        for name in scripts.keys.sorted() {
            guard let line = scripts[name] as? String else { continue }
            startCommands += Self.startCommands(in: line, file: "package.json", script: name, words: startWords)
        }
    }

    /// An npm package's name: `next`, `@ai-sdk/anthropic`.
    static func isNPMName(_ name: String) -> Bool {
        let allowed = name.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in npmCharacters.contains(scalar) }
        return allowed && (1...214).contains(name.count) && !name.hasPrefix(".")
    }

    private static let npmCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@/._-~")
}
