import Foundation
import Testing
@testable import NextTermCore

/// import_secrets' path rules and its window's banner. A file in a protected folder answers as a missing one does, so an
/// agent never learns whether a protected file exists. Files are made up, under a temporary home.
@Suite struct SecretSourcesPathTests {
    typealias I = SecretImportFixtures

    /// The vault's folder in the temporary home, as the app's is in the real one.
    static func vault(_ home: I.Home) -> String { home.file("Library/Application Support/Next Term/Secrets") }

    static func check(_ path: String, _ home: I.Home, folder: String? = nil) -> Result<String, SecretSources.PathRefusal> {
        SecretSources.checkPath(path, home: home.path, vaultFolder: vault(home), folder: folder)
    }

    @Test func protectedFoldersAnswerAsAMissingFileDoes() throws {
        let home = I.Home()
        defer { home.remove() }
        home.write(".ssh/config", "Host example\n")
        home.write(".gnupg/pubring.kbx", "made up\n")
        home.write("Library/Keychains/login.keychain-db", "made up\n")
        home.write("Library/Application Support/Next Term/Secrets/vault.json", "{}\n")
        home.write("shop-web/.env.local", "A=1\n")
        try FileManager.default.createDirectory(atPath: home.file("links"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.file("links/ssh"), withDestinationPath: home.file(".ssh"))
        try FileManager.default.createSymbolicLink(atPath: home.file("shop-web/keys.env"),
                                                   withDestinationPath: home.file(".ssh/config"))
        let protected: [String] = [
            home.file(".ssh/config"), "~/.ssh/config", "~/.SSH/config", home.file(".ssh"),
            home.file(".gnupg/pubring.kbx"),
            Self.vault(home) + "/vault.json", Self.vault(home),
            home.file("Library/Keychains/login.keychain-db"),
            home.file("links/ssh/config"), home.file("shop-web/keys.env"),
            home.file("shop-web/../.ssh/config"),
        ]
        let missing: Result<String, SecretSources.PathRefusal> = Self.check(home.file("shop-web/.env.missing"), home)
        #expect(missing == .failure(.notFound))
        for path in protected {
            #expect(Self.check(path, home) == missing, "\(path)")
        }
        // A missing file inside a protected folder, and one behind a link into it: the same again.
        #expect(Self.check("~/.ssh/id_missing", home) == missing)
        #expect(Self.check(home.file("links/ssh/id_missing"), home) == missing)
        let note: String = SecretSources.PathRefusal.notFound.note
        #expect(note == "Next Term can't import from that path: not found or protected.")
        #expect(SecretSources.PathRefusal.notFound.reasonClass == "not found or protected")
    }

    @Test func aFileOverItsReadersCapIsTooLarge() throws {
        let home = I.Home()
        defer { home.remove() }
        let big: String = home.file("rag-api/.env")
        try FileManager.default.createDirectory(atPath: home.file("rag-api"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: big, contents: Data(count: 6 * 1024 * 1024))
        #expect(Self.check(big, home) == .failure(.tooLarge))
        #expect(SecretSources.PathRefusal.tooLarge.note == "Next Term can't import from that path: too large.")
        // A 1Password export may be larger: its cap is the archive's.
        let export: String = home.file("rag-api/1PasswordExport.1pux")
        FileManager.default.createFile(atPath: export, contents: Data(count: 6 * 1024 * 1024))
        #expect(Self.check(export, home) == .success(export))
        // Exactly 5 MB is read.
        let edge: String = home.file("rag-api/edge.env")
        FileManager.default.createFile(atPath: edge, contents: Data(count: SecretSources.maxBytes))
        #expect(Self.check(edge, home) == .success(edge))
    }

    @Test func aFolderIsNotAFile() throws {
        let home = I.Home()
        defer { home.remove() }
        home.write("rag-api/.env", "A=1\n")
        #expect(Self.check(home.file("rag-api"), home) == .failure(.notAFile))
        #expect(Self.check("~", home) == .failure(.notAFile))
        #expect(SecretSources.PathRefusal.notAFile.note == "Next Term can't import from that path: not a file.")
    }

    @Test func aRelativePathResolvesAgainstTheTabsFolder() throws {
        let home = I.Home()
        defer { home.remove() }
        let env: String = home.write("shop-web/.env.local", "A=1\n")
        home.write("rag-api/.env", "B=2\n")
        let folder: String = home.file("shop-web")
        #expect(Self.check(".env.local", home, folder: folder) == .success(env))
        #expect(Self.check("./.env.local", home, folder: folder) == .success(env))
        #expect(Self.check("../rag-api/.env", home, folder: folder) == .success(home.file("rag-api/.env")))
        // With no folder to resolve it against, a relative path is refused.
        #expect(Self.check(".env.local", home) == .failure(.notAbsolute))
        #expect(Self.check("", home) == .failure(.notAbsolute))
        #expect(SecretSources.PathRefusal.notAbsolute.note == "Next Term can't import from that path: not an absolute path.")
        // A tilde path is the home folder's.
        #expect(Self.check("~/shop-web/.env.local", home) == .success(env))
    }

    @Test func linksAreFollowedToTheFileRead() throws {
        let home = I.Home()
        defer { home.remove() }
        let env: String = home.write("shop-web/.env.local", "A=1\n")
        let link: String = home.file("shop-web/current.env")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: env)
        #expect(Self.check(link, home) == .success(env))
        // A link to a folder is not a file.
        try FileManager.default.createSymbolicLink(atPath: home.file("here"), withDestinationPath: home.file("shop-web"))
        #expect(Self.check(home.file("here"), home) == .failure(.notAFile))
        #expect(Self.check(home.file("here/.env.local"), home) == .success(env))
    }

    /// The data volume's own path to a file (`/System/Volumes/Data/…`) is the same file by another name: a protected
    /// one answers as a missing file does, in any case, and any other comes back by its usual path.
    @Test func theDataVolumesPathReachesNoProtectedFile() throws {
        let home = I.Home()
        defer { home.remove() }
        home.write(".ssh/config", "Host example\n")
        home.write(".gnupg/pubring.kbx", "made up\n")
        home.write("Library/Keychains/login.keychain-db", "made up\n")
        home.write("Library/Application Support/Next Term/Secrets/vault.json", "{}\n")
        let env: String = home.write("shop-web/.env.local", "A=1\n")
        let data: String = "/System/Volumes/Data"
        try #require(FileManager.default.fileExists(atPath: data + env), "the temporary home is on the data volume")
        let missing: Result<String, SecretSources.PathRefusal> = Self.check(home.file("shop-web/.env.missing"), home)
        let protected: [String] = [
            home.file(".ssh/config"), home.file(".ssh"), home.file(".ssh/id_missing"), home.file(".gnupg/pubring.kbx"),
            home.file("Library/Keychains/login.keychain-db"), Self.vault(home) + "/vault.json",
        ]
        for path in protected {
            #expect(Self.check(data + path, home) == missing, "\(path)")
            #expect(Self.check(data.lowercased() + path, home) == missing, "\(path)")
        }
        // A link to the data volume's path of a protected folder: the same again.
        try FileManager.default.createSymbolicLink(atPath: home.file("shop-web/keys"), withDestinationPath: data + home.file(".ssh"))
        #expect(Self.check(home.file("shop-web/keys/config"), home) == missing)
        // Any other file is read by the path the rest of the Mac uses.
        #expect(Self.check(data + env, home) == .success(env))
    }

    /// AE9's banner: who asks, from where, and the agent's reason in its own words.
    @Test func theBannerNamesTheAskerTheSourceAndTheReason() {
        let asker: String = SecretSources.askerText(agent: "Claude Code", tab: "tab 2", project: "/Users/someone/Code/shop-web")
        #expect(asker == "Claude Code in shop-web")
        let from: String = SecretSources.shownPath("/Users/someone/Code/shop-web/.env.local", home: "/Users/someone")
        #expect(from == "~/Code/shop-web/.env.local")
        let banner: String = SecretSources.askBanner(asker: asker, from: from, reason: "Move the app's keys out of .env.local")
        #expect(banner == "Claude Code in shop-web asks to import keys from ~/Code/shop-web/.env.local: Move the app's keys out of .env.local")
        // No reason, or only spaces: the sentence ends at the source.
        #expect(SecretSources.askBanner(asker: asker, from: "1Password", reason: nil)
                == "Claude Code in shop-web asks to import keys from 1Password.")
        #expect(SecretSources.askBanner(asker: asker, from: "1Password", reason: "  ")
                == "Claude Code in shop-web asks to import keys from 1Password.")
        // An agent not named, by its tab; one outside every tab; a path outside the home folder, whole.
        #expect(SecretSources.askerText(agent: nil, tab: "tab 3", project: "/Users/someone/Code/rag-api") == "An agent in tab 3 of rag-api")
        #expect(SecretSources.askerText(agent: nil, tab: "tab 3", project: nil) == "An agent in tab 3")
        #expect(SecretSources.askerText(agent: "Codex", tab: "tab 1", project: nil) == "Codex")
        #expect(SecretSources.askerText(agent: nil, tab: nil, project: nil) == "An agent outside Next Term\u{2019}s tabs")
        #expect(SecretSources.shownPath("/Volumes/Work/shop-web/.env", home: "/Users/someone") == "/Volumes/Work/shop-web/.env")
        #expect(SecretSources.shownPath("/Users/someone2/.env", home: "/Users/someone") == "/Users/someone2/.env")
    }

    /// The answer's other outcomes: nothing but their status and a fixed note or reason class.
    @Test func noOtherOutcomeCarriesMoreThanItsStatusAndAFixedText() {
        let reasons: [SecretSources.Unreadable] = [.tooLarge, .envTooLarge, .notText, .notJSON, .tooMany, .encryptedExport,
                                                   .notAnExport(from: "Bitwarden"), .unknownColumns, .notTOML(line: 4),
                                                   .configTooLarge, .notAFile, .cantOpen]
        for reason in reasons {
            let answer: [String: Any] = SecretSources.answer(for: .unreadable(reason))
            #expect(Set(answer.keys) == ["status", "reason"], "\(reason)")
            #expect(answer["reason"] as? String == reason.reasonClass)
            #expect(!reason.reasonClass.contains("4"), "\(reason)")
        }
        let declined: [String: Any] = SecretSources.answer(for: .declined)
        #expect(declined["note"] as? String == "The user declined, so no key was imported.")
        let nothing: [String: Any] = SecretSources.answer(for: .nothingFound(format: .env))
        #expect(Set(nothing.keys) == ["status", "note", "format"])
    }
}
