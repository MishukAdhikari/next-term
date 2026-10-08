import Foundation
import Testing
@testable import NextTermCore

@Suite struct CompletionContextTests {
    /// A report as the hook sends it: zsh's words for the line (given here as zsh splits them).
    func report(_ words: [String], blank: Bool = false, directory: String = "/work", head: String = "", resolved: String = "") -> CompletionProtocol.TabReport {
        let word = blank ? "" : words.last ?? ""
        let line = words.joined(separator: " ") + (blank ? " " : "")
        return .init(id: 1, directory: directory, lbuffer: line, words: words, word: word, unquoted: word, head: head, resolvedHead: resolved)
    }

    func context(_ words: [String], blank: Bool = false, head: String = "", resolved: String = "") -> CompletionContext? {
        CompletionContext.analyze(report(words, blank: blank, head: head, resolved: resolved))
    }

    @Test func commandsAndArguments() {
        let cd = context(["cd", "So"])
        #expect(cd?.kind == .folders && cd?.folder == "/work" && cd?.typed == "So" && cd?.keep == "" && cd?.quote == .unquoted)
        let ls = context(["ls", "src/ma"])
        #expect(ls?.kind == .paths && ls?.folder == "/work/src" && ls?.typed == "ma" && ls?.keep == "src/")
        #expect(context(["git", "chec"]) == nil)                       // not a path command, not a path
        #expect(context(["git", "add", "src/"])?.kind == .paths)       // but a path-looking word is
        #expect(context(["git", "add", "./x"])?.folder == "/work")
        #expect(context(["cd"], blank: true)?.typed == "")
        #expect(context(["cd"], blank: true)?.kind == .folders)
        #expect(context(["mkdir", "-p", "a/b"])?.folder == "/work/a")
        #expect(context(["ls", "/etc/"])?.folder == "/etc" && context(["ls", "/etc/"])?.typed == "")
        #expect(context(["ls", "../x"])?.folder == "/")
    }

    @Test func theCurrentCommand() {
        #expect(context(["a", "|", "cd", "Doc"])?.kind == .folders)
        #expect(context(["echo", "hi", "&&", "ls", "~/De"], head: "~/", resolved: "/Users/me/")?.folder == "/Users/me")
        #expect(context(["echo", "hi", "&&", "ls", "~/De"], head: "~/", resolved: "/Users/me/")?.keep == "~/")
        #expect(context(["(", "cd", "So"])?.kind == .folders)
        #expect(context(["if", "true", ";", "then", "cd", "S"])?.kind == .folders)
        #expect(context(["sudo", "cd", "So"])?.kind == .folders)
        #expect(context(["A=1", "B=2", "env", "C=3", "ls", "x/"])?.kind == .paths)
        #expect(context(["time", "nohup", "noglob", "ls", "x"])?.kind == .paths)
        #expect(context(["sudo", "-u", "x", "cd", "So"]) == nil)      // sudo with options: zsh's
        #expect(context(["ls"]) == nil)                                // the command word
        #expect(context(["Sou"]) == nil)                               // a first word, as under autocd
        #expect(context(["echo", "|", "gre"]) == nil)
    }

    @Test func redirectionsAndOptions() {
        #expect(context(["cat", "<", "f"])?.kind == .paths)
        #expect(context(["echo", "hi", ">", "ou"])?.kind == .paths)
        #expect(context(["make", "2>", "lo"])?.kind == .paths)
        let option = context(["tool", "--file=./sr"])
        #expect(option?.kind == .paths && option?.keep == "--file=./" && option?.typed == "sr")
        #expect(context(["ls", "-la"]) == nil)
        #expect(context(["cd", "-"]) == nil)
        #expect(context(["cd", "-2"]) == nil)
        #expect(context(["ls", "--color"]) == nil)
        #expect(context(["vim", "**"]) == nil)
        #expect(context(["vim", "src/**"]) == nil)
    }

    @Test func quoting() {
        let double = context(["ls", "\"My Fo"])
        #expect(double?.quote == .double && double?.keep == "\"" && double?.typed == "My Fo")
        let single = context(["ls", "'My Fo"])
        #expect(single?.quote == .single && single?.keep == "'" && single?.typed == "My Fo")
        let inner = context(["ls", "\"My Folder/su"])
        #expect(inner?.quote == .double && inner?.keep == "\"My Folder/" && inner?.folder == "/work/My Folder" && inner?.typed == "su")
        let escaped = context(["ls", #"My\ Fo"#])
        #expect(escaped?.quote == .unquoted && escaped?.typed == "My Fo")
        let laterQuote = context(["ls", "src/\"ma"])
        #expect(laterQuote?.quote == .double && laterQuote?.keep == "src/\"" && laterQuote?.typed == "ma")
        let midName = context(["ls", "ab\"c"])
        #expect(midName?.quote == .unquoted && midName?.keep == "" && midName?.typed == "abc")
        #expect(context(["ls", "\"My Folder\""]) == nil)              // a finished word
        #expect(context(["ls", "\"a\"b"]) == nil)                      // mixed quoting
        #expect(context(["ls", "$'a\\nb"]) == nil)                     // $'…'
        #expect(context(["ls", "$(echo So"]) == nil)
        #expect(context(["ls", "`echo"]) == nil)
        #expect(context(["ls", "$HOME/x"]) == nil)                     // without the hook's head
        #expect(context(["ls", "$HOME/x"], head: "$HOME/", resolved: "/Users/me/")?.folder == "/Users/me")
        #expect(context(["ls", "~user/x"]) == nil)
        #expect(context(["ls", "~"]) == nil)
        #expect(context(["ls", "*.sw"]) == nil)
        #expect(context(["ls", "{a,b}"]) == nil)
        #expect(context(["ls", "foo$bar"]) == nil)
    }

    @Test func replacements() {
        let cd = context(["cd", "So"])!
        #expect(cd.replacement(name: Array("Sources".utf8), folder: true) == "Sources/")
        let double = context(["ls", "\"My Fo"])!
        #expect(double.replacement(name: Array("My Fo'lder $x".utf8), folder: true) == "\"My Fo'lder \\$x/")
        #expect(double.replacement(name: Array("My File".utf8), folder: false) == "\"My File\" ")
        let option = context(["tool", "--file=./sr"])!
        #expect(option.replacement(name: Array("src".utf8), folder: true) == "--file=./src/")
        let home = context(["ls", "~/De"], head: "~/", resolved: "/Users/me/")!
        #expect(home.replacement(name: Array("Desktop".utf8), folder: true) == "~/Desktop/")
        let trap = context(["cd", "x"])!
        #expect(trap.replacement(name: Array("x;touch PWNED;".utf8), folder: true) == #"x\;touch\ PWNED\;/"#)
    }

    @Test func theWordAsItChanges() {
        let cd = context(["cd", "So"])!
        #expect(cd.with(word: "Sou")?.typed == "Sou")
        #expect(cd.with(word: "S")?.typed == "S")
        #expect(cd.with(word: "")?.typed == "")
        #expect(cd.with(word: "Sources/") == nil)                      // another folder
        let src = context(["ls", "src/ma"])!
        #expect(src.with(word: "src/mai")?.typed == "mai")
        #expect(src.with(word: "lib/ma") == nil)
        let double = context(["ls", "\"My Fo"])!
        #expect(double.with(word: "\"My Fol")?.typed == "My Fol")
        #expect(double.with(word: "\"My Fol\"") == nil)                // the quote closed
        let option = context(["tool", "--file=./sr"])!
        #expect(option.with(word: "--file=./src")?.typed == "src")
        #expect(option.with(word: "--out=./sr") == nil)
        #expect(context(["cd", ".h"])?.showsHidden == true && cd.showsHidden == false)
    }

    @Test func unreadableReportsStepBack() {
        var bad = report(["cd", "So"])
        bad.unreadable = true
        #expect(CompletionContext.analyze(bad) == nil)
    }
}
