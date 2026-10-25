import Darwin
import Foundation
import Testing
@testable import NextTermCore

/// More of what a picked file is: a project's MCP config that links elsewhere still goes to the move import, the keys
/// outside a move target's servers come back as a copy checked against the vault as it is when the copy opens, an
/// archive past the text limit is read, and a pipe or a device is refused without waiting. Files are made up, under a
/// temporary home.
@Suite struct SecretFileImportPickTests {
    typealias C = ConfigFixtures
    typealias I = SecretImportFixtures

    @Test func aProjectsMCPConfigThatLinksIntoDotfilesGoesToTheMoveImport() throws {
        let home = I.Home()
        defer { home.remove() }
        let text = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(I.github)"}}}}"#
        let target: String = home.write("dotfiles/mcp.json", text)
        try FileManager.default.createDirectory(atPath: home.file("triage-agent"), withIntermediateDirectories: true)
        let link: String = home.file("triage-agent/.mcp.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        // The project isn't open: the file's own place names it.
        guard case .move(let source, let rest) = SecretSources.readPicked(link, home: home.path) else {
            Issue.record("a project's .mcp.json that links elsewhere goes to the MCP-config import")
            return
        }
        #expect(source.path == link && rest.rows.isEmpty)
        // The file it links to, picked by itself, is no project's: a copy.
        #expect(SecretFileImportTests.report(SecretSources.readPicked(target, home: home.path)) != nil)
    }

    @Test func keysOutsideAMoveTargetsServersAreCheckedAgainstTheVaultWhenTheCopyOpens() throws {
        let home = I.Home()
        defer { home.remove() }
        let text: String = """
            [mcp_servers.github.env]
            GITHUB_TOKEN = "\(I.github)"

            [shell_environment_policy.set]
            GITHUB_TOKEN = "\(C.github)"
            """
        let path: String = home.write(".codex/config.toml", text)
        guard case .move(_, let rest) = SecretSources.readPicked(path, home: home.path) else {
            Issue.record("Codex's config.toml goes to the MCP-config import")
            return
        }
        let row = try #require(rest.rows.first)
        #expect(rest.rows.count == 1 && row.name == "GITHUB_TOKEN" && row.ticked && row.note == .stillInFile)
        // The move import stored GITHUB_TOKEN from the server since: the shell's value would replace it.
        let checked: SourceReport = rest.checked(against: ["GITHUB_TOKEN"])
        let now = try #require(checked.rows.first)
        #expect(!now.ticked && now.note == .replaces && now.value == row.value)
        #expect(checked.purpose == rest.purpose && checked.agent == "Codex" && checked.fileNote == .stillInFile)
        let unchanged = try #require(rest.checked(against: ["OTHER_KEY"]).rows.first)
        #expect(unchanged.ticked && unchanged.note == .stillInFile)
    }

    @Test func anArchivePastTheTextLimitIsReadAndOtherFilesAreNot() throws {
        let home = I.Home()
        defer { home.remove() }
        var bytes = [UInt8](repeating: 0x41, count: SecretSources.maxBytes + 16)
        bytes.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x03, 0x04] as [UInt8])
        let archive: String = home.file("made-up.1pux")
        FileManager.default.createFile(atPath: archive, contents: Data(bytes))
        guard case .success(let read) = SecretSources.fileBytes(atPath: archive) else {
            Issue.record("a zip archive past maxBytes is read")
            return
        }
        #expect(read.count == bytes.count && Array(read.prefix(4)) == Array(bytes.prefix(4)))
        bytes[0] = 0x7B
        let text: String = home.file("made-up.json")
        FileManager.default.createFile(atPath: text, contents: Data(bytes))
        #expect(SecretSources.fileBytes(atPath: text) == .failure(.tooLarge))
    }

    @Test func aPipeAndADeviceAreRefusedWithoutWaiting() throws {
        let home = I.Home()
        defer { home.remove() }
        let pipe: String = home.file("keys.env")
        #expect(mkfifo(pipe, 0o600) == 0)
        // No writer ever opens it: a read that waited would hang here.
        #expect(SecretSources.fileBytes(atPath: pipe) == .failure(.notAFile))
        #expect(SecretFileImportTests.report(SecretSources.readPicked(pipe, home: home.path))?.unreadable == .notAFile)
        #expect(SecretSources.fileBytes(atPath: "/dev/null") == .failure(.notAFile))
    }
}
