import Foundation
import Testing
@testable import NextTermCore

@Suite struct TextFileTests {
    @Test func roundTripsEveryFormatByteForByte() throws {
        let samples: [Data] = [
            Data("a\nb\n".utf8),
            Data("a\r\nb\r\n".utf8),                         // Windows
            Data("a\r\nb\nc".utf8),                          // mixed: kept as is
            Data("a\rb\r".utf8),                             // old Mac
            Data([0xEF, 0xBB, 0xBF]) + Data("bom\n".utf8),
            Data([0xFF, 0xFE]) + "utf16 ✓\r\n".data(using: .utf16LittleEndian)!,
            Data([0xFE, 0xFF]) + "utf16 be\n".data(using: .utf16BigEndian)!,
            Data("no final newline".utf8),
            Data("emoji 👨‍👩‍👧 and café\n".utf8),
        ]
        for data in samples {
            let (text, format) = try #require(TextFile.decode(data))
            #expect(TextFile.encode(text, as: format) == data)
        }
    }

    @Test func windowsLineEndingsBecomeNewlinesWhileEditing() throws {
        let (text, format) = try #require(TextFile.decode(Data("one\r\ntwo\r\n".utf8)))
        #expect(text == "one\ntwo\n" && format.lineEnding == .crlf)
        // A line typed in the editor, and a pasted CRLF, both save as CRLF.
        #expect(TextFile.encode(text + "three\nfour\r\n", as: format) == Data("one\r\ntwo\r\nthree\r\nfour\r\n".utf8))
        let mixed = try #require(TextFile.decode(Data("a\r\nb\n".utf8)))
        #expect(mixed.format.lineEnding == nil && mixed.text == "a\r\nb\n")
    }

    @Test func binaryAndUnknownEncodingsAreRefused() {
        #expect(TextFile.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])) == nil) // zip
        #expect(TextFile.decode(Data([0x63, 0x61, 0x66, 0xE9])) == nil)             // Latin-1 "café"
        #expect(TextFile.decode(Data()) != nil)                                      // empty is text
    }

    @Test func writeKeepsPermissionsAndSymlinks() throws {
        let dir = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("run.sh")
        try Data("echo 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)

        try TextFile.write(Data("echo 2\n".utf8), to: link)
        #expect(try String(contentsOf: script, encoding: .utf8) == "echo 2\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == script.path)
        #expect((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int) == 0o755)
    }

    @Test func namedPipesAreNotRegularFiles() throws {
        let fifo = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-fifo-\(UUID().uuidString)"
        defer { unlink(fifo) }
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(!isRegularFile(fifo)) // reading it would wait for a writer forever
        #expect(ProjectSearch.text(of: URL(fileURLWithPath: fifo)) == nil)
        #expect(isRegularFile(#filePath))
    }

    @Test func stampsChangeWhenTheFileDoes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nt-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        let before = try #require(FileStamp(path: file.path))
        #expect(FileStamp(path: file.path) == before)
        try Data("three".utf8).write(to: file, options: .atomic)
        #expect(FileStamp(path: file.path) != before)
        #expect(FileStamp(path: file.path + ".missing") == nil)
    }
}

@Suite struct LineIndexTests {
    /// The index after any edit must equal one built from scratch.
    @Test func incrementalEditsMatchAFullRebuild() {
        var text = "one\ntwo\n\nfour" as NSString
        var index = LineIndex(text as String)
        #expect(index.starts == [0, 4, 8, 9] && index.count == 4)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 3, length: 0), "\nnew"),     // split a line
            (NSRange(location: 0, length: 4), ""),          // delete a whole line
            (NSRange(location: 2, length: 6), "x\ny\nz"),   // replace across lines
            (NSRange(location: (text.length), length: 0), "\n"),
            (NSRange(location: 0, length: 0), "👋\n"),      // a surrogate pair is two offsets
        ]
        for (range, replacement) in edits {
            let clamped = NSRange(location: min(range.location, text.length), length: min(range.length, text.length - min(range.location, text.length)))
            text = text.replacingCharacters(in: clamped, with: replacement) as NSString
            index.replace(clamped, with: replacement)
            #expect(index == LineIndex(text as String), "after replacing \(clamped) with \(replacement.debugDescription)")
        }
    }

    @Test func findsLinesAndTheirRanges() {
        let index = LineIndex("ab\ncd\n")
        #expect(index.line(at: 0) == 0 && index.line(at: 2) == 0 && index.line(at: 3) == 1 && index.line(at: 6) == 2)
        #expect(index.range(ofLine: 1) == NSRange(location: 3, length: 3))
        #expect(index.range(ofLine: 2) == NSRange(location: 6, length: 0))
    }
}

@Suite struct EditorLanguageTests {
    @Test func picksGrammarsByNameExtensionAndShebang() {
        #expect(EditorLanguage.id(forFileName: "welcome.blade.php") == "blade")
        #expect(EditorLanguage.id(forFileName: "Alertable.php") == "php")
        #expect(EditorLanguage.id(forFileName: "Dockerfile") == "docker")
        #expect(EditorLanguage.id(forFileName: "Dockerfile.prod") == "docker")
        #expect(EditorLanguage.id(forFileName: ".env.local") == "dotenv")
        #expect(EditorLanguage.id(forFileName: "tsconfig.json") == "jsonc")
        #expect(EditorLanguage.id(forFileName: "App.TSX") == "tsx")
        #expect(EditorLanguage.id(forFileName: "deploy", firstLine: "#!/usr/bin/env bash") == "shellscript")
        #expect(EditorLanguage.id(forFileName: "tool", firstLine: "#!/usr/bin/env -S python3.12 -u") == "python")
        #expect(EditorLanguage.id(forFileName: "artisan") == "php")
        #expect(EditorLanguage.id(forFileName: "notes") == nil)
        // Framework templates.
        let templates = ["show.html.erb": "erb", "index.html.twig": "twig", "page.mdx": "mdx", "app.component.html": "angular-html",
                         "styles.sass": "sass", "base.html.j2": "jinja", "theme.liquid": "liquid", "card.hbs": "handlebars",
                         "Index.cshtml": "razor", "layout.pug": "pug", "view.haml": "haml", "lib.ex": "elixir", "justfile": "just",
                         "yarn.lock": "yaml", "composer.lock": "json", "uv.lock": "toml"]
        for (name, language) in templates { #expect(EditorLanguage.id(forFileName: name) == language, "\(name)") }
        #expect(EditorLanguage.id(forFileName: "Gemfile.lock") == nil) // its own format: plain, not mis-coloured as JSON
    }

    @Test func ragProjectFiles() {
        let files = [
            // Data, docs, diagrams and graph queries.
            "eval.tsv": "tsv", "scores.tab": "tsv", "index.rst": "rst", "graph.mmd": "mermaid", "flow.mermaid": "mermaid",
            "vector_search.cypher": "cypher", "match.cyp": "cypher", "people.rq": "sparql", "query.sparql": "sparql",
            "graph.ttl": "turtle", "context.jsonld": "json", "CITATION.cff": "yaml", "startup.ipy": "python", "analysis.ipynb": "json",
            // Prompts.
            "summarize.prompt": "handlebars", "chat.prompty": "prompty", "python.mdc": "markdown",
            // Python tooling.
            "Pipfile.lock": "json", "pixi.lock": "yaml", ".condarc": "yaml", ".flake8": "ini", ".pylintrc": "ini", ".pypirc": "ini",
            ".flaskenv": "dotenv", "env.example": "dotenv", "env.sample": "dotenv",
            "requirements.txt": "pip-requirements", "requirements-dev.txt": "pip-requirements", "dev-requirements.txt": "pip-requirements",
            "requirements.in": "pip-requirements", "requirements_test.in": "pip-requirements", "constraints.txt": "pip-requirements",
            "pip-constraints.txt": "pip-requirements", "requirements.lock": "pip-requirements", "requirements-dev.lock": "pip-requirements",
            // A copy kept as an example takes the language of the name inside.
            "connections.json.example": "json", "config.yml.example": "yaml", "settings.py.sample": "python", "phpunit.xml.dist": "xml",
            "docker-compose.yaml.template": "yaml", ".env.template": "dotenv", "requirements.txt.example": "pip-requirements",
        ]
        for (name, language) in files { #expect(EditorLanguage.id(forFileName: name) == language, "\(name)") }
        // queries.cql: Neo4j's or Cassandra's, so no guess.
        for name in ["MANIFEST.in", "notes.txt", "queries.cql", "LICENSE", "config.example"] {
            #expect(EditorLanguage.id(forFileName: name) == nil, "\(name)")
        }
        #expect(EditorLanguage.id(forFileName: "rag", firstLine: "#!/usr/bin/env -S uv run --script") == "python") // PEP 723
        #expect(EditorLanguage.id(forFileName: "tool", firstLine: "#!/usr/bin/env uv") == nil)
    }

    /// A mapping cannot ship without its grammar: every language a file can get is in Resources/Highlighting.
    @Test func everyMappedLanguageShips() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Highlighting/language-manifest.json")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let ids = (manifest["languages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let shipped = Set(ids).union((manifest["aliases"] as? [String: String] ?? [:]).keys)
        #expect(ids.count > 100)
        var mapped = Set(EditorLanguage.byName.values).union(EditorLanguage.byExtension.values).union(EditorLanguage.byInterpreter.values)
        // The rules in id(forFileName:) and shebang(_:), a file each.
        for name in ["welcome.blade.php", "app.component.html", "app.component.ts", ".env.local", "Dockerfile.prod", "requirements-dev.txt"] {
            mapped.insert(EditorLanguage.id(forFileName: name) ?? "nothing for \(name)")
        }
        mapped.insert(EditorLanguage.shebang("#!/usr/bin/env -S uv run --script") ?? "nothing for uv")
        let missing = mapped.subtracting(shipped).sorted()
        #expect(missing.isEmpty, "mapped, but no grammar for them ships: \(missing)")
    }

    @Test func commentStylesOfRagProjectLanguages() {
        let prefixes = ["cypher": "//", "sparql": "#", "turtle": "#", "mermaid": "%%", "rst": "..", "pip-requirements": "#"]
        for (language, prefix) in prefixes {
            let style = EditorLanguage.commentStyle(for: language)
            #expect(style?.prefix == prefix && style?.suffix == "", "\(language)")
        }
        #expect(EditorLanguage.commentStyle(for: "prompty") == EditorLanguage.commentStyle(for: "jinja"))
        let mermaid = EditorLanguage.commentStyle(for: "mermaid")!
        #expect(EditorLanguage.toggleComment(["  A --> B"], style: mermaid) == ["  %% A --> B"])
        #expect(EditorLanguage.toggleComment(["  %% A --> B"], style: mermaid) == ["  A --> B"])
    }

    @Test func findsTheLanguagesOfCodeFences() {
        let text = """
        # Notes

        ``` python
        print(1)
        ```
        ~~~yaml
        a: 1
        ~~~
        ```py {title="x"}
        x = 1
        ```
          ```TypeScript
        Inline ```ruby is not a fence, and a closing ``` names nothing.
        ```bash
        echo "never closed"
        """
        #expect(EditorLanguage.fenceLanguages(in: text) == ["python", "yaml", "py", "typescript", "bash"])
        #expect(EditorLanguage.fenceLanguages(in: "no fences\n```\n") == [])
    }

    @Test func togglesLineComments() {
        let php = EditorLanguage.commentStyle(for: "php")!
        let lines = ["    if ($a) {", "", "        run();", "    }"]
        let commented = EditorLanguage.toggleComment(lines, style: php)
        #expect(commented == ["    // if ($a) {", "", "    //     run();", "    // }"])
        #expect(EditorLanguage.toggleComment(commented, style: php) == lines)
        // Mixed: some commented, some not, comments all of them.
        #expect(EditorLanguage.toggleComment(["// a", "b"], style: php) == ["// // a", "// b"])
    }

    @Test func togglesMarkupComments() {
        let html = EditorLanguage.commentStyle(for: "html")!
        #expect(EditorLanguage.toggleComment(["  <b>x</b>"], style: html) == ["  <!-- <b>x</b> -->"])
        #expect(EditorLanguage.toggleComment(["  <!-- <b>x</b> -->"], style: html) == ["  <b>x</b>"])
        #expect(EditorLanguage.commentStyle(for: "json") == nil)
    }

    @Test func detectsIndentation() {
        #expect(EditorLanguage.indentUnit(of: "a\n\tb\n\t\tc\n") == "\t")
        #expect(EditorLanguage.indentUnit(of: "a:\n  b:\n    c: 1\n  d: 2\n") == "  ")
        #expect(EditorLanguage.indentUnit(of: "class A {\n    fn() {\n        x\n    }\n}\n") == "    ")
        #expect(EditorLanguage.indentUnit(of: "flat\ntext\n") == "    ")
    }
}

@Suite struct CommandLineOpenTests {
    func sandbox() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-cli-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: dir + "/src/app.ts"))
        return dir
    }

    @Test func foldersFilesAndLines() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        guard case .open(let command) = CommandLineOpen.parse([".", "src/app.ts:42:7", "-n", "src/app.ts:3"], cwd: dir) else {
            return #expect(Bool(false))
        }
        #expect(command.newWindow)
        #expect(command.items == [
            OpenRequest(path: dir, isDirectory: true),
            OpenRequest(path: dir + "/src/app.ts", line: 42, column: 7),
            OpenRequest(path: dir + "/src/app.ts", line: 3),
        ])
    }

    @Test func newFilesAndMistakes() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(CommandLineOpen.parse(["src/new.md"], cwd: dir) == .open(OpenCommand(items: [OpenRequest(path: dir + "/src/new.md", isNew: true)])))
        #expect(CommandLineOpen.parse(["nowhere/new.md"], cwd: dir) == .error("nowhere/new.md: no such file or folder"))
        #expect(CommandLineOpen.parse(["src:4"], cwd: dir) == .error("src:4: a folder has no lines"))
        #expect(CommandLineOpen.parse(["--frobnicate"], cwd: dir) == .error("unknown option --frobnicate (see nxtrm --help)"))
        #expect(CommandLineOpen.parse(["-h"], cwd: dir) == .help)
        // After --, a file named like an option.
        if case .open(let command) = CommandLineOpen.parse(["--", "-weird"], cwd: dir) {
            #expect(command.items.first?.path == dir + "/-weird" && command.items.first?.isNew == true)
        } else {
            #expect(Bool(false))
        }
        #expect(CommandLineOpen.parse([], cwd: dir) == .open(OpenCommand(items: [])))
    }

    @Test func requestsSurviveTheTrip() throws {
        let command = OpenCommand(items: [OpenRequest(path: "/a b/é.ts", line: 1, column: 2)], newWindow: true, app: "/Applications/Next Term.app")
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(OpenCommand.self, from: data) == command)
    }
}
