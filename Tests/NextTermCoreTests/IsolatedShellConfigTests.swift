import Foundation
import Testing
@testable import NextTermCore

@Suite struct IsolatedShellConfigTests {
    func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-isolated-\(UUID().uuidString)")
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    @Test func prepareWritesAPrivateConfigThatKeepsItsHistoryInside() throws {
        let folder = try temporaryFolder("zsh 'own' config")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(IsolatedShellConfig.prepare(folder))
        let zshrc = try String(contentsOf: folder.appendingPathComponent(".zshrc"), encoding: .utf8)
        #expect(zshrc == IsolatedShellConfig.zshrc(in: folder.path))
        #expect(zshrc.contains("HISTFILE=" + ShellQuote.quote(folder.path + "/.zsh_history") + "\n"))
        #expect(zshrc.contains("PROMPT='%1~ %# '\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        // Again over an existing folder: the same config.
        #expect(IsolatedShellConfig.prepare(folder))
        #expect(try String(contentsOf: folder.appendingPathComponent(".zshrc"), encoding: .utf8) == zshrc)
    }

    /// Starts zsh as a tab does (a login shell, interactive, with the integration's ZDOTDIR and the folder it hands over
    /// to), in a home folder whose own config files each print their name, and prints what the shell ended with.
    func tabShell(home: URL, userFolder: String) throws -> String {
        let integration = try ShellIntegration.install(in: home.appendingPathComponent("support"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", #"print -r -- "ZD=${ZDOTDIR-unset}"; print -r -- "HF=$HISTFILE"; print -r -- "PR=$PROMPT""#]
        process.environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color",
            "ZDOTDIR": integration.path, "NEXTTERM_USER_ZDOTDIR": userFolder,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aTabShellReadsTheIsolatedConfigAndNeverTheUsers() throws {
        let home = try temporaryFolder("home")
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            try "print -r -- USERCONFIG\(name)\n".write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let folder = home.deletingLastPathComponent().appendingPathComponent("test zsh", isDirectory: true)
        #expect(IsolatedShellConfig.prepare(folder))

        let isolated = try tabShell(home: home, userFolder: folder.path)
        #expect(!isolated.contains("USERCONFIG"), "the shell read the user's own config: \(isolated)")
        #expect(isolated.contains("ZD=\(folder.path)\n") && isolated.contains("HF=\(folder.path)/.zsh_history\n"), "\(isolated)")
        #expect(isolated.contains("PR=%1~ %# \n"), "\(isolated)")

        // Without it (no ZDOTDIR of the user's: the home folder), the same shell reads every one of the user's files.
        let own = try tabShell(home: home, userFolder: "")
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] { #expect(own.contains("USERCONFIG\(name)"), "\(own)") }
        #expect(own.contains("ZD=unset\n"), "\(own)")
    }
}
