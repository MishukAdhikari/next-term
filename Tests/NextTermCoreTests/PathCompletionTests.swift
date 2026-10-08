import Foundation
import Testing
@testable import NextTermCore

@Suite struct PathCompletionTests {
    /// A temp folder with these folders and files (a name ending in `/` is a folder).
    func tree(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-paths-" + UUID().uuidString)
        for name in names {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        return dir
    }

    func candidates(_ dir: URL, _ typed: String, foldersOnly: Bool) -> PathCompletion.Result {
        let listing = PathCompletion.list(dir.path)
        return PathCompletion.Prepared(listing, foldersOnly: foldersOnly, hidden: typed.hasPrefix(".")).candidates(typed)
    }

    func names(_ result: PathCompletion.Result) -> [String] {
        result.candidates.map { $0.display + ($0.isFolder ? "/" : "") }
    }

    @Test func folderOnlyCommands() throws {
        // AE1: `cd So` lists Sources/ first, then Resources/, and not the file.
        let dir = try tree(["Sources/", "Resources/", "Sourcery.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(names(candidates(dir, "So", foldersOnly: true)) == ["Sources/", "Resources/"])
        // `ls So` lists the file too, a prefix match ahead of the fuzzy one.
        #expect(names(candidates(dir, "So", foldersOnly: false)) == ["Sources/", "Sourcery.txt", "Resources/"])
        let first = candidates(dir, "So", foldersOnly: true).candidates.first
        #expect(first?.prefix == true && first?.highlights == [0, 1] && first?.enterable == true)
    }

    @Test func oneMatch() throws {
        // AE2: Tests/ is the only entry starting with "Te".
        let dir = try tree(["Sources/", "Resources/", "Tests/", "Sourcery.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = candidates(dir, "Te", foldersOnly: true)
        #expect(names(result) == ["Tests/"] && result.total == 1 && result.candidates[0].prefix)
    }

    @Test func foldersOnlyInATreeLikeEtc() throws {
        // AE9's case, in a temp copy: files and folders mixed, `cd` with nothing typed lists folders only.
        let dir = try tree(["apache2/", "cups/", "hosts", "passwd", "ssh/", "zshrc", ".hidden/"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(names(candidates(dir, "", foldersOnly: true)) == ["apache2/", "cups/", "ssh/"])
    }

    @Test func hiddenEntries() throws {
        let dir = try tree([".git/", ".gitignore", "git-notes/", "src/"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(names(candidates(dir, "g", foldersOnly: false)) == ["git-notes/"])
        #expect(names(candidates(dir, ".g", foldersOnly: false)).prefix(2) == [".git/", ".gitignore"])
        #expect(!names(candidates(dir, "", foldersOnly: false)).contains(".git/"))
    }

    @Test func links() throws {
        let dir = try tree(["real/", "file.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("toReal").path, withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("toFile").path, withDestinationPath: "file.txt")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("toNothing").path, withDestinationPath: "gone")
        // A link to a folder counts as a folder; a broken link and a link to a file are left out of `cd`.
        #expect(names(candidates(dir, "to", foldersOnly: true)) == ["toReal/"])
        #expect(Set(names(candidates(dir, "to", foldersOnly: false))) == ["toReal/", "toFile", "toNothing"])
    }

    @Test func aFolderThatCantBeEnteredIsMarked() throws {
        let dir = try tree(["locked/", "open/"])
        defer {
            chmod(dir.appendingPathComponent("locked").path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        chmod(dir.appendingPathComponent("locked").path, 0o600)
        let result = candidates(dir, "", foldersOnly: true)
        #expect(result.candidates.map(\.enterable) == [false, true])
    }

    @Test func unicodeNames() throws {
        let nfd = "Cafe\u{301}"   // as older file systems keep it
        let dir = try tree([nfd + "/", "École/", "Straße/"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let listing = PathCompletion.list(dir.path)
        let prepared = PathCompletion.Prepared(listing, foldersOnly: true, hidden: false)
        // NFC input finds the NFD name, é finds É; the name keeps its bytes for inserting.
        let cafe = prepared.candidates("café").candidates
        #expect(cafe.count == 1 && cafe.first.map { CompletionRanking.key($0.display) } == CompletionRanking.key("café"))
        #expect(prepared.candidates("éco").candidates.first?.display.precomposedStringWithCanonicalMapping == "École")
        // A name whose folded key changes length gets no highlight.
        let strasse = prepared.candidates("strasse").candidates.first
        #expect(strasse?.display == "Straße" && strasse?.highlights == [])
    }

    @Test func aNameThatIsNotUTF8() {
        let listing = PathCompletion.list("/x", read: { _, found in
            _ = found(.init(name: [0x61, 0xFF, 0x62], kind: .folder))
            return true
        })
        let candidate = PathCompletion.Prepared(listing, foldersOnly: true, hidden: false).candidates("a").candidates.first
        #expect(candidate?.display == "a\u{FFFD}b" && candidate?.name == [0x61, 0xFF, 0x62])
    }

    @Test func aFolderRanksByItsName() {
        let listing = PathCompletion.Listing(folder: "/x", entries: [.init("ab", .folder), .init("a", .file), .init("abc", .folder)])
        let result = PathCompletion.Prepared(listing, foldersOnly: false, hidden: false).candidates("a")
        #expect(names(result) == ["a", "ab/", "abc/"])
    }

    @Test func manyEntriesAreCappedWithTheTrueTotal() {
        let listing = PathCompletion.list("/x", read: { _, found in
            for i in 0..<25_000 where !found(.init("f\(i)", i % 2 == 0 ? .folder : .file)) { break }
            return true
        })
        #expect(listing.entries.count == PathCompletion.maxEntries && !listing.complete && listing.allSeen)
        let all = PathCompletion.Prepared(listing, foldersOnly: false, hidden: false).candidates("")
        #expect(all.candidates.count == PathCompletion.maxShown && all.total == 25_000 && all.exact)
        let folders = PathCompletion.Prepared(listing, foldersOnly: true, hidden: false).candidates("")
        #expect(folders.total == 12_500)
        let typed = PathCompletion.Prepared(listing, foldersOnly: false, hidden: false).candidates("f1")
        #expect(!typed.exact)
    }

    @Test func anUnreadableFolderGivesNothing() {
        let listing = PathCompletion.list("/no/such/folder/\(UUID().uuidString)")
        #expect(!listing.readable && listing.entries.isEmpty)
        #expect(PathCompletion.Prepared(listing, foldersOnly: false, hidden: false).candidates("").candidates.isEmpty)
    }

    @Test func aSlowListerHitsTheTimeCap() {
        let started = Date()
        let listing = PathCompletion.list("/x", seconds: 0.05, read: { _, found in
            for i in 0..<10_000 {
                usleep(100)
                if !found(.init("f\(i)", .file)) { break }
            }
            return true
        })
        #expect(!listing.readable && listing.entries.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func oneListingAtATime() async {
        let stuck = DispatchSemaphore(value: 0)
        let lister = PathLister(read: { folder in
            if folder == "/a" { stuck.wait() }
            return PathCompletion.Listing(folder: folder, entries: [])
        })
        #expect(lister.start("/a", done: { _ in }))
        // While the first is stuck, a second Tab starts nothing (zsh's own Tab answers).
        #expect(lister.isBusy && !lister.start("/b", done: { _ in }))
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let started = lister.start("/c", done: { _ in finished.resume() })
            #expect(!started)
            stuck.signal()
            // Once it is done, the next one runs.
            var again = false
            for _ in 0..<200 where !again {
                usleep(5000)
                again = lister.start("/d", done: { _ in finished.resume() })
            }
            #expect(again)
        }
    }

    @Test func aThousandEntriesAreFast() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<1000 {
            if i % 3 == 0 {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder-\(i)"), withIntermediateDirectories: false)
            } else {
                FileManager.default.createFile(atPath: dir.appendingPathComponent("file-\(i).txt").path, contents: nil)
            }
        }
        // This thread's CPU time, the best of three runs: tests running beside it, and other work on the machine,
        // only ever add wall time.
        func cpu() -> Double {
            var now = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now)
            return Double(now.tv_sec) * 1000 + Double(now.tv_nsec) / 1_000_000
        }
        var elapsed = Double.infinity
        var listing = PathCompletion.Listing(folder: dir.path, entries: [])
        var result = PathCompletion.Result()
        for _ in 0..<3 {
            let started = cpu()
            listing = PathCompletion.list(dir.path)
            result = PathCompletion.Prepared(listing, foldersOnly: false, hidden: false).candidates("fo1")
            elapsed = min(elapsed, cpu() - started)
        }
        print("Tab completion: 1,000 entries listed and ranked in \(String(format: "%.1f", elapsed)) ms of CPU time")
        #expect(listing.entries.count == 1000 && !result.candidates.isEmpty)
        // Under 20 ms on a Mac; CI machines are slower and busier.
        #expect(elapsed < (ProcessInfo.processInfo.environment["CI"] == nil ? 20 : 200))
    }
}

@Suite struct CompletionRankingTests {
    @Test func prefixFirstThenFuzzy() {
        let ranking = CompletionRanking(names: ["Resources", "Sources", "sourcery", "docs", "Sourcesx"])
        let ranked = ranking.rank("so")
        #expect(ranked.map { ranking.names[$0.index] } == ["Sources", "sourcery", "Sourcesx", "Resources"])
        #expect(ranked.map(\.prefix) == [true, true, true, false])
        // Matched letters, for the fuzzy one too.
        #expect(ranked[3].highlights == [2, 3])
    }

    @Test func nothingTypedIsAlphabetical() {
        let ranking = CompletionRanking(names: ["b", "A", "c", "a"])
        #expect(ranking.rank("").map { ranking.names[$0.index] } == ["A", "a", "b", "c"])
    }

    @Test func noMatch() {
        #expect(CompletionRanking(names: ["abc"]).rank("xyz").isEmpty)
    }

    @Test func visibleNames() {
        #expect(CompletionRanking.visible("a\nb") == "a\\x0Ab")
        #expect(CompletionRanking.visible("rtl\u{202E}txt") == "rtl\\u{202E}txt")
        #expect(CompletionRanking.visible("café 🙂") == "café 🙂")
    }
}
