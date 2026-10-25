import Foundation
import Testing
@testable import NextTermCore

/// The ignored files copied or linked: the choice and how it is remembered, the rules for what is left out, links
/// that stay inside, what the sheet and the notice say, real clones in temporary folders (an APFS disk) with links
/// kept as links, nothing over what is there, other worktrees and links out of the checkout left out, and git's own
/// list of what the new branch ignores; real links, relative, one for an entry where the new branch ignores a link
/// too, and removing a linked worktree (git's remove, FileManager's) deleting the links, never what they lead to; a
/// workspace package's link made again as it is, and Composer's autoloader cloned, so the new worktree runs its own code.
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

    /// Remembered per repository: what was chosen, else the checkbox as it was left (ticked is Copy), else Leave Out.
    @Test func theChoiceAndHowItIsRemembered() {
        #expect(WorktreeCopy.Choice.allCases.map(\.title) == ["Copy", "Link", "Leave Out"])
        #expect(WorktreeCopy.Choice.remembered("link", copiedBefore: true) == .link)
        #expect(WorktreeCopy.Choice.remembered("leaveOut", copiedBefore: true) == .leaveOut)
        #expect(WorktreeCopy.Choice.remembered(nil, copiedBefore: true) == .copy)
        #expect(WorktreeCopy.Choice.remembered(nil, copiedBefore: false) == .leaveOut)
        #expect(WorktreeCopy.Choice.remembered(nil, copiedBefore: nil) == .leaveOut)
        #expect(WorktreeCopy.Choice.remembered("clone", copiedBefore: true) == .copy) // not a choice: as before
        // One plain line each, Link's saying what is shared with whom.
        #expect(WorktreeCopy.line(.copy, main: "xCloud", includes: false) == "independent clones, no extra space until changed")
        #expect(WorktreeCopy.line(.link, main: "xCloud", includes: false) == "shared with xCloud, so changing one changes both")
        #expect(WorktreeCopy.line(.leaveOut, main: "xCloud", includes: false) == "committed files only")
        #expect(WorktreeCopy.line(.leaveOut, main: "xCloud", includes: true) == "only what .worktreeinclude lists is copied")
        let linked = WorktreeCopy.linkFootnote(checkout: "xCloud-wt-a", main: "xCloud")
        #expect(linked.hasPrefix("xCloud-wt-a and its changes stay as they are. The new folder also gets links to what xCloud’s git ignores"))
        #expect(linked.contains("shared, so an install or an edit in either is in both") && linked.contains("Removing the worktree deletes only the links"))
    }

    @Test func whatTheSheetAndTheNoticeSay() {
        #expect(WorktreeCopy.choiceTitle(ignored: [".env", "storage/", "vendor/", "node_modules/", ".claude/"])
                == "Ignored files: node_modules/, vendor/, .env…")
        #expect(WorktreeCopy.choiceTitle(ignored: ["dist/"]) == "Ignored files: dist/")
        #expect(WorktreeCopy.choiceTitle(ignored: [".claude/", ".worktrees/", ".DS_Store"]) == nil)
        #expect(WorktreeCopy.choiceTitle(ignored: []) == nil)
        // From git's own list: only what is at the checkout's top.
        #expect(WorktreeCopy.choiceTitle(listed: ["storage/logs/laravel.log", "vendor/", ".env", "public/hot", ".claude/worktrees/"])
                == "Ignored files: vendor/, .env")
        #expect(WorktreeCopy.choiceTitle(listed: ["storage/logs/laravel.log"]) == nil)
        #expect(WorktreeCopy.footnote(checkout: "xCloud", source: "xCloud")
            .hasPrefix("xCloud and its changes stay as they are. The new folder also gets clones of what xCloud’s git ignores"))
        // From a worktree's window, the clones come from the main checkout, as the links do.
        #expect(WorktreeCopy.footnote(checkout: "xCloud-wt-a", source: "xCloud")
            .hasPrefix("xCloud-wt-a and its changes stay as they are. The new folder also gets clones of what xCloud’s git ignores"))

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

        // Linked: the words say so, with what to know before installing there.
        var links = WorktreeCopy.Report()
        links.links = true
        links.copied = ["node_modules", ".env", "vendor/laravel"]
        links.entries = 3
        let warning = "composer.lock differs, and vendor/ is shared with xCloud: an install there changes both"
        #expect(WorktreeCopy.notice(links, hints: ["php artisan storage:link"], warnings: [warning])
                == "; linked 3 ignored items; " + warning + "; run php artisan storage:link there")
        #expect(WorktreeCopy.logText(links).hasPrefix("Linked 3 (shared with the checkout") && WorktreeCopy.logText(links).contains("deletes only the links"))
    }

    /// Linked, an install there changes the main checkout's too: said when a lock file differs.
    @Test func whatToKnowBeforeInstallingInALinkedWorktree() {
        #expect(WorktreeCopy.sharedWarnings(differs: ["composer.lock", "yarn.lock"], vendorLinked: true, nodeModulesLinked: true, main: "xCloud") == [
            "composer.lock differs, and vendor/ is shared with xCloud: an install there changes both",
            "yarn.lock differs, and node_modules/ is shared with xCloud: an install there changes both",
        ])
        #expect(WorktreeCopy.sharedWarnings(differs: ["composer.lock"], vendorLinked: false, nodeModulesLinked: true, main: "xCloud").isEmpty)
        #expect(WorktreeCopy.sharedWarnings(differs: [], vendorLinked: true, nodeModulesLinked: true, main: "xCloud").isEmpty)
    }

    /// Relative on one volume, so moving the folder holding both keeps them working; absolute across volumes.
    @Test func whereALinkLeads() {
        #expect(WorktreeCopy.linkTarget("node_modules", source: "/Users/m/Code/xCloud", destination: "/Users/m/Code/xCloud-wt-x", sameVolume: true)
                == "../xCloud/node_modules")
        #expect(WorktreeCopy.linkTarget("public/build", source: "/Users/m/Code/xCloud", destination: "/Users/m/Code/xCloud-wt-x", sameVolume: true)
                == "../../xCloud/public/build")
        // A worktree inside the checkout, in .claude/worktrees.
        #expect(WorktreeCopy.linkTarget(".env", source: "/Users/m/Code/xCloud", destination: "/Users/m/Code/xCloud/.claude/worktrees/x", sameVolume: true)
                == "../../../.env")
        // Farther apart.
        #expect(WorktreeCopy.linkTarget("vendor", source: "/Users/m/Code/xCloud", destination: "/Users/m/wt/x", sameVolume: true) == "../../Code/xCloud/vendor")
        #expect(WorktreeCopy.linkTarget("vendor", source: "/Users/m/Code/xCloud", destination: "/Volumes/Fast/x", sameVolume: false) == "/Users/m/Code/xCloud/vendor")
    }

    /// Links lead to the main checkout, which Remove Worktree never removes; none in a bare repository, any of whose
    /// worktrees can be removed: Link is off there.
    @Test func whereLinksLeadFrom() throws {
        let f = try Folders()
        defer { f.remove() }
        try FileManager.default.createDirectory(atPath: f.source + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: f.base + "/app.git", withIntermediateDirectories: true)
        #expect(WorktreeCopy.linkSource(main: f.source) == f.source)
        #expect(WorktreeCopy.linkSource(main: f.base + "/app.git") == nil)
        #expect(WorktreeCopy.cantLink.hasPrefix("Linking needs the repository’s main checkout, and a bare repository has none"))
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

    @Test func linksKeepTheRulesAndLeadBack() throws {
        let f = try Folders()
        defer { f.remove() }
        let fm = FileManager.default
        try f.write("node_modules/vite/bin/vite.js", "#!/usr/bin/env node\n")
        try fm.createDirectory(atPath: f.source + "/node_modules/.bin", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.source + "/node_modules/.bin/vite", withDestinationPath: "../vite/bin/vite.js")
        try f.write("vendor/laravel/framework/src/App.php", "<?php\n")
        try f.write("vendor/autoload.php", "<?php\n")
        try f.write(".env", "APP_KEY=x\n")
        try f.write("storage/logs/laravel.log", "error\n")
        try f.write("storage/logs/keep.log", "kept\n")
        try f.write("bootstrap/cache/config.php", "<?php return ['path' => '/app'];\n")
        try fm.createDirectory(atPath: f.source + "/public", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.source + "/public/storage", withDestinationPath: f.source + "/storage/app/public")
        try f.write(".venv/pyvenv.cfg", "home = /usr/bin\n")
        mkfifo(f.source + "/queue.fifo", 0o644)
        try f.write(".claude/worktrees/agent-1/.git", "gitdir: /app/.git/worktrees/agent-1\n")
        try f.write(".claude/settings.local.json", "{}\n")
        try f.write("node_modules/.DS_Store", "")
        // Ignored by name, but holding what Copy leaves out a level down: a log, a worktree.
        try f.write("logs/app.log", "error\n")
        try f.write("logs/keep.txt", "kept\n")
        try f.write("trees/w/.git", "gitdir: /elsewhere\n")
        try f.write("trees/notes.md", "notes\n")

        let entries = ["node_modules/", "vendor/", ".env", "storage/logs/laravel.log", "storage/logs/keep.log", "bootstrap/cache/config.php",
                       "public/storage", ".venv/", "queue.fifo", ".claude/", "logs/", "trees/"]
        // The new branch ignores a link named node_modules too (`/node_modules`), but vendor only as a folder (`vendor/`).
        let report = WorktreeCopy.link(entries, from: f.source, to: f.destination, worktrees: [f.source, f.source + "/.claude/worktrees/agent-1"],
                                       includes: ["storage/logs/keep.log"], linkable: ["node_modules", ".claude", "logs", "trees"])
        #expect(report.links && report.fatal == nil && report.failures.isEmpty)
        func target(_ path: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: f.destination + "/" + path) }
        func kind(_ path: String) -> mode_t? {
            var info = stat()
            return lstat(f.destination + "/" + path, &info) == 0 ? info.st_mode & S_IFMT : nil
        }
        // One link for node_modules and .env, relative; vendor a folder of its own with a link for each thing in it.
        #expect(target("node_modules") == "../app/node_modules" && target(".env") == "../app/.env")
        #expect(kind("vendor") == S_IFDIR && target("vendor/laravel") == "../../app/vendor/laravel" && target("vendor/autoload.php") == "../../app/vendor/autoload.php")
        // .claude holds a worktree: a folder of its own, its file linked, the worktree left out.
        #expect(kind(".claude") == S_IFDIR && target(".claude/settings.local.json") == "../../app/.claude/settings.local.json")
        #expect(f.read("node_modules/vite/bin/vite.js") == "#!/usr/bin/env node\n" && f.read(".env") == "APP_KEY=x\n")
        #expect(try fm.destinationOfSymbolicLink(atPath: f.source + "/node_modules/.bin/vite") == "../vite/bin/vite.js")
        // .worktreeinclude brings a log back, linked too.
        #expect(target("storage/logs/keep.log") == "../../../app/storage/logs/keep.log")
        // A folder holding what Copy leaves out is gone through, so that stays out (Finder's .DS_Store is no reason).
        #expect(kind("logs") == S_IFDIR && target("logs/keep.txt") == "../../app/logs/keep.txt" && kind("logs/app.log") == nil)
        #expect(kind("trees") == S_IFDIR && target("trees/notes.md") == "../../app/trees/notes.md" && kind("trees/w") == nil)
        // Shared: a change through a link is the checkout's.
        try "APP_KEY=y\n".write(toFile: f.destination + "/.env", atomically: false, encoding: .utf8)
        #expect(try String(contentsOfFile: f.source + "/.env", encoding: .utf8) == "APP_KEY=y\n")
        // Left out as Copy leaves them out, each with its reason.
        let left = Dictionary(report.leftOut.map { ($0.path, $0.why) }, uniquingKeysWith: { a, _ in a })
        #expect(left["storage/logs/laravel.log"] == .rule("a log of this checkout’s") && left["bootstrap/cache/config.php"] != nil && left[".venv"] != nil)
        #expect(left["public/storage"] == .linkOut && left["queue.fifo"] == .special && left[".claude/worktrees/agent-1"] == .worktree)
        #expect(left["logs/app.log"] == .rule("a log of this checkout’s") && left["trees/w"] == .worktree)
        for path in ["storage/logs/laravel.log", "bootstrap/cache/config.php", "public", ".venv", "queue.fifo", ".claude/worktrees/agent-1"] {
            #expect(kind(path) == nil, "\(path)")
        }
        #expect(report.entries == 7) // node_modules, vendor, .env, keep.log, .claude, logs, trees
        #expect(WorktreeCopy.hints(for: report, source: f.source, destination: f.destination, git: "/usr/bin/false") == ["php artisan storage:link"])
    }

    /// Composer's own (vendor/composer, vendor/autoload.php, vendor/bin) is cloned, never linked: PHP follows links for
    /// `__DIR__`, so linked it would load the main checkout's app/ and tests/ there, and an install there would point
    /// the main checkout's autoloader at the new worktree. Its packages are linked, with `vendor/` and `/vendor` alike;
    /// a path repository's package (vendor/acme/pkg → ../../packages/pkg) leads to the new worktree's own.
    @Test func composersAutoloaderIsTheNewWorktreesOwn() throws {
        for linkable: Set<String> in [[], ["vendor"]] {
            let f = try Folders()
            defer { f.remove() }
            let fm = FileManager.default
            try f.write("vendor/autoload.php", "<?php\nreturn require_once __DIR__ . '/composer/autoload_real.php';\n")
            try f.write("vendor/composer/autoload_psr4.php", "<?php\n$vendorDir = dirname(__DIR__);\n")
            try f.write("vendor/composer/installed.json", "{}\n")
            try f.write("vendor/bin/phpunit", "#!/usr/bin/env php\n")
            try f.write("vendor/laravel/framework/src/App.php", "<?php\n")
            try fm.createDirectory(atPath: f.source + "/vendor/acme", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: f.source + "/vendor/acme/pkg", withDestinationPath: "../../packages/pkg")
            let report = WorktreeCopy.link(["vendor/"], from: f.source, to: f.destination, worktrees: [], linkable: linkable)
            func target(_ path: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: f.destination + "/" + path) }
            func kind(_ path: String) -> mode_t? {
                var info = stat()
                return lstat(f.destination + "/" + path, &info) == 0 ? info.st_mode & S_IFMT : nil
            }
            #expect(kind("vendor") == S_IFDIR && target("vendor/laravel") == "../../app/vendor/laravel", "\(linkable)")
            #expect(target("vendor/acme/pkg") == "../../packages/pkg" && kind("vendor/acme") == S_IFDIR)
            let hints = WorktreeCopy.hints(for: report, source: f.source, destination: f.destination, git: "/usr/bin/false")
            if WorktreeCopy.canClone(from: f.source, into: f.destination) {
                #expect(kind("vendor/composer") == S_IFDIR && kind("vendor/autoload.php") == S_IFREG && kind("vendor/bin") == S_IFDIR)
                #expect(kind("vendor/composer/autoload_psr4.php") == S_IFREG && f.read("vendor/composer/installed.json") == "{}\n")
                #expect(report.copied.contains("vendor/composer") && report.failures.isEmpty)
                #expect(hints.isEmpty) // the same HEAD (git can't say here): its classmap is right
            } else {
                // A disk that can't clone: left out, never linked, and composer install makes them there.
                #expect(kind("vendor/composer") == nil && kind("vendor/autoload.php") == nil && kind("vendor/bin") == nil)
                #expect(report.leftOut.contains(.init("vendor/composer", WorktreeCopy.composerLeftOut("app"))))
                #expect(hints == ["composer install"])
            }
        }
        // Without vendor/composer, vendor/ is no Composer's: linked whole where a link may stand for it.
        let f = try Folders()
        defer { f.remove() }
        try f.write("vendor/autoload.php", "<?php\n")
        let report = WorktreeCopy.link(["vendor/"], from: f.source, to: f.destination, worktrees: [], linkable: ["vendor"])
        #expect(report.copied == ["vendor"] && (try? FileManager.default.destinationOfSymbolicLink(atPath: f.destination + "/vendor")) == "../app/vendor")
    }

    @Test func nothingIsLinkedOverWhatIsThere() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.write("vendor/a/x.php", "source\n")
        try f.write("node_modules/p/index.js", "source\n")
        try f.write(".env", "source\n")
        try f.write("dist/app.js", "source\n")
        // The new branch has its own .env and a vendor/.gitkeep; node_modules was made by a hook.
        try f.write("vendor/.gitkeep", "", in: f.destination)
        try f.write(".env", "theirs\n", in: f.destination)
        try f.write("node_modules/q/index.js", "installed\n", in: f.destination)
        let report = WorktreeCopy.link(["vendor/", "node_modules/", ".env", "dist/"], from: f.source, to: f.destination, worktrees: [],
                                       linkable: ["vendor", "node_modules", "dist"])
        #expect(f.read(".env") == "theirs\n" && f.read("node_modules/q/index.js") == "installed\n" && f.read("node_modules/p/index.js") == nil)
        // A folder there is left as it is: a link goes only where git said it is ignored.
        #expect(f.read("vendor/a/x.php") == nil && FileManager.default.fileExists(atPath: f.destination + "/vendor/.gitkeep"))
        #expect(Set(report.leftOut.map(\.path)) == ["vendor", "node_modules", ".env"] && report.leftOut.allSatisfy { $0.why == .alreadyThere })
        #expect(report.copied == ["dist"] && f.read("dist/app.js") == "source\n")
    }

    @Test func stopEndsBetweenLinks() throws {
        let f = try Folders()
        defer { f.remove() }
        try f.write("a", "1")
        try f.write("b", "2")
        let stop = WorktreeCopy.Stop()
        let report = WorktreeCopy.link(["a", "b"], from: f.source, to: f.destination, worktrees: [], linkable: [], stop: stop) { entry, _, _ in
            if entry == "b" { stop.set() }
        }
        #expect(report.stopped && report.copied == ["a"] && f.read("a") == "1" && f.read("b") == nil)
    }

    /// FileManager's removeItem on a linked worktree deletes the links, never what they lead to.
    @Test func removingAFolderOfLinksKeepsWhatTheyLeadTo() throws {
        let f = try Folders()
        defer { f.remove() }
        let fm = FileManager.default
        try f.write("node_modules/vite/index.js", "vite\n")
        try f.write("vendor/a/x.php", "<?php\n")
        try f.write(".env", "APP_KEY=x\n")
        let report = WorktreeCopy.link(["node_modules/", "vendor/", ".env"], from: f.source, to: f.destination, worktrees: [], linkable: ["node_modules"])
        #expect(report.copied == ["node_modules", "vendor/a", ".env"])
        try fm.removeItem(atPath: f.destination)
        #expect(!fm.fileExists(atPath: f.destination))
        #expect(try String(contentsOfFile: f.source + "/node_modules/vite/index.js", encoding: .utf8) == "vite\n")
        #expect(try String(contentsOfFile: f.source + "/vendor/a/x.php", encoding: .utf8) == "<?php\n")
        #expect(try String(contentsOfFile: f.source + "/.env", encoding: .utf8) == "APP_KEY=x\n")
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

    /// In a real repository: links only where the new branch ignores a link too, git seeing no change there, Find in Files
    /// and Go to File's walk never going through one, and Remove Worktree (`git worktree remove`, never forced, and forced
    /// too) deleting the links and never what they lead to.
    @Test func aLinkedWorktreeInARealRepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let fm = FileManager.default
        try repo.write(".gitignore", "node_modules/\n/vendor\n.env\n/cache\nbuild/\n.claude/worktrees/\n")
        repo.run(["add", ".gitignore"])
        repo.run(["commit", "-qm", "Ignore"])
        try repo.write("cache/data.txt", "cached\n")
        try repo.write("node_modules/vite/index.js", "vite\n")
        try repo.write("vendor/a/x.php", "<?php\n")
        try repo.write(".env", "APP_KEY=x\n")
        try repo.write("build/out.js", "x\n")
        // The new branch tracks build/.
        repo.run(["switch", "-qc", "next"])
        try repo.write(".gitignore", "node_modules/\n/vendor\n.env\n/cache\n.claude/worktrees/\n")
        repo.run(["add", ".gitignore", "build/out.js"])
        repo.run(["commit", "-qm", "Track build"])
        repo.run(["switch", "-q", "main"])
        try repo.write("build/out.js", "x\n")
        for (name, branch) in [("xCloud-wt-next", "next"), ("xCloud-wt-forced", "-")] {
            let destination = repo.base + "/" + name
            repo.run(branch == "-" ? ["worktree", "add", "-q", "-b", "forced", destination, "next"] : ["worktree", "add", "-q", destination, branch])
            let entries = try #require(WorktreeCopy.entries(from: repo.path, to: destination, git: git))
            #expect(Set(entries) == ["node_modules/", "vendor/", ".env", "cache/"], "build/ is tracked there")
            // `/vendor` ignores a link named vendor; `node_modules/` only a folder.
            let linkable = try #require(WorktreeCopy.linkable(entries, in: destination, git: git))
            #expect(linkable == ["vendor", "cache"])
            let report = WorktreeCopy.link(entries, from: repo.path, to: destination, worktrees: WorktreeCopy.worktrees(of: repo.path, git: git),
                                           linkable: linkable)
            #expect(report.copied.sorted() == [".env", "cache", "node_modules/vite", "vendor"] && report.failures.isEmpty)
            #expect(try fm.destinationOfSymbolicLink(atPath: destination + "/vendor") == "../xCloud/vendor")
            #expect(try String(contentsOfFile: destination + "/node_modules/vite/index.js", encoding: .utf8) == "vite\n")
            // Neither git's list nor a walk goes through a link: nothing of the main checkout's is searched twice.
            let searched = ProjectSearch.files(in: destination, git: git)
            #expect(!searched.isEmpty && !searched.contains { $0.hasPrefix("cache/") || $0.hasPrefix("node_modules/") || $0.hasPrefix("vendor/") || $0 == ".env" })
            #expect(!FileWalker.files(in: destination).paths.contains("cache/data.txt"))
            // Ignored, every one: no change for git, so Remove Worktree goes ahead.
            #expect(repo.output(["-C", destination, "status", "--porcelain"]).isEmpty)
            #expect(WorktreeRemoval.changedFiles(at: destination, git: git) == 0)
            #expect(repo.output(["-C", destination, "status", "--porcelain", "--ignored"]).contains("!! vendor"))
            let removal = branch == "-" ? ["worktree", "remove", "--force", destination] : WorktreeRemoval.arguments(path: destination)
            #expect(repo.run(removal) == 0)
            #expect(!fm.fileExists(atPath: destination))
            #expect(try String(contentsOfFile: repo.path + "/node_modules/vite/index.js", encoding: .utf8) == "vite\n")
            #expect(try String(contentsOfFile: repo.path + "/vendor/a/x.php", encoding: .utf8) == "<?php\n")
            #expect(try String(contentsOfFile: repo.path + "/.env", encoding: .utf8) == "APP_KEY=x\n")
        }
    }

    /// A workspace package (npm, yarn and pnpm link node_modules/@acme/utils → ../../packages/utils): linked, the link is
    /// made again as it is, so it leads to the new worktree's own packages/utils, the branch's, never the main checkout's
    /// tracked source; with `node_modules/` and `/node_modules` alike. The rest is the main checkout's, linked.
    @Test func aWorkspacePackageLeadsToTheBranchsOwn() throws {
        guard let git = GitRunner.locateGit() else { return }
        let fm = FileManager.default
        for pattern in ["node_modules/", "/node_modules"] {
            let repo = try TemporaryRepository(git: git)
            defer { repo.remove() }
            try repo.write(".gitignore", pattern + "\n")
            try repo.write("packages/utils/index.js", "main version\n")
            repo.run(["add", ".gitignore", "packages/utils/index.js"])
            repo.run(["commit", "-qm", "Utils"])
            repo.run(["switch", "-qc", "fix/x"])
            try repo.write("packages/utils/index.js", "branch version\n")
            repo.run(["commit", "-qam", "Change utils"])
            repo.run(["switch", "-q", "main"])
            try repo.write("node_modules/vite/bin/vite.js", "vite\n")
            try fm.createDirectory(atPath: repo.path + "/node_modules/.bin", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: repo.path + "/node_modules/.bin/vite", withDestinationPath: "../vite/bin/vite.js")
            try repo.write("node_modules/@acme/other/index.js", "other\n") // a scoped package from the registry
            try fm.createSymbolicLink(atPath: repo.path + "/node_modules/@acme/utils", withDestinationPath: "../../packages/utils")
            let destination = repo.base + "/xCloud-wt-x"
            repo.run(["worktree", "add", "-q", destination, "fix/x"])
            let entries = try #require(WorktreeCopy.entries(from: repo.path, to: destination, git: git))
            let linkable = try #require(WorktreeCopy.linkable(entries, in: destination, git: git))
            let whole: Set<String> = pattern == "/node_modules" ? ["node_modules"] : [] // `node_modules/` ignores no link
            #expect(entries == ["node_modules/"] && linkable == whole, "\(pattern)")
            let report = WorktreeCopy.link(entries, from: repo.path, to: destination, worktrees: WorktreeCopy.worktrees(of: repo.path, git: git),
                                           linkable: linkable)
            #expect(report.failures.isEmpty && report.fatal == nil)
            // The branch's own, through the link made again as it is.
            #expect(canonicalPath(destination + "/node_modules/@acme/utils") == canonicalPath(destination + "/packages/utils"), "\(pattern)")
            #expect(try fm.destinationOfSymbolicLink(atPath: destination + "/node_modules/@acme/utils") == "../../packages/utils")
            #expect(try String(contentsOfFile: destination + "/node_modules/@acme/utils/index.js", encoding: .utf8) == "branch version\n")
            // The rest is the main checkout's: the packages linked whole, the .bin link leading to one of them.
            #expect(try fm.destinationOfSymbolicLink(atPath: destination + "/node_modules/vite") == "../../xCloud/node_modules/vite")
            #expect(try fm.destinationOfSymbolicLink(atPath: destination + "/node_modules/@acme/other") == "../../../xCloud/node_modules/@acme/other")
            #expect(canonicalPath(destination + "/node_modules/.bin/vite") == canonicalPath(repo.path + "/node_modules/vite/bin/vite.js"))
            #expect(repo.output(["-C", destination, "status", "--porcelain"]).isEmpty, "nothing tracked there was touched")
        }
    }
}
