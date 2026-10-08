import Foundation
import Testing
@testable import NextTermCore

@Suite struct RemoteCompletionHookTests {
    /// Runs a script as RemoteConnection.run has the host run it (base64 through a login shell's `-c`), with `input`
    /// on stdin as `run` sends it.
    func run(_ script: String, home: String, shell: String = "/bin/zsh", input: String = "") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", RemoteShell.command(script)]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell]
        let out = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".cache/next-term/tabs"), withIntermediateDirectories: true)
        return url
    }

    func files(_ home: URL) -> [String] { (FileManager.default.subpaths(atPath: home.path) ?? []).sorted() }

    func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }

    let nonce = "0123456789abcdef0123456789abcdef"

    @Test func allowWritesTheHookWithTheNonceFromStdinOnly() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let before = files(home)
        let script = RemoteCompletionHook.installScript
        // The nonce is never on a command line.
        #expect(!script.contains(nonce) && !RemoteShell.command(script).contains(nonce))
        #expect(RemoteCompletionHook.parse(try run(script, home: home.path, input: nonce + "\n")) == .installed)
        let folder = home.appendingPathComponent(".cache/next-term/completion")
        #expect((try? String(contentsOf: folder.appendingPathComponent("nonce"), encoding: .utf8)) == nonce + "\n")
        #expect((try? String(contentsOf: folder.appendingPathComponent("completion.zsh"), encoding: .utf8)) == ZshCompletionScript.script)
        #expect((try? String(contentsOf: folder.appendingPathComponent("zsh/.zshenv"), encoding: .utf8)) == RemoteCompletionHook.zshenv)
        #expect(mode(folder.appendingPathComponent("nonce")) == 0o600 && mode(folder) == 0o700 && mode(folder.appendingPathComponent("start")) == 0o700)
        // Nothing outside the hook's folder.
        let added = Set(files(home)).subtracting(before)
        #expect(!added.isEmpty && added.allSatisfy { $0.hasPrefix(".cache/next-term/completion") })
        #expect(RemoteCompletionHook.parse(try run(RemoteCompletionHook.checkScript, home: home.path)) == .present(version: RemoteCompletionHook.version))
        // The version is what the files hold: a hook written by a Next Term with another hook reads as another one.
        let current = try String(contentsOf: folder.appendingPathComponent("version"), encoding: .utf8)
        #expect(current == "\(RemoteCompletionHook.version)\n" && RemoteCompletionHook.version > 1)
        try "1\n".write(to: folder.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        #expect(RemoteCompletionHook.parse(try run(RemoteCompletionHook.checkScript, home: home.path)) == .present(version: 1))
        // Remove leaves the files as they were before Allow.
        #expect(RemoteCompletionHook.parse(try run(RemoteCompletionHook.removeScript, home: home.path)) == .removed)
        #expect(files(home) == before)
        #expect(RemoteCompletionHook.parse(try run(RemoteCompletionHook.checkScript, home: home.path)) == .missing)
    }

    @Test func onlyForZshAndNeverHalfWritten() throws {
        let home = try temporaryHome()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent(".cache/next-term").path)
            try? FileManager.default.removeItem(at: home)
        }
        let before = files(home)
        // bash's hook isn't here: nothing is written.
        #expect(RemoteCompletionHook.parse(try run(RemoteCompletionHook.installScript, home: home.path, shell: "/bin/bash", input: nonce)) == .otherShell("bash"))
        #expect(files(home) == before)
        // No nonce: nothing.
        #expect(RemoteCompletionHook.parse(try run(RemoteCompletionHook.installScript, home: home.path, input: "")) == .failed("no nonce"))
        #expect(files(home) == before)
        // A folder that can't be written: a failure, and nothing left.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.appendingPathComponent(".cache/next-term").path)
        let report = RemoteCompletionHook.parse(try run(RemoteCompletionHook.installScript, home: home.path, input: nonce))
        if case .failed = report {} else { Issue.record("expected a failure, got \(String(describing: report))") }
        #expect(files(home) == before)
    }

    @Test func startHandsZshTheHookAndAnyShellItsOwnStart() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A stand-in "zsh" that prints what it was started with.
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("zsh")
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$1\" \"${ZDOTDIR-unset}\" \"${NEXTTERM_USER_ZDOTDIR-unset}\"\n".write(to: fake, atomically: true, encoding: .utf8)
        chmod(fake.path, 0o755)
        let folder = home.appendingPathComponent(".cache/next-term/completion")
        _ = try run(RemoteCompletionHook.installScript, home: home.path, input: nonce)
        let start = folder.appendingPathComponent("start").path
        let hooked = try run("exec \(RemoteShell.quote(start))", home: home.path, shell: fake.path)
        #expect(hooked == "-l|\(folder.path)/zsh|\n")
        // Without the hook's files, the login shell starts as before.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("completion.zsh"))
        #expect(try run("exec \(RemoteShell.quote(start))", home: home.path, shell: fake.path) == "-l|unset|unset\n")
    }

    @Test func tabScriptsStartTheHookOnlyWhereItIsAllowed() {
        let plain = RemoteShell.tabScript(keep: .off, directory: "~", session: "s", tabID: "t")
        let hooked = RemoteShell.tabScript(keep: .off, directory: "~", session: "s", tabID: "t", completionHook: true)
        #expect(!plain.contains("completion/start") && hooked.contains("completion\"/start ] && exec"))
        // The login shell as before when the hook's files are gone.
        #expect(hooked.hasSuffix(RemoteShell.plainShell(nil)))
        let tmux = RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t", completionHook: true)
        #expect(tmux.contains("user-keys[0]") && tmux.contains("bind -n User0 send-keys -l") && tmux.contains("completion/start\"'"))
        #expect(!RemoteShell.tabScript(keep: .tmux, directory: "~", session: "s", tabID: "t").contains("user-keys"))
        // herdr has no hook.
        #expect(!RemoteShell.tabScript(keep: .herdr, directory: "~", session: "s", tabID: "t", completionHook: true).contains("completion"))
    }

    @Test func theServerHookSendsCompletionMarksOnlyAndWaitsForTheRoundTrip() {
        let hook = RemoteCompletionHook.zshenv
        #expect(!hook.contains("@NT_") && hook.contains("__nextterm_cwait=0.6"))
        for mark in ["cmd", "end", "cwd", "jobs"] { #expect(!hook.contains(";\(mark);"), "\(mark)") }
        // The wait rides on a server's Tab key, 150 to 600 ms; a Tab on this Mac carries none.
        let wait = CompletionProtocol.tabKey(id: 7, wait: 0.05)
        #expect(String(decoding: wait, as: UTF8.self).hasSuffix("t000007000004w150"))
        #expect(String(decoding: CompletionProtocol.tabKey(id: 8, wait: 2), as: UTF8.self).hasSuffix("w600"))
        #expect(CompletionProtocol.tabKey(id: 9) == CompletionProtocol.frame(.tab, id: 9))
        // zsh-autocomplete's list as you type rides on the Tab too, after the wait (where an older hook looks for it).
        #expect(String(decoding: CompletionProtocol.tabKey(id: 10, wait: 0.2, quiet: true), as: UTF8.self).hasSuffix("t000010000007w200;q1"))
        #expect(CompletionProtocol.tabKey(id: 11, quiet: false) == CompletionProtocol.frame(.tab, id: 11, fields: ["q0"]))
        #expect(ZshCompletionScript.script.contains("w<150-600>") && ZshCompletionScript.script.contains("Ptmux;"))
        #expect(RemoteCompletionHook.parse("noise\n\(RemoteShell.marker)\nshell\tbash\n") == .otherShell("bash"))
        #expect(RemoteCompletionHook.parse("no marker") == nil)
    }
}
