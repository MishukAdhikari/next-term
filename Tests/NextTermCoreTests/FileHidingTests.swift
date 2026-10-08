import Foundation
import Testing
@testable import NextTermCore

@Suite struct FileHidingTests {
    let root = "/Users/me/app"

    func hides(_ patterns: [String], _ relative: String, folder: Bool = false) -> Bool {
        FileHiding(patterns: patterns, root: root).hides(root + "/" + relative, isDirectory: folder)
    }

    @Test func aNameHidesAtAnyDepth() {
        #expect(hides(["node_modules"], "node_modules", folder: true))
        #expect(hides(["node_modules"], "web/node_modules", folder: true))
        #expect(hides(["*.pyc"], "pkg/sub/mod.pyc"))
        #expect(!hides(["*.pyc"], "pkg/mod.py"))
        #expect(hides(["?.log"], "a.log") && !hides(["?.log"], "ab.log"))
        #expect(hides(["Thumbs.db"], "photos/Thumbs.db"))
    }

    @Test func aPathIsFromTheProjectsFolder() {
        #expect(hides(["/build"], "build", folder: true))
        #expect(!hides(["/build"], "web/build", folder: true))
        #expect(hides(["docs/_site"], "docs/_site", folder: true))
        #expect(!hides(["docs/_site"], "x/docs/_site", folder: true))
        #expect(hides(["**/generated"], "a/b/generated", folder: true) && hides(["**/generated"], "generated", folder: true))
        #expect(hides(["src/**/*.snap"], "src/a/b/c.snap") && hides(["src/**/*.snap"], "src/c.snap"))
        #expect(!hides(["src/*.snap"], "src/a/c.snap"), "* stays within a name")
        // "dist/**" hides what is inside, as in .gitignore; "dist/" the folder.
        #expect(hides(["dist/**"], "dist/app.js") && !hides(["dist/**"], "dist", folder: true))
    }

    @Test func aSlashAtTheEndHidesOnlyFolders() {
        #expect(hides(["out/"], "out", folder: true) && hides(["out/"], "deep/out", folder: true))
        #expect(!hides(["out/"], "out"))
        #expect(hides(["/out/"], "out", folder: true) && !hides(["/out/"], "deep/out", folder: true))
    }

    @Test func setsAndBraces() {
        #expect(hides(["*.{jpg,png}"], "a/b.png") && hides(["*.{jpg,png}"], "b.jpg") && !hides(["*.{jpg,png}"], "b.gif"))
        #expect(hides(["{a,b{c,d}}.txt"], "bd.txt") && !hides(["{a,b{c,d}}.txt"], "b.txt"))
        #expect(hides(["file[0-9].txt"], "file7.txt") && !hides(["file[0-9].txt"], "fileX.txt"))
        #expect(hides(["file[!0-9].txt"], "fileX.txt") && !hides(["file[!0-9].txt"], "file7.txt"))
        #expect(hides(["a[b"], "a[b"), "an unclosed [ is itself")
        #expect(hides(["\\*star"], "*star") && !hides(["\\*star"], "xstar"))
    }

    @Test func aBangShowsAgain() {
        // As in .gitignore: the last pattern that matches decides.
        #expect(!hides(["*.log", "!keep.log"], "keep.log") && hides(["*.log", "!keep.log"], "other.log"))
        #expect(hides(["!keep.log", "*.log"], "keep.log"), "a later pattern hides it again")
        #expect(!hides(["!keep.log"], "keep.log"), "on its own it hides nothing")
        #expect(!hides(["/build/", "!/build/"], "build", folder: true))
        // "\!" is a name that starts with "!".
        #expect(hides(["\\!important"], "!important") && !hides(["\\!important"], "important"))
    }

    @Test func onlyBelowTheRoot() {
        let hiding = FileHiding(patterns: ["*.log"], root: root + "/")
        #expect(hiding.hides(root + "/a.log", isDirectory: false))
        #expect(!hiding.hides("/Users/me/other/a.log", isDirectory: false))
        #expect(!hiding.hides(root, isDirectory: true))
        #expect(!hiding.hides(root + "x/a.log", isDirectory: false), "a sibling folder whose name starts the same")
        #expect(FileHiding(patterns: ["", "  ", "/"], root: root).isEmpty)
    }

    @Test func theSettingsText() {
        #expect(FileHiding.patterns(from: " node_modules, *.log\n/build ,, *.log ") == ["node_modules", "*.log", "/build"])
        #expect(FileHiding.text(of: ["a", "/b"]) == "a, /b")
        // A comma inside braces stays in its pattern, so an imported one reads back the same after an edit.
        let imported = ["*.{js,map}", "dist", "{a,b{c,d}}.txt"]
        #expect(FileHiding.patterns(from: FileHiding.text(of: imported)) == imported)
        #expect(FileHiding.patterns(from: "*.{pyc,pyo}, node_modules") == ["*.{pyc,pyo}", "node_modules"])
        // A brace that never closes is itself, and a comma after it still ends the pattern.
        #expect(FileHiding.patterns(from: "a{b, c}d, e") == ["a{b, c}d", "e"])
        #expect(FileHiding.patterns(from: "a{b, c\nd}") == ["a{b", "c", "d}"])
    }

    @Test func globsFromOtherApps() {
        let cases: [(String, String?)] = [
            ("**/node_modules", "node_modules"), ("**/*.pyc", "*.pyc"), ("build", "/build"), ("/build", "/build"),
            ("./coverage", "/coverage"), ("dist/**", "/dist/"), ("**/tmp/", "tmp/"), ("src/**/gen", "/src/**/gen"),
            ("**/.git", nil), ("**/.DS_Store", nil), (".hg", nil), ("**", nil), ("", nil),
        ]
        for (glob, pattern) in cases { #expect(FileHiding.pattern(fromProjectGlob: glob) == pattern, "\(glob)") }
        // Each one means here what it meant there.
        #expect(hides(["/build"], "build", folder: true) && !hides(["/build"], "a/build", folder: true))
    }

    @Test func theSidebarLeavesThemOut() throws {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-hiding-\(UUID().uuidString)"
        for folder in ["src", "node_modules", "web/node_modules"] {
            try FileManager.default.createDirectory(atPath: dir + "/" + folder, withIntermediateDirectories: true)
        }
        for file in ["a.log", "main.swift", "src/b.log", "src/c.swift"] {
            try Data().write(to: URL(fileURLWithPath: dir + "/" + file))
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let hiding = FileHiding(patterns: ["node_modules", "*.log"], root: dir)
        #expect(FileNode.readChildren(of: URL(fileURLWithPath: dir), hiding: hiding).nodes.map(\.name) == ["src", "web", "main.swift"])
        #expect(FileNode.readChildren(of: URL(fileURLWithPath: dir + "/src"), hiding: hiding).nodes.map(\.name) == ["c.swift"])
        #expect(FileNode.readChildren(of: URL(fileURLWithPath: dir + "/web"), hiding: hiding).nodes.isEmpty)
        // Without patterns, everything but the sidebar's own.
        #expect(FileNode.readChildren(of: URL(fileURLWithPath: dir)).nodes.count == 5)
    }
}
