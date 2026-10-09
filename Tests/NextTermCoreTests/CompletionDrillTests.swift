import Foundation
import Testing
@testable import NextTermCore

/// Walking down a path with Tab: which rows Tab goes into, what a drill types and what ⌫ undoes, the single-match
/// rule and the empty-folder rule, on each of the list's paths.
@Suite struct CompletionDrillTests {
    struct Decoded: Equatable {
        var kind: String
        var id: Int
        var fields: [String]
    }

    /// Reads a private key back as the shell's `printf %b` would.
    func decode(_ bytes: [UInt8]?) -> Decoded? {
        guard let bytes else { return nil }
        let prefix = Array(CompletionProtocol.prefix.utf8)
        guard bytes.starts(with: prefix) else { return nil }
        let rest = Array(bytes.dropFirst(prefix.count))
        let kind = String(UnicodeScalar(rest[0]))
        let id = Int(String(decoding: rest[1..<7], as: UTF8.self)) ?? -1
        let payload = String(decoding: rest[13...], as: UTF8.self)
        let fields = payload.isEmpty ? [] : payload.split(separator: ";", omittingEmptySubsequences: false).map { field -> String in
            var out: [UInt8] = []
            var chars = Array(field.utf8)[...]
            while let byte = chars.first {
                if byte == UInt8(ascii: "\\"), chars.count >= 4, let value = UInt8(String(decoding: chars.dropFirst(2).prefix(2), as: UTF8.self), radix: 16) {
                    out.append(value)
                    chars = chars.dropFirst(4)
                } else {
                    out.append(byte)
                    chars = chars.dropFirst()
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
        return Decoded(kind: kind, id: id, fields: fields)
    }

    func context(_ words: [String], head: String = "", resolved: String = "") -> CompletionContext? {
        let word = words.last ?? ""
        let report = CompletionProtocol.TabReport(id: 4, directory: "/work", lbuffer: words.joined(separator: " "), words: words, word: word,
                                                  unquoted: word, head: head, resolvedHead: resolved)
        return CompletionContext.analyze(report)
    }

    func engine(_ words: [String], entries: [PathCompletion.Entry], closed: Set<String> = []) -> CompletionList? {
        guard let context = context(words) else { return nil }
        let listing = PathCompletion.Listing(folder: context.folder, entries: entries)
        let prepared = PathCompletion.Prepared(listing, foldersOnly: context.kind == .folders, hidden: context.showsHidden)
        let result = prepared.candidates(context.typed, follow: { _ in .file },
                                         canEnter: { !closed.contains(String(decoding: $0, as: UTF8.self)) })
        return CompletionList(id: 4, context: context, listing: listing, prepared: prepared, result: result)
    }

    /// The list for a folder gone into, as CompletionSession makes it from the folder's listing.
    func inside(_ context: CompletionContext, _ entries: [PathCompletion.Entry]) -> CompletionList {
        let listing = PathCompletion.Listing(folder: context.folder, entries: entries)
        let prepared = PathCompletion.Prepared(listing, foldersOnly: context.kind == .folders, hidden: context.showsHidden)
        let result = prepared.candidates(context.typed, follow: { _ in .file }, canEnter: { _ in true })
        return CompletionList(id: 4, context: context, listing: listing, prepared: prepared, result: result)
    }

    let entries: [PathCompletion.Entry] = [.init("Sources", .folder), .init("Resources", .folder), .init("Sourcery.txt", .file),
                                          .init("locked", .folder), .init("My Fo'lder $x", .folder), .init("a\u{1}b", .folder)]

    // MARK: which rows Tab goes into

    @Test func tabGoesIntoFoldersOnly() throws {
        let list = try #require(engine(["ls", ""], entries: entries, closed: ["/work/locked"]))
        func target(_ text: String) -> CompletionDrill.Target? {
            list.rows.firstIndex { $0.text == text }.map(list.tabTarget)
        }
        #expect(target("Sources") == .folder && target("My Fo'lder $x") == .folder)
        #expect(target("Sourcery.txt") == .file)
        // A folder that can't be entered: a beep, and the list stays.
        #expect(target("locked") == .closed)
        // A name that goes in as $'…' has no word to go on from: it goes on the line as Return puts it.
        #expect(target("a\\x01b") == .file)
        #expect(list.tabTarget(99) == .file)
    }

    // MARK: Next Term's own engine

    @Test func goingIntoAFolderOnNextTermsEngine() throws {
        let list = try #require(engine(["cd", "So"], entries: entries))
        #expect(list.rows.map(\.text) == ["Sources", "Resources"])
        let into = try #require(list.drillContext(0))
        #expect(into.folder == "/work/Sources" && into.keep == "Sources/" && into.typed == "" && into.word == "Sources/" && into.kind == .folders)
        // The drill types the name and its `/`, and keeps the list open.
        #expect(decode(list.drillTake(0)) == Decoded(kind: "k", id: 4, fields: ["w", "So", "Sources/", "o"]))
        let child = inside(into, [.init("inner", .folder), .init("main.swift", .file), .init(".hidden", .folder)])
        child.drilled(from: list, row: 0)
        // Folders only after cd, no hidden ones, the first row chosen.
        #expect(child.rows.map(\.text) == ["inner"] && child.parent === list && child.word == "Sources/" && child.preferredRow == nil)
        #expect(child.drilledName == "Sources")
        // The hook reports the word now: it narrows inside the folder.
        #expect(child.update(word: "Sources/", unquoted: "Sources/") && child.rows.map(\.text) == ["inner"])
        #expect(child.update(word: "Sources/i", unquoted: "Sources/i") && child.backUp(word: "Sources/") == nil)
        #expect(child.update(word: "Sources/", unquoted: "Sources/"))
        // ⌫ that takes the `/`: the parent's list as it was, with that folder chosen, for the word now.
        let back = try #require(child.backUp(word: "Sources"))
        #expect(back === list && back.word == "Sources" && back.rows.map(\.text) == ["Sources", "Resources"] && back.preferredRow == 0)
        #expect(back.update(word: "Sources", unquoted: "Sources") && back.rows.map(\.text) == ["Sources", "Resources"] && back.preferredRow == 0)
        // A row taken from there replaces the word now.
        #expect(decode(back.take(1)) == Decoded(kind: "k", id: 4, fields: ["w", "Sources", "Resources/"]))
        // Typing narrows it again, from the word now.
        #expect(back.update(word: "Sourcesx", unquoted: "Sourcesx") && back.preferredRow == nil)
        #expect(back.rows.isEmpty)
    }

    @Test func aDrillQuotesTheNameAsReturnDoes() throws {
        let list = try #require(engine(["cd", "My"], entries: entries))
        let into = try #require(list.drillContext(0))
        #expect(into.word == #"My\ Fo\'lder\ \$x/"# && into.folder == "/work/My Fo'lder $x" && into.quote == .unquoted)
        #expect(decode(list.drillTake(0))?.fields == ["w", "My", #"My\ Fo\'lder\ \$x/"#, "o"])
        // Inside an open quote the quote stays open, to go on into the folder.
        let quoted = try #require(engine(["cd", "\"My"], entries: entries))
        let inQuote = try #require(quoted.drillContext(0))
        #expect(inQuote.word == #""My Fo'lder \$x/"# && inQuote.quote == .double && inQuote.keep == inQuote.word)
        #expect(inQuote.with(word: inQuote.word + "in")?.typed == "in")
    }

    @Test func aDrillKeepsAnOptionAndAHead() throws {
        let option = try #require(context(["ls", "--file=./So"]))
        let into = try #require(option.drilled(into: Array("Sources".utf8)))
        #expect(into.word == "--file=./Sources/" && into.keep == "--file=./Sources/" && into.folder == "/work/Sources")
        #expect(into.with(word: "--file=./Sources/ma")?.typed == "ma")
        let home = try #require(context(["cd", "~/Do"], head: "~/", resolved: "/Users/me/"))
        let documents = try #require(home.drilled(into: Array("Documents".utf8)))
        #expect(documents.word == "~/Documents/" && documents.folder == "/Users/me/Documents" && documents.keep == "~/Documents/")
        // A name that isn't UTF-8 names no folder to list.
        #expect(home.drilled(into: [0x66, 0xFF]) == nil)
    }

    @Test func twoLevelsDownAndBackUp() throws {
        let root = try #require(engine(["cd", ""], entries: [.init("projects", .folder), .init("Pictures", .folder)]))
        let p = try #require(root.rows.firstIndex { $0.text == "projects" })
        let projects = inside(try #require(root.drillContext(p)), [.init("next-term", .folder), .init("cv", .folder)])
        projects.drilled(from: root, row: p)
        let n = try #require(projects.rows.firstIndex { $0.text == "next-term" })
        let next = inside(try #require(projects.drillContext(n)), [.init("Sources", .folder)])
        next.drilled(from: projects, row: n)
        #expect(next.word == "projects/next-term/")
        let up = try #require(next.backUp(word: "projects/next-term"))
        #expect(up === projects && up.preferredRow == n)
        // Erased back to its own `/`, then ⌫ once more: the first list.
        #expect(up.update(word: "projects/", unquoted: "projects/") && up.rows.count == 2)
        let top = try #require(up.backUp(word: "projects"))
        #expect(top === root && top.preferredRow == p)
        #expect(root.backUp(word: "") == nil)
    }

    // MARK: zsh's own completions

    @Test func goingIntoAFolderOnZshsPath() throws {
        let matches = [CompletionProtocol.Match(text: "Sources/", kind: .folder, index: 1), CompletionProtocol.Match(text: "Resources/", kind: .folder, index: 2),
                       CompletionProtocol.Match(text: "notes.txt", kind: .file, index: 3), CompletionProtocol.Match(text: "main", index: 4)]
        let list = CompletionList(id: 7, matches: matches, total: 4, stem: "", stemUnquoted: "")
        #expect(list.update(word: "", unquoted: "") && list.rows.count == 4)
        let s = try #require(list.rows.firstIndex { $0.text == "Sources/" })
        let notes = try #require(list.rows.firstIndex { $0.text == "notes.txt" })
        let main = try #require(list.rows.firstIndex { $0.text == "main" })
        // A match zsh calls a folder; whether it can be entered, the hook checks.
        #expect(list.tabTarget(s) == .folder && list.tabTarget(notes) == .file && list.tabTarget(main) == .file)
        #expect(list.drillContext(s) == nil)
        // zsh puts the folder in by its place in the list, then lists what is inside under the new id.
        #expect(decode(list.drillTake(s, to: 8)) == Decoded(kind: "k", id: 7, fields: ["m", "", "1", "000008"]))
        #expect(list.drillTake(s) == nil)
        let child = CompletionList(id: 8, matches: [CompletionProtocol.Match(text: "inner/", kind: .folder, index: 1),
                                                    CompletionProtocol.Match(text: "main.swift", kind: .file, index: 2)],
                                   total: 2, stem: "Sources/", stemUnquoted: "Sources/")
        child.drilled(from: list, row: s)
        #expect(child.update(word: "Sources/", unquoted: "Sources/") && child.rows.count == 2 && child.drilledName == "Sources/")
        let back = try #require(child.backUp(word: "Sources"))
        #expect(back === list && back.preferredRow == s && back.rows.count == 4 && back.word == "Sources")
        #expect(back.update(word: "Sources", unquoted: "Sources") && back.rows.count == 4)
        let r = try #require(back.rows.firstIndex { $0.text == "Resources/" })
        #expect(decode(back.take(r))?.fields == ["m", "Sources", "2"])
        // The hook's lists are its own: going back up tells it which one is open again.
        #expect(decode(CompletionProtocol.backUp(id: 8, to: 7)) == Decoded(kind: "k", id: 8, fields: ["u", "000007"]))
    }

    // MARK: a server's screen

    @Test func goingIntoAFolderOnAServersScreen() throws {
        let listing = PathCompletion.Listing(folder: "/srv", entries: [
            .init("foo", .folder), .init("food.txt", .file), .init("Sources", .folder), .init("My Fo'lder", .folder), .init("locked", .folder),
        ])
        let disk = PathCompletion.Disk(follow: { _ in .missing }, canEnter: { $0 != Array("/srv/locked".utf8) })
        let ls = try #require(ScreenWord.read("$ ls "))
        let list = CompletionList(id: 1, screen: ls, listing: listing, disk: disk, shell: .bash)
        func row(_ text: String) -> Int { list.rows.firstIndex { $0.text == text } ?? -1 }
        let foo = row("foo")
        #expect(list.tabTarget(foo) == .folder && list.tabTarget(row("food.txt")) == .file)
        #expect(list.tabTarget(row("locked")) == .closed)
        // A name the screen can't read back as typed (it needs quoting): it goes on the line as Return puts it.
        #expect(list.tabTarget(row("My Fo'lder")) == .file)
        let into = try #require(list.drillScreen(foo))
        #expect(into.word == "foo/" && into.folder == "foo/" && into.typed == "" && into.before == "$ ls " && into.kind == .paths)
        // What it types is what Return types.
        #expect(list.screenInsertion(foo, at: ls).map { "\($0.erase) \($0.text)" } == "0 foo/")
        let inner = PathCompletion.Listing(folder: "/srv/foo", entries: [.init("bar", .folder), .init("x.txt", .file)])
        let child = CompletionList(id: 1, screen: into, listing: inner, disk: disk, shell: .bash)
        child.drilled(from: list, row: foo)
        #expect(child.rows.map(\.text) == ["bar", "x.txt"] && child.parent === list)
        let narrowed = try #require(into.next("$ ls foo/b"))
        #expect(child.update(screen: narrowed) && child.rows.map(\.text) == ["bar"])
        let slash = try #require(ScreenWord.read("$ ls foo/"))
        #expect(child.backUp(screen: slash) == nil)
        let erased = try #require(ScreenWord.read("$ ls foo"))
        let back = try #require(child.backUp(screen: erased))
        #expect(back === list && back.preferredRow == foo && back.rows.count == 5 && back.screenWord?.word == "foo")
        #expect(back.update(screen: erased) && back.rows.count == 5)
        // Another row replaces the name on screen from there.
        let now = try #require(back.screenWord)
        #expect(back.screenInsertion(row("Sources"), at: now).map { "\($0.erase) \($0.text)" } == "3 Sources/")
        // Another line before the word: not the same list.
        let other = try #require(ScreenWord.read("$ cat foo"))
        #expect(child.backUp(screen: other) == nil)
    }

    // MARK: the rules

    @Test func whatTabOnAFolderDoesOnceItIsListed() {
        let read = PathCompletion.Listing(folder: "/a", entries: [.init("b", .folder)])
        #expect(CompletionDrill.step(read, shown: 1) == .into)
        // Nothing the list would show inside (an empty folder, files after cd): the name goes in, the list closes.
        #expect(CompletionDrill.step(read, shown: 0) == .wentIn)
        // No permission, or gone: a beep, and the list stays.
        let unreadable = PathCompletion.list("/no/such/folder/\(UUID().uuidString)")
        #expect(CompletionDrill.step(unreadable, shown: 0) == .refused)
        // Too slow: the name goes in and the list closes, never a stall.
        let slow = PathCompletion.list("/x", seconds: 0.02, read: { _, found in
            for i in 0..<10_000 {
                usleep(100)
                if !found(.init("f\(i)", .file)) { break }
            }
            return true
        })
        #expect(!slow.readable && slow.late && !unreadable.late)
        #expect(CompletionDrill.step(slow, shown: 0) == .wentIn)
    }

    @Test func theSingleMatchRule() throws {
        func result(_ words: [String], _ entries: [PathCompletion.Entry], enterable: Bool = true, exact: Bool = true) throws -> PathCompletion.Result {
            let completion = try #require(context(words))
            let listing = PathCompletion.Listing(folder: "/work", entries: entries)
            var result = PathCompletion.Prepared(listing, foldersOnly: completion.kind == .folders, hidden: false)
                .candidates(completion.typed, follow: { _ in .file }, canEnter: { _ in enterable })
            result.exact = exact
            return result
        }
        // One folder that can be entered: it goes in, and what is inside is listed.
        let tests = try result(["cd", "Te"], [.init("Tests", .folder), .init("Sources", .folder)])
        #expect(CompletionDrill.single(tests)?.display == "Tests")
        // A file goes in as before; so does a folder that can't be entered, and nothing goes in from a folder not read whole.
        let file = try result(["cat", "no"], [.init("notes.txt", .file)])
        let closed = try result(["cd", "Te"], [.init("Tests", .folder)], enterable: false)
        let partial = try result(["cd", "Te"], [.init("Tests", .folder)], exact: false)
        let two = try result(["cd", "So"], [.init("Sources", .folder), .init("Resources", .folder)])
        #expect(CompletionDrill.single(file) == nil && CompletionDrill.single(closed) == nil)
        #expect(CompletionDrill.single(partial) == nil && CompletionDrill.single(two) == nil)
    }

    @Test func backUpIsTheSlashTaken() {
        #expect(CompletionDrill.goesBackUp("Sources", from: "Sources/"))
        #expect(CompletionDrill.goesBackUp(#""My Dir"#, from: #""My Dir/"#))
        #expect(!CompletionDrill.goesBackUp("Sources/", from: "Sources/"))
        #expect(!CompletionDrill.goesBackUp("Source", from: "Sources/"))
        #expect(!CompletionDrill.goesBackUp("", from: ""))
    }

    @Test func voiceOverSaysTheFolderGoneInto() {
        #expect(CompletionDrill.announcement(into: "projects", total: 12, exact: true) == "In projects, 12 items")
        #expect(CompletionDrill.announcement(into: "cv", total: 1, exact: true) == "In cv, 1 item")
        #expect(CompletionDrill.announcement(into: "many", total: 2000, exact: false).hasSuffix("items shown"))
        #expect(CompletionDrill.backUpAnnouncement("projects", row: 2, of: 5) == "Back up, projects, 3 of 5")
    }

    // MARK: the arrow keys

    @Test func whatEachKeyDoes() {
        // ⇥ and → on a row: into a folder, a beep on one that can't be entered, anything else on the line as ↩︎ puts it.
        for key in [CompletionDrill.Key.tab, .right] {
            #expect(CompletionDrill.action(key, on: .folder, inside: false) == .goIn)
            #expect(CompletionDrill.action(key, on: .folder, inside: true) == .goIn)
            #expect(CompletionDrill.action(key, on: .file, inside: false) == .putOnLine)
            #expect(CompletionDrill.action(key, on: .closed, inside: true) == .beep)
            // A server's hook from before going into folders: the name goes on the line, as ↩︎ puts it.
            #expect(CompletionDrill.action(key, on: .folder, inside: false, drills: false) == .putOnLine)
            #expect(CompletionDrill.action(key, on: .closed, inside: false, drills: false) == .putOnLine)
            // While a folder is listed, the key waits for its list.
            #expect(CompletionDrill.action(key, on: .file, inside: false, drilling: true) == .wait)
        }
        // No rows yet (Loading, or before the first report): ⇥ waits for them; → closes the list and moves the cursor.
        #expect(CompletionDrill.action(.tab, on: nil, inside: false) == .wait)
        #expect(CompletionDrill.action(.right, on: nil, inside: false) == .closeAndPass)
        // ← in a folder a drill opened: back up, whatever row is chosen; at the top: the list closes, the cursor moves.
        #expect(CompletionDrill.action(.left, on: .file, inside: true) == .backUp)
        #expect(CompletionDrill.action(.left, on: nil, inside: true) == .backUp)
        #expect(CompletionDrill.action(.left, on: .folder, inside: false) == .closeAndPass)
        #expect(CompletionDrill.action(.left, on: nil, inside: false) == .closeAndPass)
        #expect(CompletionDrill.action(.left, on: .folder, inside: true, drilling: true) == .wait)
    }

    @Test func leftGoesBackUpOnNextTermsEngine() throws {
        let list = try #require(engine(["cd", "So"], entries: entries))
        // At the top: nothing to go back to.
        #expect(list.upTake() == nil && list.goUp() == nil && list.parentWord == nil)
        let child = inside(try #require(list.drillContext(0)), [.init("inner", .folder), .init("deep", .folder)])
        child.drilled(from: list, row: 0)
        #expect(child.parentWord == "So")
        // Narrowed inside, then ←: the word the folder was gone into from, in place of the word now, the list kept open.
        #expect(child.update(word: "Sources/i", unquoted: "Sources/i") && child.rows.map(\.text) == ["inner"])
        #expect(decode(child.upTake()) == Decoded(kind: "k", id: 4, fields: ["w", "Sources/i", "So", "o"]))
        let up = try #require(child.goUp())
        #expect(up === list && up.word == "So" && up.rows.map(\.text) == ["Sources", "Resources"] && up.preferredRow == 0)
        // The shell reports that word: the rows stay, the folder chosen.
        #expect(up.update(word: "So", unquoted: "So") && up.rows.map(\.text) == ["Sources", "Resources"] && up.preferredRow == 0)
        // From the list Tab opened, ← has nowhere to go.
        #expect(up.upTake() == nil && up.goUp() == nil)
    }

    @Test func leftTwoLevelsUp() throws {
        let root = try #require(engine(["cd", "pr"], entries: [.init("projects", .folder), .init("Pictures", .folder), .init("prose", .folder)]))
        let p = try #require(root.rows.firstIndex { $0.text == "projects" })
        let projects = inside(try #require(root.drillContext(p)), [.init("next-term", .folder), .init("cv", .folder)])
        projects.drilled(from: root, row: p)
        #expect(projects.update(word: "projects/ne", unquoted: "projects/ne"))
        let n = try #require(projects.rows.firstIndex { $0.text == "next-term" })
        let next = inside(try #require(projects.drillContext(n)), [.init("Sources", .folder)])
        next.drilled(from: projects, row: n)
        #expect(decode(next.upTake())?.fields == ["w", "projects/next-term/", "projects/ne", "o"])
        let up = try #require(next.goUp())
        #expect(up === projects && up.word == "projects/ne" && up.preferredRow == n && up.rows.map(\.text) == ["next-term"])
        #expect(decode(up.upTake())?.fields == ["w", "projects/ne", "pr", "o"])
        let top = try #require(up.goUp())
        #expect(top === root && top.word == "pr" && top.preferredRow == p && top.goUp() == nil)
    }

    @Test func leftGoesBackUpOnZshsPath() throws {
        let matches = [CompletionProtocol.Match(text: "Sources/", kind: .folder, index: 1), CompletionProtocol.Match(text: "Resources/", kind: .folder, index: 2)]
        let list = CompletionList(id: 7, matches: matches, total: 2, stem: "", stemUnquoted: "")
        #expect(list.update(word: "", unquoted: "") && list.upTake() == nil)
        let child = CompletionList(id: 8, matches: [CompletionProtocol.Match(text: "inner/", kind: .folder, index: 1)], total: 1,
                                   stem: "Sources/", stemUnquoted: "Sources/")
        child.drilled(from: list, row: 0)
        #expect(child.update(word: "Sources/", unquoted: "Sources/"))
        // The hook's u key with the words: the one now, and the one to put back (here none, after `cd `).
        #expect(decode(child.upTake()) == Decoded(kind: "k", id: 8, fields: ["u", "000007", "Sources/", ""]))
        let up = try #require(child.goUp())
        #expect(up === list && up.word == "" && up.preferredRow == 0 && up.rows.count == 2)
        #expect(up.update(word: "", unquoted: "") && up.rows.count == 2 && up.preferredRow == 0)
        // ⌫'s u key has no words: the line is already the one zsh lists for.
        #expect(decode(CompletionProtocol.backUp(id: 8, to: 7))?.fields == ["u", "000007"])
    }

    @Test func leftGoesBackUpOnAServersScreen() throws {
        let listing = PathCompletion.Listing(folder: "/srv", entries: [.init("foo", .folder), .init("food.txt", .file), .init("fog", .folder)])
        let disk = PathCompletion.Disk(follow: { _ in .missing }, canEnter: { _ in true })
        let fo = try #require(ScreenWord.read("$ ls fo"))
        let list = CompletionList(id: 1, screen: fo, listing: listing, disk: disk, shell: .bash)
        let foo = try #require(list.rows.firstIndex { $0.text == "foo" })
        #expect(list.upKeys(at: fo) == nil)
        let into = try #require(list.drillScreen(foo))
        let child = CompletionList(id: 1, screen: into, listing: PathCompletion.Listing(folder: "/srv/foo", entries: [.init("bar", .folder), .init("baz", .file)]),
                                   disk: disk, shell: .bash)
        child.drilled(from: list, row: foo)
        #expect(child.parentWord == "fo")
        // Typed inside, then ←: Backspaces back to the word gone in from, as typed.
        let narrowed = try #require(ScreenWord.read("$ ls foo/b"))
        #expect(child.update(screen: narrowed))
        #expect(child.upKeys(at: narrowed).map { "\($0.erase) \($0.text)" } == "3 ")
        #expect(child.upKeys(at: into).map { "\($0.erase) \($0.text)" } == "2 ")
        // Another line before the word: no keys.
        #expect(child.upKeys(at: try #require(ScreenWord.read("$ cat foo/"))) == nil)
        #expect(child.upTake() == nil)
        let up = try #require(child.goUp())
        #expect(up === list && up.screenWord == fo && up.preferredRow == foo && up.rows.count == 3)
        // Once the screen shows it, the rows stay, the folder chosen.
        #expect(up.update(screen: fo) && up.rows.count == 3 && up.preferredRow == foo)
    }

    @Test func retypingAWordOnScreen() {
        func keys(_ from: String, _ to: String) -> String? { CompletionDrill.retype(from, to: to).map { "\($0.erase) \($0.text)" } }
        #expect(keys("foo/", "fo") == "2 ")
        #expect(keys("foo/bar/", "") == "8 ")
        #expect(keys("foo/", "fax") == "3 ax")
        #expect(keys("fo", "fo") == "0 ")
        // What goes must be plain ASCII: a Backspace is a byte or a character, by the server's locale.
        #expect(keys("café/", "ca") == nil)
        #expect(keys("café/x", "café/") == "1 ")
        #expect(keys("ab", "acé") == "1 cé")
    }

    // MARK: the state and the keys

    @Test func drillingOnNextTermsEngine() {
        var s = CompletionState()
        s.armed(CompletionProtocol.Arm())
        #expect(s.startDrill() == nil) // no list open
        let id = s.startTab()!
        #expect(s.startDrill() == nil) // a Tab in flight
        s.answered(id, .open)
        s.line(.init(id: id, left: false, word: "So", unquoted: "So"))
        // The list stays open, under its own id, and writes wait.
        #expect(s.startDrill() == id && s.isDrilling && s.drillID == id && s.holding && s.openID == id && s.pendingID == nil)
        #expect(s.path == .engine && s.shown)
        #expect(s.startDrill() == nil) // one at a time
        s.drilled(.into)
        #expect(s.phase == .open(id: id, path: .engine) && !s.holding && s.shown)
        _ = s.startDrill()
        s.drilled(.refused)
        #expect(s.phase == .open(id: id, path: .engine) && !s.holding)
        _ = s.startDrill()
        s.drilled(.wentIn)
        #expect(s.isArmed && !s.shown && !s.holding)
        // Esc while it lists: closed.
        let again = s.startTab()!
        s.answered(again, .open)
        _ = s.startDrill()
        s.closed()
        #expect(s.isArmed && !s.isDrilling)
    }

    @Test func drillingOnZshsPath() {
        var s = CompletionState()
        s.armed(CompletionProtocol.Arm(completionSystem: true))
        let id = s.startTab()!
        s.listed(id)
        let to = s.startDrill()!
        #expect(to != id && s.drillID == to && s.openID == id && s.holding && s.path == .completionSystem)
        // The hold ends at 120 ms; the drill stays in flight until zsh answers.
        #expect(!s.holdExpired(to) && !s.holding && s.isDrilling)
        s.listed(to)
        #expect(s.phase == .open(id: to, path: .completionSystem) && s.shown && !s.holding)
        // It can't be entered: the list as it was.
        let refused = s.startDrill()!
        s.done(refused, .kept)
        #expect(s.phase == .open(id: to, path: .completionSystem) && !s.holding)
        // Empty inside: the name went in, the list closes.
        let empty = s.startDrill()!
        s.done(empty, .inserted)
        #expect(s.isArmed)
        // The hook couldn't take it (the word changed): its `line` says the list is gone.
        let other = s.startTab()!
        s.listed(other)
        _ = s.startDrill()
        s.line(.init(id: other, left: true))
        #expect(s.isArmed)
        // Going back up: the list open again is the one gone into from.
        let last = s.startTab()!
        s.listed(last)
        s.reopened(3)
        #expect(s.phase == .open(id: 3, path: .completionSystem))
    }

    @Test func theDrillsKeys() {
        #expect(decode(CompletionProtocol.takeWord(id: 3, old: "So", new: "Sources/", open: true))?.fields == ["w", "So", "Sources/", "o"])
        #expect(decode(CompletionProtocol.takeWord(id: 3, old: "So", new: "Sources/"))?.fields == ["w", "So", "Sources/"])
        #expect(decode(CompletionProtocol.takeMatch(id: 7, old: "", index: 1, drill: 8))?.fields == ["m", "", "1", "000008"])
        #expect(decode(CompletionProtocol.insertAnswer(id: 2, word: "Tests/", open: true)) == Decoded(kind: "a", id: 2, fields: ["i", "Tests/", "o"]))
        #expect(decode(CompletionProtocol.tabKey(id: 1, drill: true))?.fields == ["d"])
        #expect(decode(CompletionProtocol.tabKey(id: 1, wait: 0.3, quiet: true, drill: true))?.fields == ["w300", "q1", "d"])
        #expect(CompletionProtocol.parse(kind: "done", value: "000008;kept") == .done(id: 8, outcome: .kept))
        // Only a hook that knows them is sent them.
        #expect(CompletionProtocol.Arm().drills && !CompletionProtocol.Arm(version: 1).drills)
    }
}
