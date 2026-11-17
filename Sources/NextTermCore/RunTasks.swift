import Foundation

/// The Run group (plan 044): the tasks a project's own files name, each one command typed and run in a new tab in the
/// project's folder. Read from files only, never by running a tool: `package.json`'s scripts, a Makefile's targets, a
/// justfile's recipes, pyproject's scripts and tasks, Cargo's usual commands and its `[[bin]]` targets, and a few
/// well-known Gradle wrapper tasks. Each file is read as the Services scan reads one (FactReader: inside the project,
/// at most 512 KB, never a pipe or an evicted file), so a change to any of them sets off the same scan.
public struct RunTask: Sendable, Equatable, Identifiable {
    /// What named the task.
    public enum Source: String, Sendable {
        case npm, make, just, python, cargo, gradle
    }

    /// The file, then the name: `package.json:dev`.
    public var id: String { file + ":" + name }
    /// What the row shows: `dev`, `run --bin server`, `assembleDebug`.
    public let name: String
    /// The line typed into the tab: `npm run dev`, `cargo run --bin server`, `./gradlew assembleDebug`.
    public let command: String
    /// Relative to the project: `package.json`, `Cargo.toml`, `gradlew`.
    public let file: String
    public let source: Source

    public init(name: String, command: String, file: String, source: Source) {
        self.name = name
        self.command = command
        self.file = file
        self.source = source
    }

    /// ⌘P's line for it: `Run: npm run dev`.
    public var paletteTitle: String { "Run: " + command }
}

/// One read of a project for its Run group: its tasks, and the tools its files say they need (ProjectTools), whether
/// or not this Mac has them.
public struct RunScan: Sendable, Equatable {
    public var tasks: [RunTask]
    public var needs: [ProjectTool]

    public init(tasks: [RunTask] = [], needs: [ProjectTool] = []) {
        self.tasks = tasks
        self.needs = needs
    }
}

public enum RunTasks {
    /// The most rows the group shows: a project with more names them somewhere else too.
    public static let limit = 60

    /// Reads the project's files for tasks and for the tools they need. Nothing is run.
    public static func scan(root: String) -> RunScan {
        var reader = FactReader(root: root)
        var tasks: [RunTask] = []
        tasks += packageScripts(&reader)
        if let text = reader.text("Makefile") { tasks += makeTargets(text) }
        if let text = reader.text("justfile") ?? reader.text(".justfile") { tasks += justRecipes(text) }
        var python = PythonProject()
        if let text = reader.text("pyproject.toml") {
            python = PythonProject(text, uvLock: reader.isFile("uv.lock"), poetryLock: reader.isFile("poetry.lock"),
                                   pdmLock: reader.isFile("pdm.lock"))
            tasks += python.tasks
        }
        let cargo = reader.text("Cargo.toml")
        if let cargo { tasks += cargoTasks(cargo) }
        let gradlew = reader.isFile("gradlew")
        if gradlew { tasks += gradleTasks(&reader) }
        var seen = Set<String>()
        tasks = tasks.filter { (task: RunTask) -> Bool in seen.insert(task.id).inserted }
        var needs: [ProjectTool] = []
        if python.usesUV { needs.append(.uv) }
        if cargo != nil { needs.append(.cargo) }
        if gradlew { needs.append(.jdk) }
        return RunScan(tasks: Array(tasks.prefix(limit)), needs: needs)
    }

    // MARK: ⌘P

    /// ⌘P's Run lines for what is typed there: none unless it starts with "run" (any case, then a space, a colon or
    /// nothing); then every task whose command holds each word after it, in the group's order. "run" alone lists all.
    public static func matching(_ tasks: [RunTask], query: String) -> [RunTask] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("run") else { return [] }
        let rest = text.dropFirst(3)
        guard rest.isEmpty || rest.first == " " || rest.first == ":" else { return [] }
        let words = rest.split(whereSeparator: { (c: Character) -> Bool in c == " " || c == ":" })
        return tasks.filter { (task: RunTask) -> Bool in
            let command = task.command.lowercased()
            return words.allSatisfy { (word: Substring) -> Bool in command.contains(word) }
        }
    }

    // MARK: package.json

    /// The scripts npm runs by itself around install and publish, and the `pre`/`post` hooks of another script: run
    /// as a step of something else, never by name.
    static let lifecycle: Set<String> = ["install", "preinstall", "postinstall", "prepare", "prepublish", "prepublishOnly",
                                         "publish", "postpublish", "prepack", "postpack", "dependencies", "uninstall",
                                         "preuninstall", "postuninstall", "version", "preversion", "postversion"]

    /// `package.json`'s scripts in the file's order, typed with the package manager its lock file names.
    static func packageScripts(_ reader: inout FactReader) -> [RunTask] {
        guard let text = reader.text("package.json") else { return [] }
        let names = scriptNames(text)
        guard !names.isEmpty else { return [] }
        let runner = packageRunner(reader)
        let all = Set(names)
        return names.compactMap { (name: String) -> RunTask? in
            if lifecycle.contains(name) { return nil }
            for hook in ["pre", "post"] where name.hasPrefix(hook) && all.contains(String(name.dropFirst(hook.count))) {
                return nil
            }
            return RunTask(name: name, command: runner + " run " + ShellQuote.quote(name), file: "package.json", source: .npm)
        }
    }

    /// The `scripts` keys, in the order the file writes them (JSONSerialization's dictionary has none), each a string.
    static func scriptNames(_ text: String) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        let names = scripts.keys.filter { (name: String) -> Bool in scripts[name] is String && !name.isEmpty }
        // A key's place is where `"name":` first appears after `"scripts"`; one not found goes last, by name.
        let body = text.range(of: "\"scripts\"").map { text[$0.upperBound...] } ?? Substring(text)
        func place(_ name: String) -> String.Index {
            let quoted = (try? JSONSerialization.data(withJSONObject: [name], options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? "\"\(name)\""
            return body.range(of: quoted + ":")?.lowerBound ?? body.range(of: quoted)?.lowerBound ?? text.endIndex
        }
        return names.sorted { (a: String, b: String) -> Bool in
            let (pa, pb) = (place(a), place(b))
            return pa != pb ? pa < pb : a < b
        }
    }

    /// pnpm, Yarn or Bun when the project's lock file is theirs, else npm.
    static func packageRunner(_ reader: FactReader) -> String {
        if reader.isFile("pnpm-lock.yaml") { return "pnpm" }
        if reader.isFile("yarn.lock") { return "yarn" }
        if reader.isFile("bun.lock") || reader.isFile("bun.lockb") { return "bun" }
        return "npm"
    }

    // MARK: Makefile and justfile

    /// A Makefile's targets in the file's order, as `make <target>`: a name at the start of a line, then `:`
    /// (ProjectFacts.recipeName). Special targets (`.PHONY`) and file targets (`main.o`) are left out.
    static func makeTargets(_ text: String) -> [RunTask] {
        topLevelNames(text).compactMap { (name: String) -> RunTask? in
            guard !name.contains(".") else { return nil }
            return RunTask(name: name, command: "make " + name, file: "Makefile", source: .make)
        }
    }

    /// A justfile's recipes in the file's order, as `just <recipe>`. One whose name starts with `_`, or that follows
    /// `[private]`, is just's private one.
    static func justRecipes(_ text: String) -> [RunTask] {
        var names: [String] = []
        var isPrivate = false
        for line in ProjectFacts.lines(text) {
            if line.first == " " || line.first == "\t" { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if trimmed.contains("private") { isPrivate = true }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            defer { isPrivate = false }
            guard let name = ProjectFacts.recipeName(line), !isPrivate, !name.hasPrefix("_"), !names.contains(name) else { continue }
            names.append(name)
        }
        return names.map { (name: String) -> RunTask in
            RunTask(name: name, command: "just " + name, file: "justfile", source: .just)
        }
    }

    /// The names that start a recipe, once each, in order.
    static func topLevelNames(_ text: String) -> [String] {
        var names: [String] = []
        for line in ProjectFacts.lines(text) where line.first != " " && line.first != "\t" {
            guard let name = ProjectFacts.recipeName(line), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    // MARK: pyproject.toml

    /// What a `pyproject.toml` says: its scripts and tasks, and the tool that runs them.
    struct PythonProject {
        var tasks: [RunTask] = []
        /// A `uv.lock` beside it, or a `[tool.uv]` table.
        var usesUV = false

        init() {}

        /// `[project.scripts]`, Poetry's and PDM's `scripts`, and poe's and taskipy's tasks. The project's own runner
        /// (uv, Poetry or PDM, by its lock file or `[tool.x]` table) goes before a command that needs the project's
        /// environment.
        init(_ text: String, uvLock: Bool, poetryLock: Bool, pdmLock: Bool) {
            guard case .success(let table) = TOMLReader.parse(text) else { return }
            let root = TOMLValue.table(table)
            let tools = root["tool"]?.table ?? [:]
            usesUV = uvLock || tools["uv"] != nil
            let runner: String
            if usesUV {
                runner = "uv run "
            } else if poetryLock || tools["poetry"] != nil {
                runner = "poetry run "
            } else if pdmLock || tools["pdm"] != nil {
                runner = "pdm run "
            } else {
                runner = ""
            }
            func add(_ names: [String], _ command: (String) -> String) {
                for name in names where !name.hasPrefix("_") {
                    tasks.append(RunTask(name: name, command: command(ShellQuote.quote(name)), file: "pyproject.toml",
                                             source: .python))
                }
            }
            add(Self.keys(root["project", "scripts"])) { runner + $0 }
            add(Self.keys(root["tool", "poetry", "scripts"])) { "poetry run " + $0 }
            add(Self.keys(root["tool", "pdm", "scripts"])) { "pdm run " + $0 }
            add(Self.keys(root["tool", "poe", "tasks"])) { runner + "poe " + $0 }
            add(Self.keys(root["tool", "taskipy", "tasks"])) { runner + "task " + $0 }
        }

        /// A table's keys, sorted (TOMLReader keeps no order), so one file gives one list.
        static func keys(_ value: TOMLValue?) -> [String] {
            (value?.table ?? [:]).keys.sorted()
        }
    }

    // MARK: Cargo.toml

    /// `cargo build`, `run`, `test` and `clippy`, then `run --bin X` for each `[[bin]]`. Plain `run` is left out when
    /// two or more binaries leave cargo no default (`default-run`). A workspace with no `[package]` has nothing to run.
    static func cargoTasks(_ text: String) -> [RunTask] {
        guard case .success(let table) = TOMLReader.parse(text) else { return [] }
        let root = TOMLValue.table(table)
        let package = root["package"]?.table
        let bins: [String] = (root["bin"]?.array ?? []).compactMap { (bin: TOMLValue) -> String? in bin["name"]?.string }
        guard package != nil || root["workspace"] != nil else { return [] }
        var names = ["build"]
        if package != nil, bins.count < 2 || package?["default-run"] != nil { names.append("run") }
        names += ["test", "clippy"]
        if package != nil { names += bins.map { (bin: String) -> String in "run --bin " + ShellQuote.quote(bin) } }
        return names.map { (name: String) -> RunTask in
            RunTask(name: name, command: "cargo " + name, file: "Cargo.toml", source: .cargo)
        }
    }

    // MARK: Gradle

    /// The wrapper's well-known tasks, never a list asked of Gradle: an Android app's `assembleDebug`, `installDebug`
    /// and `test`; an Android library's `assembleDebug` and `test`; else `build` and `test`.
    static func gradleTasks(_ reader: inout FactReader) -> [RunTask] {
        var app = false, library = false
        for file in ["build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts"] {
            guard let text = reader.text(file) else { continue }
            if text.contains("com.android.application") || text.contains("android.application") { app = true }
            if text.contains("com.android.library") || text.contains("android.library") { library = true }
        }
        let names: [String]
        if app {
            names = ["assembleDebug", "installDebug", "test"]
        } else if library {
            names = ["assembleDebug", "test"]
        } else {
            names = ["build", "test"]
        }
        return names.map { (name: String) -> RunTask in
            RunTask(name: name, command: "./gradlew " + name, file: "gradlew", source: .gradle)
        }
    }
}
