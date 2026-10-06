import Foundation
import Testing
@testable import NextTermCore

@Suite struct FuzzyFinderTests {
    let paths = [
        "app/Http/Controllers/UserController.php",
        "app/Models/User.php",
        "resources/views/users/index.blade.php",
        "tests/Feature/UserTest.php",
        "app/Http/Controllers/Controller.php",
        "config/database.php",
        "public/index.php",
        "README.md",
        "docs/user-guide.md",
    ]

    func top(_ query: String, _ count: Int = 1) -> [String] {
        let index = FuzzyIndex(paths: paths)
        return index.sorted(index.search(query) ?? [], limit: count).map { paths[$0.index] }
    }

    @Test func fileNamesWin() {
        #expect(top("user") == ["app/Models/User.php"])
        #expect(top("usercon") == ["app/Http/Controllers/UserController.php"])
        #expect(top("index") == ["public/index.php"]) // the shorter path of two equal names
        #expect(top("readme") == ["README.md"])
        #expect(top("user.php") == ["app/Models/User.php"])
    }

    @Test func wordStartsAndHumps() {
        #expect(top("uc") == ["app/Http/Controllers/UserController.php"])
        #expect(top("ut") == ["tests/Feature/UserTest.php"])
        #expect(top("db") == ["config/database.php"])
        #expect(top("idxbl") == ["resources/views/users/index.blade.php"])
    }

    @Test func foldersCountToo() {
        #expect(top("feat/ut") == ["tests/Feature/UserTest.php"])
        #expect(top("models user") == ["app/Models/User.php"]) // spaces only separate words
    }

    @Test func lettersMustBeInOrder() {
        let index = FuzzyIndex(paths: paths)
        #expect(index.search("zzz")?.isEmpty == true)
        #expect(index.search("resu")?.contains { paths[$0.index] == "app/Models/User.php" } == false)
    }

    @Test func narrowingSearchesOnlyThePreviousMatches() {
        let index = FuzzyIndex(paths: paths)
        let wide = index.search("us") ?? []
        let narrow = index.search("usr", among: wide.map(\.index)) ?? []
        let full = index.search("usr") ?? []
        #expect(Set(narrow.map(\.index)) == Set(full.map(\.index)))
        #expect(Dictionary(uniqueKeysWithValues: narrow.map { ($0.index, $0.score) }) == Dictionary(uniqueKeysWithValues: full.map { ($0.index, $0.score) }))
    }

    @Test func highlightsTheLettersThatScored() {
        let index = FuzzyIndex(paths: paths)
        let path = "app/Http/Controllers/UserController.php"
        let i = paths.firstIndex(of: path)!
        let name = path.utf8.count - "UserController.php".utf8.count
        #expect(index.positions(of: "usercon", in: i) == Array(name..<(name + 7)))
        let humps = index.positions(of: "uc", in: i)
        #expect(humps == [name, name + 4]) // U and C of UserController
    }

    @Test func longPathsMatchOnTheirEnd() {
        let deep = String(repeating: "folder/", count: 100) + "Target.swift"
        let index = FuzzyIndex(paths: [deep])
        #expect(index.search("target")?.count == 1)
        let positions = index.positions(of: "target", in: 0)
        #expect(positions.first == deep.utf8.count - "Target.swift".utf8.count)
    }

    @Test func manyPathsStayQuick() {
        var many: [String] = []
        for a in 0..<100 { for b in 0..<100 { for name in ["UserController.php", "index.ts", "README.md", "schema_\(b).sql", "Thing\(a).swift"] {
            many.append("src/module\(a)/part\(b)/\(name)")
        } } }
        let index = FuzzyIndex(paths: many)
        let start = Date()
        let matches = index.search("ctrl") ?? []
        let sorted = index.sorted(matches, limit: 50)
        let elapsed = Date().timeIntervalSince(start)
        #expect(sorted.first.map { many[$0.index].hasSuffix("UserController.php") } == true)
        #expect(elapsed < 3, "50,000 paths took \(elapsed) s in a debug build")
    }

    @Test func walkerSkipsHiddenAndDependencyFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-walk-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for path in ["src/a.swift", "node_modules/x/index.js", ".git/config", ".env", "docs/b.md"] {
            let full = (root as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x".write(toFile: full, atomically: true, encoding: .utf8)
        }
        let walk = FileWalker.files(in: root)
        #expect(Set(walk.paths) == ["src/a.swift", ".env", "docs/b.md"] && walk.complete)
        #expect(FileWalker.files(in: root, limit: 1).complete == false)
    }
}
