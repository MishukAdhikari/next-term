import Foundation
import Testing
@testable import NextTermCore

/// "Copy ignored files too": the rules for what is left out, links that stay inside, what the sheet and the notice
/// say, and real clones in temporary folders (an APFS disk): links kept as links, nothing over what is there, other
/// worktrees and links out of the checkout left out, and git's own list of what the new branch ignores.
@Suite struct WorktreeCopyTests {
    @Test func whatIsLeftOutByDefault() {
        #expect(WorktreeCopy.rule(for: "storage/logs/laravel.log", isFolder: false) == "a log of this checkout’s")
        #expect(WorktreeCopy.rule(for: "npm-debug.log", isFolder: false) != nil)
        #expect(WorktreeCopy.rule(for: "bootstrap/cache/config.php", isFolder: false) == "Laravel’s cache, with this checkout’s paths in it")
        #expect(WorktreeCopy.rule(for: "public/hot", isFolder: false) != nil)
        #expect(WorktreeCopy.rule(for: "storage/framework/down", isFolder: false) != nil)
        #expect(WorktreeCopy.rule(for: "tmp/server.pid", isFolder: false) != nil)
        #expect(WorktreeCopy.rule(for: ".build", isFolder: true) != nil && WorktreeCopy.rule(for: "ios/DerivedData", isFolder: true) != nil)
        #expect(WorktreeCopy.rule(for: ".venv", isFolder: true, isVirtualenv: true) != nil)
        #expect(WorktreeCopy.rule(for: ".DS_Store", isFolder: false) != nil)
        // What a new worktree needs, and caches that rebuild harmlessly, are copied.
        for path in ["vendor", "node_modules", "public/build", ".next", "target", "storage/framework/views", ".venv"] {
            #expect(WorktreeCopy.rule(for: path, isFolder: true) == nil, "\(path)")
        }
        #expect(WorktreeCopy.rule(for: ".env", isFolder: false) == nil)
        #expect(WorktreeCopy.rule(for: "logs.txt", isFolder: false) == nil)
    }

    @Test func linksThatStayInside() {
        #expect(WorktreeCopy.linkStaysInside("node_modules/.bin/vite", target: "../vite/bin/vite.js"))
        #expect(WorktreeCopy.linkStaysInside("current", target: "releases/2"))
        #expect(!WorktreeCopy.linkStaysInside("public/storage", target: "/Users/m/Code/app/storage/app/public"))
        #expect(!WorktreeCopy.linkStaysInside("public/storage", target: "../../other/storage"))
        #expect(!WorktreeCopy.linkStaysInside("node_modules", target: "../app/node_modules"))
        #expect(!WorktreeCopy.linkStaysInside("x", target: ""))
    }

    @Test func whatTheSheetAndTheNoticeSay() {
        #expect(WorktreeCopy.checkboxTitle(ignored: [".env", "storage/", "vendor/", "node_modules/", ".claude/"])
                == "Copy ignored files too: node_modules/, vendor/, .env…")
        #expect(WorktreeCopy.checkboxTitle(ignored: ["dist/"]) == "Copy ignored files too: dist/")
        #expect(WorktreeCopy.checkboxTitle(ignored: [".claude/", ".worktrees/", ".DS_Store"]) == nil)
        #expect(WorktreeCopy.checkboxTitle(ignored: []) == nil)
        #expect(WorktreeCopy.footnote(checkout: "xCloud").hasPrefix("xCloud and its changes stay as they are. The new folder also gets clones of what xCloud’s git ignores"))

        var report = WorktreeCopy.Report()
        #expect(WorktreeCopy.notice(report, hints: []) == "")
        report.copied = ["vendor/laravel", "vendor/symfony", ".env"]
        report.entries = 2
        report.leftOut = [.init("storage/logs/laravel.log", .rule("a log")), .init("x", .failed("Permission denied"))]
        #expect(WorktreeCopy.notice(report, hints: ["composer install"]) == "; copied 2 ignored items, 1 left out; run composer install there")
        #expect(report.failures == [.init("x", .failed("Permission denied"))])
        report.stopped = true
        #expect(WorktreeCopy.notice(report, hints: []) == "; copied 2 ignored items before Stop, 1 left out")
        #expect(WorktreeCopy.logText(report).contains("  storage/logs/laravel.log: a log"))
    }

    @Test func whatToRunThere() {
        #expect(WorktreeCopy.hints(differs: ["composer.lock", "package-lock.json"], vendorCopied: true, classmapCopied: true, headsDiffer: true,
                                   nodeModulesCopied: true) == ["composer install", "npm install"])
        #expect(WorktreeCopy.hints(differs: [], vendorCopied: true, classmapCopied: true, headsDiffer: true, nodeModulesCopied: false) == ["composer dump-autoload"])
        #expect(WorktreeCopy.hints(differs: [], vendorCopied: true, classmapCopied: true, headsDiffer: false, nodeModulesCopied: true).isEmpty)
        #expect(WorktreeCopy.hints(differs: ["bun.lock", "bun.lockb"], vendorCopied: false, classmapCopied: false, headsDiffer: true,
                                   nodeModulesCopied: true) == ["bun install"])
        #expect(WorktreeCopy.hints(differs: ["composer.lock"], vendorCopied: false, classmapCopied: false, headsDiffer: true, nodeModulesCopied: false).isEmpty)
    }

    /// Two folders on the same disk: the checkout and the new worktree.
    struct Folders {
        let base: String
        var source: String { base + "/app" }
        var destination: String { base + "/app-wt-x" }
        init() throws {
            base = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-copy-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: base + "/app", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: base + "/app-wt-x", withIntermediateDirectories: true)
        }
        func write(_ path: String, _ text: String, in root: String? = nil) throws {
            let full = (root ?? source) + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: false, encoding: .utf8)
        }
        func read(_ path: String) -> String? { try? String(contentsOfFile: destination + "/" + path, encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
    }

    @Test func clonesKeepLinksModesAndTimesAndLeaveTheRest() throws {
        let f = try Folders()
        defer { f.remove() }
        guard WorktreeCopy.canClone(from: f.source, into: f.destination) else { return } // not an APFS disk here
        let fm = FileManager.default
        try f.write("node_modules/vite/bin/vite.js", "#!/usr/bin/env node\n")
        chmod(f.source + "/node_modules/vite/bin/vite.js", 0o755)
        try fm.createDirectory(atPath: f.source + "/node_modules/.bin", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.source + "/node_modules/.bin/vite", withDestinationPath: "../vite/bin/vite.js")
        try f.write("vendor/laravel/framework/src/App.php", "<?php\n")
        try f.write("vendor/autoload.php", "<?php\n")
        try f.write(".env", "APP_KEY=x\n")
        try f.write("storage/logs/laravel.log", "error\n")
        try f.write("bootstrap/cache/config.php", "<?php return ['path' => '/app'];\n")
        try fm.createDirectory(atPath: f.source + "/public", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.source + "/public/storage", withDestinationPath: f.source + "/storage/app/public")
        try f.write(".venv/pyvenv.cfg", "home = /usr/bin\n")
        mkfifo(f.source + "/queue.fifo", 0o644)
        // A worktree nested inside, and a folder holding a worktree's .git file.
        try f.write(".claude/worktrees/agent-1/.git", "gitdir: /app/.git/worktrees/agent-1\n")
        try f.write(".claude/settings.local.json", "{}\n")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: f.source + "/vendor/autoload.php")

        let entries = ["node_modules/", "vendor/", ".env", "storage/logs/laravel.log", "bootstrap/cache/config.php", "public/storage", ".venv/",
                       "queue.fifo", ".claude/"]
        var seen: [String] = []
        let report = WorktreeCopy.clone(entries, from: f.source, to: f.destination, worktrees: [f.source, f.source + "/.claude/worktrees/agent-1"],
                                        hasTracked: { _ in false }) { entry, _, _ in seen.append(entry) }
        #expect(report.fatal == nil && !report.stopped)
        #expect(seen.count == entries.count)
        // A level down: each package and vendor its own call.
        #expect(report.copied.contains("node_modules/vite") && report.copied.contains("node_modules/.bin") && report.copied.contains("vendor/laravel"))
        #expect(try fm.destinationOfSymbolicLink(atPath: f.destination + "/node_modules/.bin/vite") == "../vite/bin/vite.js")
        var info = stat()
        #expect(stat(f.destination + "/node_modules/vite/bin/vite.js", &info) == 0 && info.st_mode & 0o777 == 0o755)
        let modified = try fm.attributesOfItem(atPath: f.destination + "/vendor/autoload.php")[.modificationDate] as? Date
        #expect(modified == old)
        #expect(f.read(".env") == "APP_KEY=x\n" && f.read(".claude/settings.local.json") == "{}\n")
        // Left out, each with its reason.
        let left = Dictionary(report.leftOut.map { ($0.path, $0.why) }, uniquingKeysWith: { a, _ in a })
        #expect(left["storage/logs/laravel.log"] == .rule("a log of this checkout’s"))
        #expect(left["bootstrap/cache/config.php"] != nil && left[".venv"] != nil)
        #expect(left["public/storage"] == .linkOut && left["queue.fifo"] == .special)
        #expect(left[".claude/worktrees/agent-1"] == .worktree)
        for path in ["storage/logs/laravel.log", "bootstrap/cache/config.php", "public/storage", ".venv", "queue.fifo", ".claude/worktrees/agent-1"] {
            var gone = stat()
            #expect(lstat(f.destination + "/" + path, &gone) != 0, "\(path)")
        }
        #expect(report.entries == 4) // node_modules, vendor, .env, .claude
        #expect(WorktreeCopy.hints(for: report, source: f.source, destination: f.destination, git: "/usr/bin/false") == ["php artisan storage:link"])
    }

    @Test func nothingIsWrittenOverWhatIsThere() throws {
        let f = try Folders()
        defer { f.remove() }
        guard WorktreeCopy.canClone(from: f.source, into: f.destination) else { return }
        try f.write("vendor/a/x.php", "source\n")
        try f.write("vendor/b/y.php", "source\n")
        try f.write("node_modules/p/index.js", "source\n")
        try f.write(".env", "source\n")
        // The new branch tracks vendor/.gitkeep, and has its own vendor/a and .env; node_modules was made by a hook.
        try f.write("vendor/.gitkeep", "", in: f.destination)
        try f.write("vendor/a/x.php", "theirs\n", in: f.destination)
        try f.write(".env", "theirs\n", in: f.destination)
        try f.write("node_modules/q/index.js", "installed\n", in: f.destination)
        let report = WorktreeCopy.clone(["vendor/", "node_modules/", ".env"], from: f.source, to: f.destination, worktrees: [],
                                        hasTracked: { $0 == "vendor" })
        #expect(f.read("vendor/a/x.php") == "theirs\n" && f.read(".env") == "theirs\n")
        #expect(f.read("vendor/b/y.php") == "source\n") // missing there: added
        #expect(f.read("node_modules/p/index.js") == nil && f.read("node_modules/q/index.js") == "installed\n")
        let left = report.leftOut.map(\.path)
        #expect(left.contains("vendor/a") && left.contains(".env") && left.contains("node_modules"))
        #expect(report.failures.isEmpty)
    }

    @Test func stopEndsBetweenCalls() throws {
        let f = try Folders()
        defer { f.remove() }
        guard WorktreeCopy.canClone(from: f.source, into: f.destination) else { return }
        try f.write("a/1", "1")
        try f.write("b/2", "2")
        let stop = WorktreeCopy.Stop()
        let report = WorktreeCopy.clone(["a/", "b/"], from: f.source, to: f.destination, worktrees: [], hasTracked: { _ in false }, stop: stop) { entry, _, _ in
            if entry == "b" { stop.set() }
        }
        #expect(report.stopped && report.copied == ["a/1"] && f.read("b/2") == nil)
    }

    @Test func aDiskElsewhereGetsNoCopy() throws {
        let f = try Folders()
        defer { f.remove() }
        #expect(!WorktreeCopy.canClone(from: f.source, into: "/dev/null/new"))
        #expect(!WorktreeCopy.canClone(from: f.base + "/missing", into: f.destination))
    }

    /// git's own list: a folder the new branch doesn't ignore whole is gone through for what it does ignore.
    @Test func whatTheNewBranchIgnoresToo() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        try repo.write(".gitignore", "vendor/\n.env\n.claude/worktrees/\n.claude/settings.local.json\nbuild/\n")
        repo.run(["add", ".gitignore"])
        repo.run(["commit", "-qm", "Ignore"])
        try repo.write("vendor/a/x.php", "<?php\n")
        try repo.write(".env", "A=1\n")
        try repo.write(".claude/settings.local.json", "{}\n")
        try repo.write(".claude/worktrees/w/.git", "gitdir: x\n")
        try repo.write("build/out.js", "x\n")
        // The new branch stops ignoring build/ and tracks it.
        repo.run(["switch", "-qc", "next"])
        try repo.write(".gitignore", "vendor/\n.env\n.claude/worktrees/\n.claude/settings.local.json\n")
        repo.run(["add", ".gitignore", "build/out.js"])
        repo.run(["commit", "-qm", "Track build"])
        repo.run(["switch", "-q", "main"])
        try repo.write("build/out.js", "x\n") // gone with the switch (next tracks it): ignored here again
        let destination = repo.base + "/xCloud-wt-next"
        repo.run(["worktree", "add", "-q", destination, "next"])
        let listed = try #require(WorktreeCopy.ignoredEntries(in: repo.path, git: git))
        #expect(listed.contains(".claude/") && listed.contains("vendor/") && listed.contains("build/"))
        let kept = try #require(WorktreeCopy.entries(from: repo.path, to: destination, git: git))
        #expect(kept.contains("vendor/") && kept.contains(".env") && kept.contains(".claude/settings.local.json") && kept.contains(".claude/worktrees/"))
        #expect(!kept.contains("build/") && !kept.contains(".claude/"))
        #expect(WorktreeCopy.worktrees(of: repo.path, git: git).map(canonicalPath).contains(canonicalPath(destination)))
        let report = WorktreeCopy.clone(kept, from: repo.path, to: destination, worktrees: WorktreeCopy.worktrees(of: repo.path, git: git),
                                        hasTracked: { _ in false })
        #expect(FileManager.default.fileExists(atPath: destination + "/vendor/a/x.php") || !WorktreeCopy.canClone(from: repo.path, into: destination))
        #expect(report.leftOut.contains(.init(".claude/worktrees/w", .worktree)) || report.fatal != nil)
        #expect(repo.output(["-C", destination, "status", "--porcelain"]).isEmpty, "nothing tracked there was touched")
    }
}
