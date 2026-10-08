import Foundation
import Testing
@testable import NextTermCore

@Suite struct WordQuoteTests {
    @Test func unquoted() {
        #expect(WordQuote.quote("Sources", in: .unquoted) == "Sources")
        #expect(WordQuote.quote("My Fo'lder $x", in: .unquoted) == #"My\ Fo\'lder\ \$x"#)
        #expect(WordQuote.quote("~x", in: .unquoted) == #"\~x"#)
        #expect(WordQuote.quote("=x", in: .unquoted) == #"\=x"#)
        #expect(WordQuote.quote("a=b~c", in: .unquoted) == #"a=b\~c"#)    // `~` is a glob operator under extendedglob
        #expect(WordQuote.quote("x;touch PWNED;", in: .unquoted) == #"x\;touch\ PWNED\;"#)
        #expect(WordQuote.quote("café 🙂", in: .unquoted) == #"café\ 🙂"#)
        #expect(WordQuote.quote("line\nbreak", in: .unquoted) == #"$'line\x0Abreak'"#)
        #expect(WordQuote.quote("tab\tx", in: .unquoted) == #"$'tab\x09x'"#)
        #expect(WordQuote.quote("rtl\u{202E}txt", in: .unquoted) == #"$'rtl\xE2\x80\xAEtxt'"#)
        #expect(WordQuote.quote([0x61, 0xFF, 0x62], in: .unquoted) == #"$'a\xFFb'"#)
    }

    @Test func insideQuotes() {
        #expect(WordQuote.quote("My Fo'lder $x", in: .double) == #"My Fo'lder \$x"#)
        #expect(WordQuote.quote("a\"b`c\\d", in: .double) == #"a\"b\`c\\d"#)
        #expect(WordQuote.quote("hi!", in: .double, shell: .zsh) == #"hi"\!""#)
        #expect(WordQuote.quote("hi!", in: .double, shell: .bash) == #"hi"\!""#)
        #expect(WordQuote.quote("it's", in: .single) == #"it'\''s"#)
        #expect(WordQuote.quote("a\nb", in: .double) == #""$'a\x0Ab'""#)
        #expect(WordQuote.quote("a\nb", in: .single) == #"'$'a\x0Ab''"#)
        #expect(WordQuote.quote("a\nb", in: .unquoted, shell: .sh) == nil)
    }

    @Test func endings() {
        #expect(WordQuote.ending(folder: true, in: .double) == "/")
        #expect(WordQuote.ending(folder: false, in: .unquoted) == " ")
        #expect(WordQuote.ending(folder: false, in: .double) == "\" ")
        #expect(WordQuote.ending(folder: false, in: .single) == "' ")
    }

    static let names = ShellQuoteTests.nasty + ["a&b", "(x)", "^x", "a\tb", "My Fo'lder $x", "x;touch PWNED;", "=x", "~x", "#x",
                                                "*?[]", "; & | < > ( ) { } \\ ^", "hi!", "cafe\u{301}", "zero\u{200B}width", "rtl\u{202E}txt"]

    /// Prints what zsh (or bash) reads the text as, with history expansion off as in a script.
    func readBack(_ text: String, shell: String) throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        let command = "printf %s " + text
        p.arguments = shell.hasSuffix("zsh") ? ["-f", "-c", command] : ["--norc", "-c", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Every quoted name, as the word it would be on the line, reads back as exactly that name, in zsh and in
    /// bash, unquoted and inside an open quote (closed here, as a file's ending closes it). A name can never
    /// become a second word or a command.
    @Test(arguments: names) func roundTrips(_ name: String) throws {
        for (shell, kind) in [("/bin/zsh", WordQuote.Shell.zsh), ("/bin/bash", WordQuote.Shell.bash)] {
            for context in [WordQuote.Context.unquoted, .double, .single] {
                guard let quoted = WordQuote.quote(name, in: context, shell: kind) else { Issue.record("no quoting for \(name)"); continue }
                #expect(!quoted.unicodeScalars.contains(where: ShellQuote.isControl), "control character in \(quoted)")
                let open = context == .double ? "\"" : context == .single ? "'" : ""
                let word = open + quoted + WordQuote.ending(folder: false, in: context).dropLast()
                #expect(try readBack(word, shell: shell) == name, "\(shell) \(context): \(word)")
            }
        }
    }

    @Test func aDirectoryNameCannotRunACommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "x;touch PWNED;"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        let word = WordQuote.quote(name, in: .unquoted)! + "/"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "cd " + word]
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("PWNED").path))
    }
}
