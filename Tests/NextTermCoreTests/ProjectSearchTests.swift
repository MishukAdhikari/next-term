import Foundation
import Testing
@testable import NextTermCore

@Suite struct ProjectSearchTests {
    func folder() throws -> URL {
        let url = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func expressions() throws {
        let literal = try SearchQuery(text: "a.b(c)").expression()
        #expect(literal.numberOfMatches(in: "x a.b(c) y axb(c)", range: NSRange(location: 0, length: 17)) == 1)
        let word = try SearchQuery(text: "user", wholeWord: true).expression()
        #expect(word.numberOfMatches(in: "user users $user", range: NSRange(location: 0, length: 16)) == 2)
        let cased = try SearchQuery(text: "User", matchCase: true).expression()
        #expect(cased.numberOfMatches(in: "user User", range: NSRange(location: 0, length: 9)) == 1)
        #expect(throws: (any Error).self) { try SearchQuery(text: "(", isRegex: true).expression() }
    }

    @Test func masks() {
        let q = SearchQuery(text: "x", masks: ["*.php", "!vendor/**", "!*.blade.php"])
        #expect(q.includes("app/Http/Kernel.php"))
        #expect(!q.includes("vendor/laravel/x.php"))
        #expect(!q.includes("resources/views/home.blade.php"))
        #expect(!q.includes("app.js"))
        #expect(SearchQuery(text: "x", masks: ["src/**/*.ts"]).includes("src/a/b/c.ts"))
        #expect(SearchQuery(text: "x").includes("anything"))
    }

    @Test func matchesAreLineAndUTF16Exact() throws {
        let expr = try SearchQuery(text: "ব").expression()
        let found = ProjectSearch.matches(in: "one\r\nবাংলা ব\nlast", relativePath: "a.txt", expression: expr)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.line == 2 && $0.matchedText == "ব" })
    }

    @Test func searchSkipsBinariesAndDependencyFolders() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "app/a.php", "<?php // TODO one\n// todo two\n")
        try write(root, "node_modules/x/index.js", "TODO hidden\n")
        try write(root, "logo.bin", "TODO\0binary")
        try write(root, "README.md", "nothing\n")
        let files = ProjectSearch.files(in: root.path, git: nil)
        #expect(!files.contains { $0.hasPrefix("node_modules/") })
        var results: [FileMatches] = []
        let lock = NSLock()
        let total = try ProjectSearch.search(root: root.path, files: files, query: SearchQuery(text: "todo")) { m in
            lock.lock(); results.append(m); lock.unlock()
        }
        #expect(total == 2 && results.map(\.relativePath) == ["app/a.php"])
    }

    @Test func gitDecidesWhatIsIgnored() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", root.path, "init", "-q"]
        try p.run(); p.waitUntilExit()
        try write(root, ".gitignore", "secret/\n*.log\n")
        try write(root, "src/a.swift", "x")
        try write(root, "secret/key.txt", "x")
        try write(root, "debug.log", "x")
        let files = ProjectSearch.files(in: root.path, git: git)
        #expect(files == [".gitignore", "src/a.swift"])
    }

    @Test func replaceOnlySelectedAndStillThere() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt", "foo bar\r\nfoo foo\r\nend")
        let url = root.appendingPathComponent("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let query = SearchQuery(text: "foo")
        let all = ProjectSearch.matches(in: try String(contentsOf: url, encoding: .utf8), relativePath: "a.txt", expression: try query.expression())
        #expect(all.count == 3)
        // Replace the first and the last; leave the middle one.
        let result = try ProjectSearch.replace([all[0], all[2]], in: root.path, with: "baz", query: query)
        #expect(result.replaced == 2 && result.skipped == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == "baz bar\r\nfoo baz\r\nend") // CRLF kept
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(result.original == Data("foo bar\r\nfoo foo\r\nend".utf8))
        // The file changed since the search: stale matches are skipped, never overwritten.
        try write(root, "a.txt", "inserted line\nbaz bar\nfoo baz\nend")
        let stale = try ProjectSearch.replace([all[1]], in: root.path, with: "zzz", query: query)
        #expect(stale.replaced == 0 && stale.skipped == 1)
    }

    @Test func regexReplacementAndPreview() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "b.php", "$user->getName();\n")
        let query = SearchQuery(text: #"->get(\w+)\(\)"#, isRegex: true)
        let found = ProjectSearch.matches(in: "$user->getName();", relativePath: "b.php", expression: try query.expression())
        #expect(ProjectSearch.preview(found[0], replacement: "->$1", query: query) == "$user->Name;")
        _ = try ProjectSearch.replace(found, in: root.path, with: "->$1", query: query)
        #expect(try String(contentsOf: root.appendingPathComponent("b.php"), encoding: .utf8) == "$user->Name;\n")
        // A literal replacement keeps "$1" literally.
        let literal = SearchQuery(text: "Name")
        let m = ProjectSearch.matches(in: "$user->Name;", relativePath: "b.php", expression: try literal.expression())
        #expect(ProjectSearch.preview(m[0], replacement: "$1", query: literal) == "$user->$1;")
    }
}

@Suite struct ResultOrderTests {
    @Test func currentFileThenItsTypeThenTheRest() {
        let order = ResultOrder(current: "resources/views/welcome.blade.php")
        let paths = ["app/User.php", "README.md", "resources/views/home.blade.php", "resources/views/welcome.blade.php", "routes/web.php", "a.js"]
        #expect(paths.sorted(by: order.precedes) == [
            "resources/views/welcome.blade.php", "resources/views/home.blade.php", "app/User.php", "routes/web.php", "README.md", "a.js",
        ])
        #expect(order.typeLabel == "blade.php")
        #expect(ResultOrder(current: "app/Models/User.php").typeLabel == "php")
        #expect(ResultOrder(current: ".env").typeLabel == nil)
        // No current file: by path.
        #expect(paths.sorted(by: ResultOrder(current: nil).precedes) == paths.sorted())
    }
}
