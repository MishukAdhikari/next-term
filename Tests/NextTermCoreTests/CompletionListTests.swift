import Foundation
import Testing
@testable import NextTermCore

@Suite struct CompletionListTests {
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

    func engine(_ words: [String], entries: [PathCompletion.Entry]) -> CompletionList? {
        let word = words.last ?? ""
        let report = CompletionProtocol.TabReport(id: 4, directory: "/work", lbuffer: words.joined(separator: " "), words: words,
                                                  word: word, unquoted: word)
        guard let context = CompletionContext.analyze(report) else { return nil }
        let listing = PathCompletion.Listing(folder: context.folder, entries: entries)
        let prepared = PathCompletion.Prepared(listing, foldersOnly: context.kind == .folders, hidden: context.showsHidden)
        let result = prepared.candidates(context.typed, follow: { _ in .file }, canEnter: { _ in true })
        return CompletionList(id: 4, context: context, listing: listing, prepared: prepared, result: result)
    }

    let entries: [PathCompletion.Entry] = [.init("Sources", .folder), .init("Resources", .folder), .init("Sourcery.txt", .file),
                                          .init(".git", .folder), .init("My Fo'lder $x", .folder)]

    @Test func engineRowsNarrowAsTheWordChanges() throws {
        let list = try #require(engine(["cd", "So"], entries: entries))
        #expect(list.rows.map(\.text) == ["Sources", "Resources"] && list.word == "So" && !list.isZsh)
        #expect(list.update(word: "Sou", unquoted: "Sou") && list.rows.map(\.text) == ["Sources", "Resources"])
        #expect(list.update(word: "Sour", unquoted: "Sour") && list.rows.map(\.text) == ["Sources", "Resources"])
        #expect(list.update(word: "Sourc", unquoted: "Sourc") && list.rows.first?.text == "Sources")
        // Backspace widens again; a dot shows hidden folders.
        #expect(list.update(word: "", unquoted: "") && list.rows.count == 3)
        #expect(list.update(word: ".", unquoted: ".") && list.rows.map(\.text) == [".git"])
        // Another folder: the list closes.
        #expect(!list.update(word: "Sources/", unquoted: "Sources/"))
    }

    @Test func engineTakeQuotesTheName() throws {
        let list = try #require(engine(["cd", "My"], entries: entries))
        #expect(list.rows.first?.text == "My Fo'lder $x")
        #expect(decode(list.take(0)) == Decoded(kind: "k", id: 4, fields: ["w", "My", #"My\ Fo\'lder\ \$x/"#]))
        _ = list.update(word: "My\\ F", unquoted: "My F")
        #expect(decode(list.take(0))?.fields == ["w", "My\\ F", #"My\ Fo\'lder\ \$x/"#])
        #expect(list.take(5) == nil)
    }

    @Test func verdicts() throws {
        func verdict(_ words: [String]) throws -> CompletionVerdict {
            let word = words.last ?? ""
            let report = CompletionProtocol.TabReport(id: 1, directory: "/work", lbuffer: "", words: words, word: word, unquoted: word)
            let context = try #require(CompletionContext.analyze(report))
            let listing = PathCompletion.Listing(folder: "/work", entries: [.init("Sources", .folder), .init("Resources", .folder),
                                                                             .init("Tests", .folder), .init("notes.txt", .file)])
            let prepared = PathCompletion.Prepared(listing, foldersOnly: context.kind == .folders, hidden: false)
            return CompletionVerdict.of(prepared.candidates(context.typed, canEnter: { _ in true }), context: context)
        }
        #expect(try verdict(["cd", "Te"]) == .insert("Tests/"))    // AE2
        #expect(try verdict(["cat", "no"]) == .insert("notes.txt "))
        #expect(try verdict(["cd", "So"]) == .open)
        #expect(try verdict(["cd", "zz"]) == .native)
        #expect(try verdict(["cd", "Rsrc"]) == .open)             // one fuzzy match: shown, not put in
    }

    @Test func zshRowsAllForTheListedWordThenNarrowed() throws {
        let matches = ["main", "feature/x", "HEAD", "6304be0"].enumerated().map { index, text in
            CompletionProtocol.Match(text: text, description: text == "6304be0" ? "[HEAD] first" : "", kind: .other, index: index + 1)
        }
        let list = CompletionList(id: 9, matches: matches, total: 4, stem: "", stemUnquoted: "")
        #expect(list.isZsh && list.rows.isEmpty)
        // The first `line`: every match zsh gave, alphabetical.
        #expect(list.update(word: "", unquoted: ""))
        #expect(list.rows.map(\.text) == ["6304be0", "feature/x", "HEAD", "main"] && list.total == 4)
        #expect(list.rows.first?.description == "[HEAD] first")
        #expect(list.update(word: "ma", unquoted: "ma") && list.rows.map(\.text) == ["main"])
        #expect(decode(list.take(0)) == Decoded(kind: "k", id: 9, fields: ["m", "ma", "1"]))
    }

    @Test func zshMatchesThatDontStartWithTheWordStillShowForIt() {
        // An approximate completer's answers: shown for the word zsh listed them for.
        let matches = [CompletionProtocol.Match(text: "feature/x", index: 1), CompletionProtocol.Match(text: "fixup", index: 2)]
        let list = CompletionList(id: 2, matches: matches, total: 2, stem: "", stemUnquoted: "")
        #expect(list.update(word: "ftrx", unquoted: "ftrx") && list.rows.count == 2)
    }

    @Test func zshStem() {
        let matches = [CompletionProtocol.Match(text: "inner", kind: .folder, index: 1), CompletionProtocol.Match(text: "insect", kind: .folder, index: 2)]
        let list = CompletionList(id: 3, matches: matches, total: 2, stem: "My\\ Src/", stemUnquoted: "My Src/")
        #expect(list.update(word: "My\\ Src/in", unquoted: "My Src/in") && list.rows.count == 2 && list.rows.allSatisfy(\.isFolder))
        #expect(list.update(word: "My\\ Src/ins", unquoted: "My Src/ins") && list.rows.map(\.text) == ["insect"])
        #expect(!list.update(word: "Other/", unquoted: "Other/"))
    }

    @Test func zshListCutAt2000() {
        let matches = (1...2000).map { CompletionProtocol.Match(text: "f\($0)", index: $0) }
        let list = CompletionList(id: 3, matches: matches, total: 3000, stem: "", stemUnquoted: "")
        _ = list.update(word: "", unquoted: "")
        #expect(list.total == 3000 && list.rows.count == 2000 && !list.exact)
    }

    @Test func namesShowTheirHiddenCharacters() throws {
        let list = try #require(engine(["ls", "a"], entries: [.init("a\u{202E}b", .file), .init("a\nc", .file)]))
        #expect(Set(list.rows.map(\.text)) == ["a\\u{202E}b", "a\\x0Ac"] && list.rows.allSatisfy { $0.highlights.isEmpty })
        // The name goes in as $'…', never raw.
        let take = try #require(list.take(0))
        #expect(!take.contains(0x0A) && decode(take)?.fields.last?.hasPrefix("$'a") == true)
    }
}
