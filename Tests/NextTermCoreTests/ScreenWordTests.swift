import Testing
@testable import NextTermCore

@Suite struct ScreenWordTests {
    @Test func theWordAndWhatTheCommandBeforeItLists() throws {
        let cd = try #require(ScreenWord.read("deploy@web-1:~/app$ cd /va"))
        #expect(cd.kind == .folders && cd.word == "/va" && cd.folder == "/" && cd.typed == "va")
        #expect(cd.before == "deploy@web-1:~/app$ cd ")
        let ls = try #require(ScreenWord.read("$ ls fo"))
        #expect(ls.kind == .paths && ls.folder == "" && ls.typed == "fo")
        // Options between the command and the word, and a path to the command.
        #expect(ScreenWord.read("$ ls -la src/ma")?.kind == .paths)
        #expect(ScreenWord.read("$ /bin/ls src/ma")?.folder == "src/")
        // Nothing typed yet after the command.
        let empty = try #require(ScreenWord.read("% cd "))
        #expect(empty.word == "" && empty.typed == "" && empty.kind == .folders)
        // Any word that looks like a path, after any command; `~/` and dots.
        #expect(ScreenWord.read("$ git add src/Ma")?.kind == .paths)
        #expect(ScreenWord.read("$ vim ~/.zs")?.folder == "~/")
        #expect(ScreenWord.read("$ python ./scr")?.kind == .paths)
    }

    @Test func otherWordsAreTheShellsOwn() {
        // A command name, an option, a word that names no path after a command that isn't listed for.
        #expect(ScreenWord.read("$ gi") == nil)
        #expect(ScreenWord.read("$ git chec") == nil)
        #expect(ScreenWord.read("$ ls --colo") == nil)
        // The prompt's own text, with no blank before the cursor.
        #expect(ScreenWord.read("app$") == nil)
        // The command after a separator is the one that counts.
        #expect(ScreenWord.read("$ ls x | grep fo") == nil)
        #expect(ScreenWord.read("$ make && cd Doc")?.kind == .folders)
    }

    @Test func onlyPlainWordsAreRead() {
        for word in ["'My Fo", "\"x", "a\\ b", "$HOME/x", "`id`/", "*.txt", "f?o", "a[b]", "{a,b}", "x;y", "a&b", "a|b", "<f", "!x", "#x",
                     "a^b", "~user/x", "~", "a~b", "=cmd", "-x", "a\u{7}b", "a\u{200B}b"] {
            #expect(ScreenWord.read("$ ls " + word) == nil, "\(word)")
        }
        #expect(ScreenWord.read("$ ls café/é")?.typed == "é")
        // A quote or a backslash earlier on the line may reach the word: `'My Fo`, `a\ b`, even one in the prompt.
        #expect(ScreenWord.read("$ git add 'a b src/x") == nil)
        #expect(ScreenWord.read("me's mac $ cd sr") == nil)
        #expect(ScreenWord.read("$ echo 'x ls fo") == nil)
        #expect(ScreenWord.read("$ echo 'x ; cd sr") == nil)
        #expect(ScreenWord.read("$ cd a=b,c@d%e+f:g")?.typed == "a=b,c@d%e+f:g")
    }

    @Test func theListFollowsTheWordInItsFolder() throws {
        let start = try #require(ScreenWord.read("$ ls src/m"))
        #expect(start.next("$ ls src/ma")?.typed == "ma")
        // Another folder, another command line, or a word that is no longer plain: the list closes.
        #expect(start.next("$ ls src/main/") == nil)
        #expect(start.next("$ cat src/ma") == nil)
        #expect(start.next("$ ls src/m'") == nil)
        #expect(start.next("$ ls src/ma ") == nil)
    }
}
