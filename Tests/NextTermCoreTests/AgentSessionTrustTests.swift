import Foundation
import Testing
@testable import NextTermCore

/// Folder trust for Claude Code sessions (plan 035 U5, R8): a folder is trusted only when its canonical path is listed
/// exactly; a subfolder or a sibling of a listed folder isn't.
@Suite struct AgentSessionTrustTests {
    /// A fresh folder with `app` and `app/sub` and `other` in it, symlinks resolved (the temporary folder is one).
    private func fixture() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-fixture-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Code/app/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Code/other"), withIntermediateDirectories: true)
        return AgentSessionTrust.canonical(base.path)
    }

    @Test func aListedFolderIsTrusted() throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let app = base + "/Code/app"
        let list = AgentSessionTrust.adding(app, to: [])
        #expect(AgentSessionTrust.isTrusted(app, in: list))
    }

    @Test func aChildOrSiblingOfAListedFolderIsNot() throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let list = AgentSessionTrust.adding(base + "/Code/app", to: [])
        #expect(!AgentSessionTrust.isTrusted(base + "/Code/app/sub", in: list))
        #expect(!AgentSessionTrust.isTrusted(base + "/Code/other", in: list))
        #expect(!AgentSessionTrust.isTrusted(base + "/Code", in: list))
    }

    @Test func dotsAndSymlinksResolveToTheSameEntry() throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let list = AgentSessionTrust.adding(base + "/Code/app", to: [])
        #expect(AgentSessionTrust.isTrusted(base + "/Code/../Code/app", in: list))
        #expect(AgentSessionTrust.isTrusted(base + "/Code/./app/", in: list))
        let link = base + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base + "/Code/app")
        #expect(AgentSessionTrust.canonical(link) == base + "/Code/app")
        #expect(AgentSessionTrust.isTrusted(link, in: list))
        // Trusting through the link keeps the real folder, once.
        #expect(AgentSessionTrust.adding(link, to: list) == list)
    }

    @Test func theTildeIsTheHomeFolder() {
        let home = AgentSessionTrust.canonical(NSHomeDirectory())
        #expect(AgentSessionTrust.canonical("~") == home)
        #expect(AgentSessionTrust.isTrusted("~/.", in: [home]))
    }

    @Test func anEmptyListTrustsNothing() throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(!AgentSessionTrust.isTrusted(base + "/Code/app", in: []))
        #expect(!AgentSessionTrust.isTrusted("/", in: []))
    }

    @Test func addingTwiceKeepsOneEntryAndRemovingTakesIt() throws {
        let base = try fixture()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let app = base + "/Code/app"
        let once = AgentSessionTrust.adding(app, to: [])
        let twice = AgentSessionTrust.adding(base + "/Code/../Code/app", to: once)
        #expect(twice == [app])
        let other = AgentSessionTrust.adding(base + "/Code/other", to: twice)
        #expect(AgentSessionTrust.removing(app, from: other) == [base + "/Code/other"])
    }

    @Test func aMissingFolderIsOnlyTidied() {
        let path = "/nt-no-such-folder-\(UUID().uuidString)"
        #expect(AgentSessionTrust.canonical(path + "/a/../b/") == path + "/b")
        #expect(AgentSessionTrust.canonical(path + "//a/./c") == path + "/a/c")
    }

    /// An empty path, or `.`, is the working folder, resolved as any other.
    @Test func anEmptyPathIsTheWorkingFolder() {
        let here = canonicalPath(FileManager.default.currentDirectoryPath)
        #expect(AgentSessionTrust.canonical("") == here)
        #expect(AgentSessionTrust.canonical(".") == here)
    }

    @Test func theListIsReadFromTheDefaults() throws {
        let name = "nt-trust-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AgentSessionTrust.list(in: defaults).isEmpty)
        defaults.set(["/a", "/b"], forKey: AgentSessionTrust.defaultsKey)
        #expect(AgentSessionTrust.list(in: defaults) == ["/a", "/b"])
    }

    @Test func theQuestionNamesTheFolder() {
        #expect(AgentSessionTrust.question(folder: "/p/app")
            == "Claude Code will run the hooks and MCP servers of /p/app. Trust this folder?")
    }
}
