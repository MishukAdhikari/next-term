import Foundation
import Testing
@testable import NextTermCore

@Suite struct RemoteListingTests {
    /// Runs a script the way RemoteConnection.run has the host run it: base64 through a login shell's `-c`, in /bin/sh.
    func run(_ script: String, home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", RemoteShell.command(script)]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/bash"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every path under `root` with its size and modification date: what "nothing was written" compares.
    func snapshot(_ root: URL) -> [String] {
        let fm = FileManager.default
        let paths = (fm.subpaths(atPath: root.path) ?? []).sorted()
        return paths.map { path in
            let attributes = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)) ?? [:]
            return "\(path) \(attributes[.size] ?? "") \(attributes[.modificationDate] ?? "")"
        }
    }

    func names(_ result: RemoteListing.Result) -> [String: PathCompletion.Kind] {
        Dictionary(result.listing.entries.map { ($0.display, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func aFolderWithItsTypesAndNothingWritten() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let tree = home.appendingPathComponent("tree")
        for folder in ["Sources", "Resources", ".git", "locked"] {
            try fm.createDirectory(at: tree.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Sourcery.txt", "a\nb", "café", "My Fo'lder $x"] { fm.createFile(atPath: tree.appendingPathComponent(file).path, contents: nil) }
        try fm.createSymbolicLink(atPath: tree.appendingPathComponent("toSources").path, withDestinationPath: "Sources")
        try fm.createSymbolicLink(atPath: tree.appendingPathComponent("gone").path, withDestinationPath: "nowhere")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tree.appendingPathComponent("locked").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tree.appendingPathComponent("locked").path) }

        let before = snapshot(home)
        let output = try run(RemoteListing.script(.absolute(tree.path), live: .none), home: home.path)
        #expect(snapshot(home) == before)
        let result = try #require(RemoteListing.parse(output))
        #expect(result.shell == "bash" && result.quoting == .bash)
        #expect(result.folder.hasSuffix("/tree") && result.listing.complete)
        let found = names(result)
        #expect(found["Sources"] == .folder && found["Resources"] == .folder && found[".git"] == .folder)
        #expect(found["Sourcery.txt"] == .file && found["My Fo'lder $x"] == .file && found["toSources"] == .folder && found["gone"] == .link)
        // A newline and an accent arrive byte for byte (as hex on the way).
        #expect(result.listing.entries.contains { $0.name == Array("a\nb".utf8) })
        #expect(result.listing.entries.contains { $0.display.precomposedStringWithCanonicalMapping == "café" })
        // A folder that can't be entered is marked, to show dimmed.
        let locked = Array((result.folder + "/locked").utf8)
        #expect(result.closed == [locked] && !result.disk.canEnter(locked) && result.disk.canEnter(Array((result.folder + "/Sources").utf8)))
    }

    @Test func wordsNamedFromHomeAndTheShellsFolder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        let fromHome = try #require(RemoteListing.parse(try run(RemoteListing.script(.typed("~/app/"), live: .none), home: home.path)))
        #expect(fromHome.listing.entries.map(\.display) == ["src"])
        #expect(RemoteListing.parse(try run(RemoteListing.script(.typed("/"), live: .none), home: home.path)) != nil)
        // A word relative to the shell's folder, where that folder isn't known (no /proc here, herdr): no list.
        #expect(RemoteListing.parse(try run(RemoteListing.script(.typed("src/"), live: .none), home: home.path)) == nil)
        #expect(RemoteListing.parse(try run(RemoteListing.script(.typed("app/"), live: .pid(tabKey: "t1")), home: home.path)) == nil)
        // A folder that isn't there: no list.
        #expect(RemoteListing.parse(try run(RemoteListing.script(.typed("~/nothing/"), live: .none), home: home.path)) == nil)
    }

    @Test func aTmuxPaneIsReadByItsSessionAndNotInCopyMode() throws {
        let script = RemoteListing.script(.typed("src/"), live: .tmux(session: "nt-app;x"))
        // Next Term's own tmux server, the session by its safe name, and nothing listed from a pane in copy mode.
        #expect(script.contains("-L nextterm display-message -p -t '=nt-appx:' '#{pane_current_path}'"))
        #expect(script.contains("'#{pane_in_mode}'") && script.contains("exit 5"))
        // Without tmux on the host, the shell's folder isn't known: a relative word gets no list.
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RemoteListing.parse(try run(script, home: home.path)) == nil)
    }

    @Test func aBigFolderIsCappedAndSaysSo() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for i in 0..<30 { FileManager.default.createFile(atPath: home.appendingPathComponent("file-\(i)").path, contents: nil) }
        let capped = try #require(RemoteListing.parse(try run(RemoteListing.script(.typed("~/"), live: .none, limit: 10), home: home.path)))
        #expect(capped.listing.entries.count == 10 && !capped.listing.complete && !capped.listing.allSeen)
        // Cut by bytes: the entry cut short is left out.
        let cut = try #require(RemoteListing.parse(try run(RemoteListing.script(.typed("~/"), live: .none, bytes: 40), home: home.path)))
        #expect(cut.listing.entries.count < 5 && !cut.listing.complete)
        #expect(cut.listing.entries.allSatisfy { $0.display.hasPrefix("file-") && $0.display.count >= 6 })
        // Hidden names only when asked for.
        FileManager.default.createFile(atPath: home.appendingPathComponent(".hidden").path, contents: nil)
        let plain = try #require(RemoteListing.parse(try run(RemoteListing.script(.typed("~/"), live: .none, hidden: false), home: home.path)))
        #expect(!plain.listing.entries.contains { $0.isHidden } && plain.listing.entries.count == 30)
    }

    @Test func parsingTakesOnlyWhatTheScriptPrints() throws {
        let output = "motd noise\n\n\(RemoteShell.marker)\nshell\tsh\tbusybox\ndir\t/srv/app\nlist\td:src\u{0}f#66ff\u{0}D:priv\u{0}x:old\u{0}q:bad\u{0}f#6\u{0}d:a/b\u{0}f:trunc"
        let result = try #require(RemoteListing.parse(output))
        #expect(result.shell == "sh" && result.busybox && result.quoting == .bash && result.folder == "/srv/app")
        // An unknown type, odd hex, a slash and the last entry cut short are left out.
        #expect(result.listing.entries.map(\.name) == [Array("src".utf8), [0x66, 0xFF], Array("priv".utf8), Array("old".utf8)])
        #expect(!result.listing.complete)
        #expect(result.listing.entries[1].display == "f\u{FFFD}")
        #expect(result.closed == [Array("/srv/app/priv".utf8)])
        #expect(RemoteListing.parse("no marker\nlist\td:x\u{0}") == nil)
        #expect(RemoteListing.parse("\(RemoteShell.marker)\nshell\tbash\t\ndir\trelative\nlist\t") == nil)
    }

    @Test func eachShellGetsNamesItCanTake() {
        #expect(RemoteListing.quoting(shell: "zsh", busybox: false) == .zsh)
        #expect(RemoteListing.quoting(shell: "dash", busybox: false) == .sh)
        #expect(RemoteListing.quoting(shell: "sh", busybox: false) == .sh)
        #expect(RemoteListing.quoting(shell: "fish", busybox: false) == nil)
        let odd: [UInt8] = [0x66, 0xFF]
        #expect(RemoteListing.typable(odd, shell: .bash) == "$'f\\xFF'")
        #expect(RemoteListing.typable(odd, shell: .sh) == nil)
        #expect(RemoteListing.typable(Array("a b".utf8), shell: .sh) == "a\\ b")
        // fish and tcsh: only names that need no quoting.
        #expect(RemoteListing.typable(Array("a b".utf8), shell: nil) == nil)
        #expect(RemoteListing.typable(Array("plain-name.txt".utf8), shell: nil) == "plain-name.txt")
    }

    @Test func aServersListPutsNamesOnTheLineAsKeys() throws {
        let listing = PathCompletion.Listing(folder: "/srv", entries: [
            .init("foo", .folder), .init("food.txt", .file), .init("Sources", .folder), .init("gone", .link),
        ])
        let disk = PathCompletion.Disk(follow: { _ in .missing }, canEnter: { _ in true })
        // One folder that starts with the name typed: it goes in, by appending.
        let cd = try #require(ScreenWord.read("$ cd fo"))
        let one = CompletionList(id: 1, screen: cd, listing: listing, disk: disk, shell: .bash)
        #expect(one.screenVerdict == .insert)
        #expect(one.screenInsertion(0, at: cd).map { "\($0.erase) \($0.text)" } == "0 o/")
        // Files and folders: the list opens.
        let ls = try #require(ScreenWord.read("$ ls fo"))
        let several = CompletionList(id: 2, screen: ls, listing: listing, disk: disk, shell: .bash)
        #expect(several.screenVerdict == .open && several.rows.map(\.text) == ["foo", "food.txt"])
        // A name in another case is typed whole, after Backspaces for what was typed.
        let so = try #require(ScreenWord.read("$ cd so"))
        let other = CompletionList(id: 3, screen: so, listing: listing, disk: disk, shell: .bash)
        #expect(other.screenVerdict == .insert)
        #expect(other.screenInsertion(0, at: so).map { "\($0.erase) \($0.text)" } == "2 Sources/")
        // Quoted for the server's shell.
        let named = PathCompletion.Listing(folder: "/srv", entries: [.init("My Fo'lder", .folder)])
        let my = try #require(ScreenWord.read("$ cd M"))
        let quoted = CompletionList(id: 4, screen: my, listing: named, disk: disk, shell: .bash)
        #expect(quoted.screenInsertion(0, at: my)?.text == "y\\ Fo\\'lder/")
        // Narrowed as the word on screen grows; a link to nothing is a name after `ls`, and no folder for `cd`.
        let all = try #require(ScreenWord.read("$ ls "))
        let narrowing = CompletionList(id: 5, screen: all, listing: listing, disk: disk, shell: .bash)
        #expect(narrowing.rows.count == 4 && narrowing.rows.contains { $0.text == "gone" })
        let typed = try #require(all.next("$ ls foo"))
        #expect(narrowing.update(screen: typed) && narrowing.rows.map(\.text) == ["foo", "food.txt"])
        #expect(!narrowing.update(screen: try #require(ScreenWord.read("$ cat foo"))))
        let folders = try #require(ScreenWord.read("$ cd "))
        #expect(!CompletionList(id: 6, screen: folders, listing: listing, disk: disk, shell: .bash).rows.contains { $0.text == "gone" })
        // A name the shell can't take isn't offered: `$'…'` under dash.
        let odd = PathCompletion.Listing(folder: "/srv", entries: [.init(name: [0x66, 0xFF], kind: .file), .init("f2", .file)])
        let f = try #require(ScreenWord.read("$ ls f"))
        #expect(CompletionList(id: 7, screen: f, listing: odd, disk: disk, shell: .sh).rows.map(\.text) == ["f2"])
        #expect(CompletionList(id: 8, screen: f, listing: odd, disk: disk, shell: .bash).rows.count == 2)
        // A private key is never what a server's row sends.
        #expect(several.take(0) == nil)
    }
}
