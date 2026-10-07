import Testing
@testable import NextTermCore

@Suite struct CommandLineLinkTests {
    let home = "/Users/ada"
    let script = "/Applications/Next Term.app/Contents/Resources/bin/nxtrm"
    let stock = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The plan for a PATH, with these folders writable and these entries in them.
    func plan(_ path: [String], writable: Set<String> = [], entries: [String: CommandLineLink.Entry] = [:]) -> CommandLineLink.Plan {
        CommandLineLink.plan(path: path, home: home, script: script,
                             isWritable: { writable.contains($0) }, entry: { entries[$0] ?? .nothing })
    }

    @Test func aStockMacHasNoFolderWithoutAPassword() {
        #expect(plan(stock) == .unavailable)
        // Writable, but not on PATH: no PATH entry is ever added.
        #expect(plan(stock, writable: ["/Users/ada/.local/bin", "/opt/homebrew/bin"]) == .unavailable)
    }

    @Test func theFirstWritableCommandFolderOnPathTakesIt() {
        let brew = ["/opt/homebrew/bin", "/opt/homebrew/sbin"] + stock
        #expect(plan(brew, writable: ["/opt/homebrew/bin"]) == .link("/opt/homebrew/bin/nxtrm"))
        // An Intel Mac's Homebrew owns /usr/local/bin.
        #expect(plan(stock, writable: ["/usr/local/bin"]) == .link("/usr/local/bin/nxtrm"))
        // PATH order decides, both ways.
        let writable: Set = ["/Users/ada/.local/bin", "/opt/homebrew/bin"]
        #expect(plan(["/Users/ada/.local/bin"] + brew, writable: writable) == .link("/Users/ada/.local/bin/nxtrm"))
        #expect(plan(brew + ["/Users/ada/.local/bin"], writable: writable) == .link("/opt/homebrew/bin/nxtrm"))
        #expect(plan(["/Users/ada/bin"] + stock, writable: ["/Users/ada/bin"]) == .link("/Users/ada/bin/nxtrm"))
    }

    @Test func otherWritableFoldersOnPathAreNotOurs() {
        let managed = [".", "node_modules/.bin", "/Users/ada/.rbenv/shims", "/Users/ada/.cargo/bin",
                       "/Users/ada/.nvm/versions/node/v22.0.0/bin", "/Users/ada/Code/api/vendor/bin"]
        #expect(plan(managed + stock, writable: Set(managed)) == .unavailable)
        #expect(plan(managed + ["/opt/homebrew/bin"], writable: Set(managed + ["/opt/homebrew/bin"])) == .link("/opt/homebrew/bin/nxtrm"))
        // The app's own bin folder, inherited from a Next Term tab, is neither a link nor someone else's.
        let bundled = "/Applications/Next Term.app/Contents/Resources/bin"
        #expect(plan([bundled, "/opt/homebrew/bin"], writable: ["/opt/homebrew/bin"], entries: [script: .file]) == .link("/opt/homebrew/bin/nxtrm"))
    }

    @Test func pathSpellings() {
        #expect(plan(["~/.local/bin"], writable: ["/Users/ada/.local/bin"]) == .link("/Users/ada/.local/bin/nxtrm"))
        #expect(plan(["/opt/homebrew/bin/"], writable: ["/opt/homebrew/bin"]) == .link("/opt/homebrew/bin/nxtrm"))
        #expect(CommandLineLink.folders(["/usr/bin", "", "bin", "/usr/bin/", "~", "~/bin", "/"], home: home)
                == ["/usr/bin", "/Users/ada", "/Users/ada/bin", "/"])
    }

    @Test func aLinkToThisAppIsKeptWhereverItIs() {
        let path = ["/Users/ada/.local/bin", "/opt/homebrew/bin"] + stock
        let writable: Set = ["/Users/ada/.local/bin", "/opt/homebrew/bin"]
        // Installed with the password earlier: no second link in a folder before it.
        #expect(plan(path, writable: writable, entries: ["/usr/local/bin/nxtrm": .link(script)]) == .linked("/usr/local/bin/nxtrm"))
        #expect(plan(path, writable: writable, entries: ["/opt/homebrew/bin/nxtrm": .link(script)]) == .linked("/opt/homebrew/bin/nxtrm"))
        // One the user made in a folder of their own counts too.
        #expect(plan(["/Users/ada/.dotfiles/bin"] + path, entries: ["/Users/ada/.dotfiles/bin/nxtrm": .link(script)]) == .linked("/Users/ada/.dotfiles/bin/nxtrm"))
    }

    @Test func aLinkToAnotherCopyOfTheAppIsRepointed() {
        let old = CommandLineLink.Entry.link("/Users/ada/Downloads/Next Term.app/Contents/Resources/bin/nxtrm")
        let path = ["/Users/ada/.local/bin", "/opt/homebrew/bin"] + stock
        let writable: Set = ["/Users/ada/.local/bin", "/opt/homebrew/bin"]
        // Repointed where it is, not joined by a second link earlier on PATH.
        #expect(plan(path, writable: writable, entries: ["/opt/homebrew/bin/nxtrm": old]) == .link("/opt/homebrew/bin/nxtrm"))
        // In a folder that needs a password, the shell still runs that copy: a link after it would never be
        // reached, so only a folder ahead of it, or the password route, will do.
        #expect(plan(stock + ["/opt/homebrew/bin"], writable: ["/opt/homebrew/bin"], entries: ["/usr/local/bin/nxtrm": old]) == .unavailable)
        #expect(plan(["/opt/homebrew/bin"] + stock, writable: ["/opt/homebrew/bin"], entries: ["/usr/local/bin/nxtrm": old])
                == .link("/opt/homebrew/bin/nxtrm"))
        #expect(plan(stock, entries: ["/usr/local/bin/nxtrm": old]) == .unavailable)
    }

    @Test func aLinkToACopyThatIsGoneIsPassedOverUnlessItCanBeRepointed() {
        let gone = CommandLineLink.Entry.brokenLink("/Users/ada/Downloads/Next Term.app/Contents/Resources/bin/nxtrm")
        // The shell passes over a link to nothing, so one later on PATH is reached.
        #expect(plan(stock + ["/opt/homebrew/bin"], writable: ["/opt/homebrew/bin"], entries: ["/usr/local/bin/nxtrm": gone])
                == .link("/opt/homebrew/bin/nxtrm"))
        #expect(plan(stock, entries: ["/usr/local/bin/nxtrm": gone]) == .unavailable)
        // Writable: repointed where it is.
        let path = ["/Users/ada/.local/bin", "/opt/homebrew/bin"] + stock
        #expect(plan(path, writable: ["/Users/ada/.local/bin", "/opt/homebrew/bin"], entries: ["/opt/homebrew/bin/nxtrm": gone])
                == .link("/opt/homebrew/bin/nxtrm"))
    }

    @Test func someoneElsesNxtrmIsNeverTouchedOrShadowed() {
        let path = ["/Users/ada/.local/bin", "/opt/homebrew/bin"] + stock
        let writable: Set = ["/Users/ada/.local/bin", "/opt/homebrew/bin"]
        #expect(plan(path, writable: writable, entries: ["/opt/homebrew/bin/nxtrm": .file]) == .taken("/opt/homebrew/bin/nxtrm"))
        #expect(plan(path, writable: writable, entries: ["/Users/ada/.local/bin/nxtrm": .link("/opt/tools/nxtrm")]) == .taken("/Users/ada/.local/bin/nxtrm"))
        #expect(plan(path, writable: writable, entries: ["/Users/ada/.local/bin/nxtrm": .brokenLink("/opt/tools/nxtrm")]) == .taken("/Users/ada/.local/bin/nxtrm"))
        // In a folder that is not a command folder, still first on PATH.
        #expect(plan(["/Users/ada/.cargo/bin"] + path, writable: writable, entries: ["/Users/ada/.cargo/bin/nxtrm": .file]) == .taken("/Users/ada/.cargo/bin/nxtrm"))
        // Ours first on PATH wins over theirs later.
        #expect(plan(path, writable: writable, entries: ["/Users/ada/.local/bin/nxtrm": .link(script), "/usr/local/bin/nxtrm": .file])
                == .linked("/Users/ada/.local/bin/nxtrm"))
    }

    @Test func linksOfOurs() {
        #expect(CommandLineLink.isOurs(script))
        #expect(CommandLineLink.isOurs("/Volumes/Next Term/Next Term.app/Contents/Resources/bin/nxtrm"))
        #expect(!CommandLineLink.isOurs("/opt/tools/nxtrm"))
        #expect(!CommandLineLink.isOurs("/Applications/Next Term.app/Contents/Resources/bin/nxtrm-old"))
    }

    @Test func theOfferComesOncePerVersionUntilDeclined() {
        #expect(CommandLineLink.shouldOffer(remembered: nil, version: "0.9.0"))
        #expect(!CommandLineLink.shouldOffer(remembered: "0.9.0", version: "0.9.0"))
        #expect(CommandLineLink.shouldOffer(remembered: "0.9.0", version: "0.9.1"))
        #expect(!CommandLineLink.shouldOffer(remembered: CommandLineLink.declined, version: "0.9.1"))
    }
}
