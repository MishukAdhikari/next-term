import Foundation
import Testing
@testable import NextTermCore

/// A config shared through git gets the git warning, whether it sits in a work tree or is a link into one, as a dotfiles
/// repository set up with links (stow-style) makes it: reads and writes follow the link, so the change is committed
/// there (review finding #21). Folders made up under a temporary home.
@Suite struct SecretImportGitTests {
    func makeFolder(_ home: F.Home, _ relative: String) {
        try? FileManager.default.createDirectory(atPath: home.file(relative), withIntermediateDirectories: true)
    }

    @Test func aFileInAWorkTreeAndOneOutside() {
        let home = F.Home()
        defer { home.remove() }
        makeFolder(home, "proj/.git")
        let inside = home.write("proj/.cursor/mcp.json", "{}\n")
        let outside = home.write(".cursor/mcp.json", "{}\n")
        #expect(SecretImport.isInGitWorkTree(inside))
        #expect(!SecretImport.isInGitWorkTree(outside))
    }

    @Test func aLinkToAFileInADotfilesRepository() throws {
        let home = F.Home()
        defer { home.remove() }
        makeFolder(home, "dotfiles/.git")
        let real = home.write("dotfiles/codex/config.toml", "model = \"x\"\n")
        makeFolder(home, ".codex")
        let link = home.file(".codex/config.toml")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(SecretImport.isInGitWorkTree(link))
    }

    @Test func aLinkedFolderInAWorktree() throws {
        let home = F.Home()
        defer { home.remove() }
        // A worktree's `.git` is a file; the whole ~/.gemini folder is the link.
        home.write("dotfiles/.git", "gitdir: /elsewhere/.git/worktrees/dotfiles\n")
        home.write("dotfiles/gemini/settings.json", "{}\n")
        try FileManager.default.createSymbolicLink(atPath: home.file(".gemini"), withDestinationPath: home.file("dotfiles/gemini"))
        #expect(SecretImport.isInGitWorkTree(home.file(".gemini/settings.json")))
    }

    @Test func theScanMarksALinkedConfigShared() throws {
        let home = F.Home()
        defer { home.remove() }
        makeFolder(home, "dotfiles/.git")
        let text = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(F.github)"}}}}"#
        let real = home.write("dotfiles/cursor/mcp.json", text)
        makeFolder(home, ".cursor")
        try FileManager.default.createSymbolicLink(atPath: home.file(".cursor/mcp.json"), withDestinationPath: real)
        let found = SecretImport.scan(F.sources(home), inGitWorkTree: SecretImport.isInGitWorkTree)
        let finding = found.findings.first { $0.variable == "GITHUB_TOKEN" }
        #expect(finding?.shared == true)
    }
}
