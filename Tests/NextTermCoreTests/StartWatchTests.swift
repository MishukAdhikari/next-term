import Foundation
import Testing
@testable import NextTermCore

/// The start watch (KTD6, U14): for 5 seconds after an automatic resume's Return, or after the user runs a line the
/// restore put back, the shell's end mark and the agent's session file say whether the agent started. Its verdicts, the
/// one fallback a tab gets, its notes, and the agent's error as a note quotes it. Made-up ids, folders and times.
@Suite struct StartWatchTests {
    static let s = "7ce4a1b2-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
    static let other = "1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9"
    var s: String { Self.s }

    func end(_ status: Int32, after: TimeInterval = 0.4, key: Bool = false) -> StartWatch.End {
        StartWatch.End(status: status, after: after, keyPressed: key)
    }

    func verdict(_ end: StartWatch.End? = nil, file: String? = nil, at elapsed: TimeInterval) -> StartWatch.Verdict {
        StartWatch.verdict(end: end, sessionFile: file, session: s, elapsed: elapsed)
    }

    // MARK: verdicts

    /// Still running at 5 s, or the session file naming the session, is a resume.
    @Test func stillRunningAtFiveSecondsOrTheFileNamingTheSessionIsAResume() {
        #expect(verdict(at: 0) == .watching)
        #expect(verdict(at: 4.9) == .watching)
        #expect(verdict(at: StartWatch.window) == .resumed)
        #expect(verdict(at: 12) == .resumed)
        // The agent's own file names the session: no need to wait the window out, whatever the id's case.
        #expect(verdict(file: s, at: 0.6) == .resumed)
        #expect(verdict(file: s.uppercased(), at: 0.6) == .resumed)
        // An agent with no session file of its own (`file` never read) waits the window out.
        #expect(StartWatch.verdict(end: nil, sessionFile: nil, session: nil, elapsed: 5) == .resumed)
        #expect(StartWatch.verdict(end: nil, sessionFile: s, session: nil, elapsed: 1) == .watching)
    }

    /// AE31: a nonzero end within 5 s, with no key pressed and a status other than 130, is a failed start.
    @Test func ae31ANonzeroEndWithinTheWindowWithNoKeyIsAFailedStart() {
        #expect(verdict(end(1), at: 0.5) == .failedAtStart(status: 1))
        #expect(verdict(end(2, after: StartWatch.window), at: 5.1) == .failedAtStart(status: 2))
        // Killed by a signal other than Ctrl-C's still failed.
        #expect(verdict(end(139, after: 1), at: 1.1) == .failedAtStart(status: 139))
        // The failure counts even when the file named the session before it.
        #expect(verdict(end(1), file: s, at: 0.5) == .failedAtStart(status: 1))
        // Ctrl-C, status 0, or a key pressed first: the tab stays as it is.
        #expect(verdict(end(130), at: 0.5) == .leftAsIs)
        #expect(verdict(end(0), at: 0.5) == .leftAsIs)
        #expect(verdict(end(1, key: true), at: 0.5) == .leftAsIs)
        // An end after the window is an agent that ran it through, then stopped.
        #expect(verdict(end(1, after: 6), at: 6.1) == .resumed)
        for settled in [StartWatch.Verdict.resumed, .failedAtStart(status: 1), .newSession(Self.other), .leftAsIs] {
            #expect(settled.settled, "\(settled)")
        }
        #expect(!StartWatch.Verdict.watching.settled)
        #expect(StartWatch.Verdict.failedAtStart(status: 1).failed)
        #expect(!StartWatch.Verdict.newSession(Self.other).failed && !StartWatch.Verdict.leftAsIs.failed)
    }

    /// The session file naming another id is a new session, once the window is out: a file read as the agent starts may
    /// still change to the session it loads.
    @Test func theFileNamingAnotherIdIsANewSession() {
        #expect(verdict(file: Self.other, at: 1) == .watching)
        #expect(verdict(file: Self.other, at: StartWatch.window) == .newSession(Self.other))
        // It named another id, then the session: a resume.
        var watch = StartWatch.Watch(session: s, since: 100)
        watch.read(sessionFile: Self.other)
        #expect(watch.verdict(at: 101) == .watching)
        watch.read(sessionFile: s)
        #expect(watch.verdict(at: 101.5) == .resumed)
        // A read that finds no file keeps the last one read.
        watch.read(sessionFile: nil)
        #expect(watch.sessionFile == s)
    }

    /// The watch keeps what came before the end: a key pressed after it, a second end, or a file read after it changes
    /// nothing.
    @Test func aWatchKeepsWhatCameBeforeTheEnd() {
        var watch = StartWatch.Watch(session: s, since: 100)
        #expect(watch.verdict(at: 100.2) == .watching)
        watch.ended(status: 1, at: 100.4)
        watch.key()
        watch.ended(status: 0, at: 100.6)
        watch.read(sessionFile: Self.other)
        #expect(watch.end?.status == 1 && watch.end?.keyPressed == false && watch.sessionFile == nil)
        #expect(abs((watch.end?.after ?? 0) - 0.4) < 0.000_1)
        #expect(watch.verdict(at: 101) == .failedAtStart(status: 1))
        // A key before the end: the user took over, and the tab stays as it is.
        var typed = StartWatch.Watch(session: s, since: 100)
        typed.key()
        typed.ended(status: 1, at: 100.4)
        #expect(typed.verdict(at: 100.5) == .leftAsIs)
    }

    /// The tab's writes into its shell since the Return are the user's: one before the end is a key pressed, and the
    /// fallback after a failed start types only onto a line nothing reached since the Return. A key pressed between the
    /// end mark and the verdict, which the watch no longer counts, still takes the line, so the plain form is never typed
    /// onto the user's own.
    @Test func aWriteSinceTheReturnTakesTheFallbacksLine() {
        var watch = StartWatch.Watch(session: s, since: 100, writes: 7)
        watch.wrote(7)
        watch.ended(status: 1, at: 100.4)
        watch.wrote(8)
        #expect(watch.end?.keyPressed == false && watch.verdict(at: 100.45) == .failedAtStart(status: 1))
        #expect(watch.line.taken(userTyped: false, writes: 8))
        #expect(!watch.line.taken(userTyped: false, writes: 7))
        // A write before the end: the user took over, and the tab stays as it is.
        var typed = StartWatch.Watch(session: s, since: 100, writes: 7)
        typed.wrote(8)
        typed.ended(status: 1, at: 100.4)
        #expect(typed.end?.keyPressed == true && typed.verdict(at: 100.5) == .leftAsIs)
    }

    // MARK: the fallback and its notes

    /// Claude's record after `claude --permission-mode bypassPermissions` with exact id S from its session file.
    func claude(_ options: [[String]], launcher: SessionSnapshot.Launcher? = nil) -> SessionSnapshot.Evidence {
        SessionSnapshot.Evidence(agent: .claude, sessionID: s, source: .sessionFile, sessionFolder: "/Users/x/app",
                                 options: options.map { SessionSnapshot.LaunchOption($0) }, launcher: launcher)
    }

    let rejected = "error: unknown option '--permission-mode'"

    /// AE31: an automatic resume carrying `--permission-mode` that a later Claude rejects puts `claude --resume S` back on
    /// the line once, and the note quotes Claude's error and names what the plain form left off. A second failure gives
    /// the first sentence only.
    @Test func ae31AFailedStartPutsThePlainResumeBackOnceWithTheAgentsError() {
        let start = StartWatch.Start(evidence: claude([["--permission-mode", "bypassPermissions"]]), session: s, line: nil)
        #expect(start.plain == "claude --resume \(s)" && start.dropped == ["--permission-mode"])
        let first = StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: false, error: rejected)
        #expect(first == .putBack(line: "claude --resume \(s)", note: "claude exited at once (status 1): “\(rejected)”. "
            + "The plain resume is back on the line. Left off: --permission-mode."))
        let second = StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: true, error: rejected)
        #expect(second == .note("claude exited at once (status 1): “\(rejected)”."))
        // Ctrl-C, status 0, a key pressed first, a resume: nothing changes.
        for verdict in [StartWatch.Verdict.leftAsIs, .resumed, .watching] {
            #expect(StartWatch.step(verdict, start: start, fallbackUsed: false, error: rejected) == .nothing, "\(verdict)")
        }
    }

    /// The architecture's example: a put-back line rebuilt from argv, every option it carried named, an unknown one too.
    @Test func aFailedPutBackLineNamesEveryOptionThePlainFormDropped() {
        let evidence = claude([["--foo"], ["--dangerously-skip-permissions"]])
        let line = "claude --foo --dangerously-skip-permissions --resume \(s)"
        #expect(evidence.putBack(id: s, folder: evidence.sessionFolder)?.line == line)
        let start = StartWatch.Start(evidence: evidence, session: s, line: line)
        let step = StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: false, error: "error: unknown option '--foo'")
        #expect(step == .putBack(line: "claude --resume \(s)", note: "claude exited at once (status 1): “error: unknown option '--foo'”. "
            + "The plain resume is back on the line. Left off: --foo, --dangerously-skip-permissions."))
        // An option the line left off, its value not told from a prompt's, was never on it: the plain form drops nothing
        // of it, and its first note named it.
        let unclear = SessionSnapshot.Evidence(agent: .claude, sessionID: s, source: .sessionFile,
                                               options: [SessionSnapshot.LaunchOption(["--newflag"], unclear: true)])
        #expect(StartWatch.Start(evidence: unclear, session: s, line: "claude --resume \(s)").dropped.isEmpty)
    }

    /// AE31 with a launcher (KTD6, KTD7): a put-back line that replays the user's launcher falls back to that launcher
    /// with the resume form alone, so an alias that sets a store (`cw`, with CLAUDE_CONFIG_DIR in it) still finds the
    /// session. The options typed after it are dropped and named; the launcher's own come back with it. An automatic
    /// resume runs the recorded program, so its fallback is the program's plain form. A launcher typed bare is the next
    /// test's.
    @Test func ae31AFailedLauncherLineFallsBackToTheLauncherWithTheResumeFormAlone() {
        let cw = claude([["--permission-mode", "bypassPermissions"]], launcher: SessionSnapshot.Launcher(word: "cw", typed: 1))
        let line = "cw --permission-mode bypassPermissions --resume \(s)"
        #expect(cw.putBack(id: s, folder: cw.sessionFolder)?.line == line)
        let start = StartWatch.Start(evidence: cw, session: s, line: line)
        #expect(start.plain == "cw --resume \(s)" && start.dropped == ["--permission-mode"])
        let first = StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: false, error: rejected)
        #expect(first == .putBack(line: "cw --resume \(s)", note: "claude exited at once (status 1): “\(rejected)”. "
            + "The plain resume is back on the line. Left off: --permission-mode."))
        #expect(StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: true, error: rejected)
            == .note("claude exited at once (status 1): “\(rejected)”."))
        // The launcher's own options come back with it: only those typed after it are dropped. A path launcher too.
        let held = claude([["--dangerously-skip-permissions"], ["--model", "opus"]],
                          launcher: SessionSnapshot.Launcher(word: "/Users/x/bin/cad", typed: 1))
        let heldLine = "/Users/x/bin/cad --model opus --resume \(s)"
        #expect(held.putBack(id: s, folder: held.sessionFolder)?.line == heldLine)
        let typed = StartWatch.Start(evidence: held, session: s, line: heldLine)
        #expect(typed.plain == "/Users/x/bin/cad --resume \(s)" && typed.dropped == ["--model"])
        // An automatic resume of the same record: the program's plain form, every option it carried named.
        let automatic = StartWatch.Start(evidence: cw, session: s, line: nil)
        #expect(automatic.plain == "claude --resume \(s)" && automatic.dropped == ["--permission-mode"])
        // A line that starts with the program, not the launcher, did not replay it: the program's plain form.
        let rebuilt = StartWatch.Start(evidence: cw, session: s, line: "claude --permission-mode bypassPermissions --resume \(s)")
        #expect(rebuilt.plain == "claude --resume \(s)")
    }

    /// AE31 with a launcher typed bare (KTD6): `claude-auto-danger --resume S` is the launcher's resume form alone, so
    /// the launcher's plain form is the line that failed. The fallback is the program's plain form, once, and the note
    /// names the alias's own options as left off, from the record, or says "the options in" the alias when the record
    /// shows none. If the program's form fails too, the note alone.
    @Test func ae31AFailedBareLauncherLineFallsBackToTheProgramsPlainFormOnce() {
        let bare = SessionSnapshot.Launcher(word: "claude-auto-danger", typed: 0)
        let alias = claude([["--dangerously-skip-permissions"], ["--model", "opus"]], launcher: bare)
        let line = "claude-auto-danger --resume \(s)"
        #expect(alias.putBack(id: s, folder: alias.sessionFolder)?.line == line)
        let start = StartWatch.Start(evidence: alias, session: s, line: line)
        #expect(start.plain == "claude --resume \(s)" && start.dropped == ["--dangerously-skip-permissions", "--model"])
        #expect(start.bypassedLauncher == "claude-auto-danger")
        let first = StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: false, error: rejected)
        #expect(first == .putBack(line: "claude --resume \(s)", note: "claude exited at once (status 1): “\(rejected)”. "
            + "The plain resume is back on the line. Left off: --dangerously-skip-permissions, --model (from claude-auto-danger)."))
        // Each tab gets one fallback: a tab that had it gets the note alone.
        #expect(StartWatch.step(.failedAtStart(status: 1), start: start, fallbackUsed: true, error: rejected)
            == .note("claude exited at once (status 1): “\(rejected)”."))
        // The program's plain form, run in turn, fails too: it replays no launcher, and the tab had its fallback, so the
        // note alone.
        let after = StartWatch.Start(evidence: alias, session: s, line: "claude --resume \(s)")
        #expect(after.plain == "claude --resume \(s)" && after.bypassedLauncher == nil)
        #expect(StartWatch.step(.failedAtStart(status: 1), start: after, fallbackUsed: true, error: "No conversation found")
            == .note("claude exited at once (status 1): “No conversation found”."))
        // A record that does not show the alias's own options, unknown or none: the note says "the options in" it.
        for options in [nil, [SessionSnapshot.LaunchOption]()] {
            let unshown = SessionSnapshot.Evidence(agent: .claude, sessionID: s, source: .sessionFile, sessionFolder: "/Users/x/app",
                                                   options: options, launcher: bare)
            let replayed = StartWatch.Start(evidence: unshown, session: s, line: line)
            #expect(replayed.plain == "claude --resume \(s)" && replayed.dropped.isEmpty, "\(String(describing: options))")
            #expect(StartWatch.step(.failedAtStart(status: 1), start: replayed, fallbackUsed: false, error: nil)
                == .putBack(line: "claude --resume \(s)", note: "claude exited at once (status 1). The plain resume is back on the line. "
                    + "Left off: the options in claude-auto-danger."), "\(String(describing: options))")
        }
        // An alias named for the program: its plain form is the line that failed, which would expand it again, so the
        // note alone.
        let named = claude([["--dangerously-skip-permissions"]], launcher: SessionSnapshot.Launcher(word: "claude", typed: 0))
        let same = StartWatch.Start(evidence: named, session: s, line: "claude --resume \(s)")
        #expect(same.plain == "claude --resume \(s)")
        #expect(StartWatch.step(.failedAtStart(status: 1), start: same, fallbackUsed: false, error: nil)
            == .note("claude exited at once (status 1)."))
        // A launcher with options typed after it still falls back to itself, its own options kept.
        let typed = claude([["--dangerously-skip-permissions"], ["--model", "opus"]],
                           launcher: SessionSnapshot.Launcher(word: "claude-auto-danger", typed: 1))
        let typedStart = StartWatch.Start(evidence: typed, session: s, line: "claude-auto-danger --model opus --resume \(s)")
        #expect(typedStart.plain == line && typedStart.dropped == ["--model"] && typedStart.bypassedLauncher == nil)
    }

    /// The plain form is what failed, or no session is named: there is nothing to fall back to, so the note alone.
    @Test func aPlainFormThatFailedGetsTheNoteAlone() {
        let plain = StartWatch.Start(evidence: claude([]), session: s, line: "claude --resume \(s)")
        #expect(plain.dropped.isEmpty)
        #expect(StartWatch.step(.failedAtStart(status: 1), start: plain, fallbackUsed: false, error: "No conversation found")
            == .note("claude exited at once (status 1): “No conversation found”."))
        let unnamed = StartWatch.Start(evidence: claude([["--model", "opus"]]), session: nil, line: "claude --model opus")
        #expect(unnamed.plain == nil)
        #expect(StartWatch.step(.failedAtStart(status: 1), start: unnamed, fallbackUsed: false, error: nil)
            == .note("claude exited at once (status 1)."))
        // An automatic resume with no option still gets the plain form once: it differs from what ran.
        let bare = StartWatch.Start(evidence: claude([]), session: s, line: nil)
        #expect(StartWatch.step(.failedAtStart(status: 1), start: bare, fallbackUsed: false, error: nil)
            == .putBack(line: "claude --resume \(s)", note: "claude exited at once (status 1). The plain resume is back on the line."))
    }

    /// Codex's plain form is its resume form after the program, with the session's folder; Gemini's names its session.
    @Test func eachAgentsPlainFormIsItsResumeFormAlone() {
        let codex = SessionSnapshot.Evidence(agent: .codex, sessionID: s, source: .openRollout, sessionFolder: "/Users/x/app",
                                             options: [SessionSnapshot.LaunchOption(["--yolo"])])
        let start = StartWatch.Start(evidence: codex, session: s, line: nil)
        #expect(start.plain == "codex resume \(s) -C /Users/x/app" && start.dropped == ["--yolo"])
        let step = StartWatch.step(.failedAtStart(status: 2), start: start, fallbackUsed: false, error: "error: unexpected argument '--yolo' found")
        #expect(step == .putBack(line: "codex resume \(s) -C /Users/x/app", note: "codex exited at once (status 2): "
            + "“error: unexpected argument '--yolo' found”. The plain resume is back on the line. Left off: --yolo."))
        let gemini = SessionSnapshot.Evidence(agent: .gemini, options: [SessionSnapshot.LaunchOption(["--approval-mode=yolo"])])
        let line = "gemini --approval-mode=yolo --resume \(s)"
        let put = StartWatch.Start(evidence: gemini, session: s, line: line)
        #expect(put.plain == "gemini --resume \(s)" && put.dropped == ["--approval-mode"])
    }

    /// The session file naming another id: the note says the agent started a new session.
    @Test func aNewSessionGetsANote() {
        let start = StartWatch.Start(evidence: claude([]), session: s, line: nil)
        #expect(StartWatch.step(.newSession(Self.other), start: start, fallbackUsed: false, error: nil)
            == .note("Claude Code started a new session instead of resuming session \(s)."))
        let qwen = StartWatch.Start(evidence: SessionSnapshot.Evidence(agent: .qwen, sessionID: s, source: .runtimeFile), session: s, line: nil)
        #expect(StartWatch.step(.newSession(Self.other), start: qwen, fallbackUsed: true, error: nil)
            == .note("Qwen Code started a new session instead of resuming session \(s)."))
    }

    // MARK: the error

    /// The agent's error as a note quotes it: the first line that says "error", else its last line; masked, one line of
    /// printable text, at most `quoteLimit` characters.
    @Test func theErrorIsTheLineThatSaysSoMaskedAndShort() {
        #expect(StartWatch.error(in: ["", "error: unknown option '--foo'", "(Did you mean --food?)", ""]) == "error: unknown option '--foo'")
        // clap's usage after the error is not it.
        let clap = ["error: unexpected argument '--foo' found", "", "  tip: to pass '--foo' as a value, use '-- --foo'", "",
                    "Usage: codex resume [OPTIONS] [SESSION_ID] [PROMPT]", "", "For more information, try '--help'."]
        #expect(StartWatch.error(in: clap) == "error: unexpected argument '--foo' found")
        // Saying nothing of an error: its last line.
        #expect(StartWatch.error(in: ["Loading…", "No conversation found with session ID: x", "   "]) == "No conversation found with session ID: x")
        #expect(StartWatch.error(in: []) == nil && StartWatch.error(in: ["", "  "]) == nil)
        // A secret in it is masked; control characters and sequences go.
        let secret = StartWatch.error(in: ["error: token 4fJk2Lq9ZxWv7Rt3Yh8Np1Bm6Cd0Es5Gu was refused"]) ?? ""
        #expect(secret.contains("•••") && !secret.contains("4fJk2Lq9"))
        let hostile = StartWatch.error(in: ["error: \u{1B}]52;c;aGk=\u{07}bad\u{1B}[201~ \u{202E}flag"]) ?? ""
        #expect(!hostile.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in scalar.value < 0x20 || scalar.value == 0x202E })
        #expect(hostile.hasPrefix("error: "))
        // A long one is cut.
        let long = StartWatch.error(in: ["error: " + String(repeating: "no such file ", count: 30)]) ?? ""
        #expect(long.count == StartWatch.quoteLimit && long.hasSuffix("…"))
    }
}
