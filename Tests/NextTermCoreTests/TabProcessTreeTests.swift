import Foundation
import Testing
@testable import NextTermCore

/// The orphan suite's tabs (scripts/orphan-check.sh) but L, which only records signal dispositions, as one
/// snapshot of the kernel's process list taken while they all run: each tab has its own terminal and shell. Pids
/// are made up and readable: tab A's shell is 100 and what runs in it 101..., tab B's shell 200, and so on. The
/// names are the ones the alerts show.
enum Suite {
    static let noTTY = ProcessRecord.noTerminal
    static func p(_ pid: Int32, parent: Int32, group: Int32, tty: Int32, _ name: String, ignores: Bool = false,
                  stopped: Bool = false, started: UInt64 = 1) -> ProcessRecord {
        ProcessRecord(pid: pid, parent: parent, group: group, terminal: tty, started: started, ignoresHangup: ignores,
                      stopped: stopped, name: name)
    }
    static func shell(_ pid: Int32, tty: Int32) -> ProcessRecord { p(pid, parent: 50, group: pid, tty: tty, "zsh") }

    static let snapshot: [ProcessRecord] = [
        p(1, parent: 0, group: 1, tty: noTTY, "launchd"),
        p(50, parent: 1, group: 50, tty: noTTY, "NextTerm"),
        p(60, parent: 1, group: 60, tty: noTTY, "tmux"), // a tmux server: double-forked to launchd
        // A: npm run dev → next dev → next-server, all in the job's group.
        shell(100, tty: 3),
        p(101, parent: 100, group: 101, tty: 3, "npm"),
        p(102, parent: 101, group: 101, tty: 3, "next"),
        p(103, parent: 102, group: 101, tty: 3, "next-server"),
        // B: python ignoring SIGHUP, in front.
        shell(200, tty: 4),
        p(201, parent: 200, group: 201, tty: 4, "ntmark-hupign.py", ignores: true),
        // C: two background jobs, the shell at its prompt.
        shell(300, tty: 5),
        p(301, parent: 300, group: 301, tty: 5, "next-server"),
        p(302, parent: 300, group: 302, tty: 5, "sleep"),
        // D: nohup'd jobs (Node undoes nohup, sleep does not).
        shell(400, tty: 6),
        p(401, parent: 400, group: 401, tty: 6, "next-server"),
        p(402, parent: 400, group: 402, tty: 6, "sleep", ignores: true),
        // E: sleep & disown.
        shell(500, tty: 7),
        p(501, parent: 500, group: 501, tty: 7, "sleep"),
        // F: ( sleep & ) and ( node … & ): double-forked, now launchd's.
        shell(600, tty: 8),
        p(601, parent: 1, group: 603, tty: 8, "sleep"),
        p(602, parent: 1, group: 604, tty: 8, "next-server"),
        // G: sh -c 'python3 x.py & wait', the python moved itself into a group of its own.
        shell(700, tty: 9),
        p(701, parent: 700, group: 701, tty: 9, "sh"),
        p(702, parent: 701, group: 702, tty: 9, "ntmark-setpgid.py"),
        // H: an agent in front; its tool ran npm run dev in a session of its own, with no terminal.
        shell(800, tty: 10),
        p(801, parent: 800, group: 801, tty: 10, "claude"),
        p(802, parent: 801, group: 802, tty: noTTY, "npm"),
        p(803, parent: 802, group: 802, tty: noTTY, "next"),
        p(804, parent: 803, group: 802, tty: noTTY, "next-server"),
        // I: the same, an agent that ends its tools itself on SIGHUP.
        shell(900, tty: 11),
        p(901, parent: 900, group: 901, tty: 11, "claude"),
        p(902, parent: 901, group: 902, tty: noTTY, "npm"),
        p(903, parent: 902, group: 902, tty: noTTY, "next"),
        p(904, parent: 903, group: 902, tty: noTTY, "next-server"),
        // J: sleep stopped with ^Z: the shell has the terminal back.
        shell(1000, tty: 12),
        p(1001, parent: 1000, group: 1001, tty: 12, "sleep", stopped: true),
        // K: node with a SIGHUP handler that does nothing (it catches, it does not ignore).
        shell(1100, tty: 13),
        p(1101, parent: 1100, group: 1101, tty: 13, "ntmark-hupnode.js"),
        // M: GNU screen attached in front. Its server is the client's child in a session of its own with no
        // terminal (as an agent's tool is), and its window runs login → zsh on a terminal of its own, with a
        // disowned sleep.
        shell(1300, tty: 15),
        p(1301, parent: 1300, group: 1301, tty: 15, "screen"),
        p(1302, parent: 1301, group: 1302, tty: noTTY, "SCREEN"),
        p(1303, parent: 1302, group: 1303, tty: 20, "login"),
        p(1304, parent: 1303, group: 1304, tty: 20, "zsh"),
        p(1305, parent: 1304, group: 1305, tty: 20, "sleep"),
        // N: `script` in front, its own shell on a terminal of its own, with a disowned sleep.
        shell(1400, tty: 16),
        p(1401, parent: 1400, group: 1401, tty: 16, "script"),
        p(1402, parent: 1401, group: 1402, tty: 21, "zsh"),
        p(1403, parent: 1402, group: 1403, tty: 21, "sleep"),
    ]

    /// Each tab: its shell and the group in front of its terminal (tcgetpgrp).
    static let tabs: [String: (shell: Int32, front: Int32)] = [
        "A": (100, 101), "B": (200, 201), "C": (300, 300), "D": (400, 400), "E": (500, 500), "F": (600, 600),
        "G": (700, 701), "H": (800, 801), "I": (900, 901), "J": (1000, 1000), "K": (1100, 1101),
        "M": (1300, 1301), "N": (1400, 1401),
    ]

    static func plan(_ tab: String, in snapshot: [ProcessRecord] = snapshot) -> HangupPlan {
        let t = tabs[tab]!
        return TabProcessTree.plan(snapshot: snapshot, shell: t.shell, foregroundGroup: t.front)
    }
}

struct TabProcessTreeTests {
    @Test func aJobInFrontIsHungUpAsAGroup() {
        let plan = Suite.plan("A")
        #expect(plan.groups == [101])
        #expect(plan.targets.map(\.pid) == [101, 102, 103])
        #expect(plan.stoppable.map(\.pid) == [101, 102, 103])
        #expect(plan.keepsRunning.isEmpty && plan.startedOutside.isEmpty)
    }

    @Test func aProgramIgnoringSIGHUPIsHungUpButNeverSentSIGTERM() {
        let plan = Suite.plan("B")
        #expect(plan.groups == [201])
        #expect(plan.stoppable.isEmpty)
        #expect(plan.keepsRunning.map(\.pid) == [201])
    }

    /// The shell is never a root: at its prompt nothing is a target, so its background jobs (C, D), a disowned
    /// job (E), a double fork (F) and a stopped job (J) are left to the shell's own hangup, as in every terminal.
    @Test func aShellAtItsPromptAddsNoTargets() {
        for tab in ["C", "D", "E", "F", "J"] {
            let plan = Suite.plan(tab)
            #expect(plan == .none, "tab \(tab)")
        }
    }

    @Test func aChildThatMovedToAGroupOfItsOwnIsHungUpToo() {
        let plan = Suite.plan("G")
        #expect(plan.groups == [701, 702])
        #expect(plan.stoppable.map(\.pid) == [701, 702])
        #expect(plan.startedOutside.map(\.pid) == [702])
    }

    /// The agent case: what its tool started in a session of its own (no terminal) is found through the
    /// parent links, and its whole group is hung up.
    @Test func whatAnAgentStartedOutsideTheTerminalIsHungUp() {
        for (tab, base) in [("H", Int32(800)), ("I", Int32(900))] {
            let plan = Suite.plan(tab)
            #expect(plan.groups == [base + 1, base + 2], "tab \(tab)")
            #expect(plan.stoppable.map(\.pid) == [base + 1, base + 2, base + 3, base + 4], "tab \(tab)")
            #expect(plan.startedOutside.map(\.pid) == [base + 2, base + 3, base + 4], "tab \(tab)")
            #expect(plan.foreground.map(\.pid) == [base + 1], "tab \(tab)")
        }
    }

    @Test func aProgramCatchingSIGHUPGetsSIGTERMLater() {
        let plan = Suite.plan("K")
        #expect(plan.groups == [1101])
        #expect(plan.stoppable.map(\.pid) == [1101])
    }

    /// A terminal of its own below the tab (GNU screen's windows, `script`, an editor's :terminal) is that
    /// terminal's business, as before 0.10.2: the program in front is hung up, its pty closing hangs up what runs
    /// there, and screen's server, which holds such a terminal from a session of its own, keeps its session.
    @Test func aTerminalOfItsOwnBelowTheTabIsLeftToItsOwnHangup() {
        let screen = Suite.plan("M")
        #expect(screen.groups == [1301])
        #expect(screen.targets.map(\.pid) == [1301])
        #expect(screen.startedOutside.isEmpty)
        let script = Suite.plan("N")
        #expect(script.groups == [1401])
        #expect(script.targets.map(\.pid) == [1401])
    }

    /// The trade-off: a tool command an agent runs on a pty of its own (node-pty) is not walked into, but its
    /// tool's session is still hung up as a group, the pty's host with it, and the pty's closing ends the rest.
    @Test func anAgentToolOnAPtyOfItsOwnIsHungUpThroughItsSession() {
        let snapshot = Suite.snapshot + [
            Suite.shell(1500, tty: 17),
            Suite.p(1501, parent: 1500, group: 1501, tty: 17, "claude"),
            Suite.p(1502, parent: 1501, group: 1502, tty: Suite.noTTY, "bash"),
            Suite.p(1503, parent: 1502, group: 1502, tty: Suite.noTTY, "script"),
            Suite.p(1504, parent: 1503, group: 1504, tty: 22, "npm"),
            Suite.p(1505, parent: 1504, group: 1504, tty: 22, "next-server"),
        ]
        let plan = TabProcessTree.plan(snapshot: snapshot, shell: 1500, foregroundGroup: 1501)
        #expect(plan.groups == [1501, 1502])
        #expect(plan.targets.map(\.pid) == [1501, 1502, 1503])
    }

    @Test func aRemoteTabHasNoTargets() {
        let plan = TabProcessTree.plan(snapshot: Suite.snapshot, shell: 800, foregroundGroup: 801, remote: true)
        #expect(plan == .none)
    }

    /// Only this tab's tree: never another tab's processes, never a daemon that double-forked to launchd, never
    /// the shell's group, never launchd's.
    @Test func otherTabsAndDaemonsAreNeverTargets() {
        var all: Set<Int32> = []
        for tab in Suite.tabs.keys {
            let plan = Suite.plan(tab)
            let shell = Suite.tabs[tab]!.shell
            let mine = Set(Suite.snapshot.filter { $0.terminal == Int32(shell / 100 + 2) || $0.terminal == ProcessRecord.noTerminal }.map(\.pid))
            #expect(plan.targets.allSatisfy { mine.contains($0.pid) }, "tab \(tab)")
            #expect(!plan.groups.contains(shell) && !plan.groups.contains(1), "tab \(tab)")
            let pids = Set(plan.targets.map(\.pid))
            #expect(all.isDisjoint(with: pids), "tab \(tab)")
            all.formUnion(pids)
        }
        #expect(!all.contains(60) && !all.contains(50) && !all.contains(1))
    }

    /// A group the terminal names but the snapshot lacks (it ended in between) is left alone.
    @Test func aForegroundGroupMissingFromTheSnapshotIsLeftAlone() {
        let snapshot = Suite.snapshot.filter { $0.group != 101 }
        #expect(Suite.plan("A", in: snapshot) == .none)
        // And a group id that is not on this terminal (reused by something else) is not taken for the front.
        #expect(TabProcessTree.plan(snapshot: Suite.snapshot, shell: 100, foregroundGroup: 201) == .none)
    }

    /// An interactive shell run in the tab (`bash`, `nix develop`) is at its own prompt: its disowned jobs stay,
    /// as the tab's own shell's do. Only its group is hung up, and it hangs up its jobs itself.
    @Test func aNestedShellAtItsPromptKeepsItsDisownedJobs() {
        let snapshot = Suite.snapshot + [
            Suite.shell(1200, tty: 14),
            Suite.p(1201, parent: 1200, group: 1201, tty: 14, "bash"),
            Suite.p(1202, parent: 1201, group: 1202, tty: 14, "sleep"),
        ]
        let nested = TabProcessTree.plan(snapshot: snapshot, shell: 1200, foregroundGroup: 1201, interactiveShells: [1201])
        #expect(nested.groups == [1201])
        let script = TabProcessTree.plan(snapshot: snapshot, shell: 1200, foregroundGroup: 1201)
        #expect(script.groups == [1201, 1202])
    }

    /// A stopped process outside the front gets SIGCONT after the hangup, so the hangup arrives.
    @Test func aStoppedGroupIsContinuedAfterTheHangup() {
        let snapshot = Suite.snapshot.map { $0.pid == 803 ? Suite.p(803, parent: 802, group: 802, tty: Suite.noTTY, "next", stopped: true) : $0 }
        let plan = Suite.plan("H", in: snapshot)
        #expect(plan.stoppedGroups == [802])
        #expect(Suite.plan("A").stoppedGroups.isEmpty)
    }

    /// SIGTERM after the grace goes only to a target still alive as the same process (same start time), and
    /// never to one that ignores SIGHUP.
    @Test func sigtermGoesOnlyToTheSameProcessesStillAlive() {
        let waiting = [
            Suite.p(10, parent: 1, group: 10, tty: 3, "gone", started: 5),
            Suite.p(11, parent: 1, group: 10, tty: 3, "alive", started: 6),
            Suite.p(12, parent: 1, group: 10, tty: 3, "reused", started: 7),
            Suite.p(13, parent: 1, group: 10, tty: 3, "nohup", started: 8),
        ]
        let now: [Int32: ProcessRecord] = [
            11: Suite.p(11, parent: 1, group: 10, tty: Suite.noTTY, "alive", started: 6),
            12: Suite.p(12, parent: 1, group: 12, tty: Suite.noTTY, "another", started: 70),
            13: Suite.p(13, parent: 1, group: 10, tty: Suite.noTTY, "nohup", ignores: true, started: 8),
        ]
        #expect(TabProcessTree.outlived(waiting, now: { now[$0] }).map(\.pid) == [11])
        // The plan's own list already leaves out what ignored SIGHUP when it was taken.
        #expect(TabProcessTree.outlived(Suite.plan("B").stoppable, now: { _ in Suite.snapshot[4] }).isEmpty)
    }

    /// A tab closed just before Quit still waits for its SIGTERMs off the main thread: Quit takes those waits
    /// over, and one that finished is no longer listed.
    @Test func quitTakesOverTheWaitsOfTabsClosedJustBefore() {
        let pending = PendingHangups()
        let first = [Suite.p(11, parent: 1, group: 11, tty: 3, "next-server", started: 6)]
        let second = [Suite.p(12, parent: 1, group: 12, tty: 4, "ntmark-hupnode.js", started: 7),
                      Suite.p(13, parent: 12, group: 12, tty: 4, "node", started: 8)]
        pending.add(first)
        pending.add(second)
        pending.remove(first)
        // A reused pid (another start time) is another process: its wait stays.
        pending.remove([Suite.p(12, parent: 1, group: 12, tty: 4, "another", started: 70)])
        #expect(pending.takeAll().map(\.pid) == [12, 13])
        #expect(pending.takeAll().isEmpty)
        // From many threads at once.
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let record = [Suite.p(Int32(1000 + i), parent: 1, group: 1, tty: 3, "x", started: 1)]
            pending.add(record)
            if i % 2 == 0 { pending.remove(record) }
        }
        #expect(pending.takeAll().count == 100)
    }

    @Test func interactiveShells() {
        #expect(TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash"]))
        #expect(TabProcessTree.isInteractiveShell(name: "zsh", arguments: ["-zsh"]))
        #expect(TabProcessTree.isInteractiveShell(name: "zsh", arguments: ["zsh", "-l"]))
        #expect(TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "--login", "-i"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "sh", arguments: ["sh", "-c", "python3 x.py & wait"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "zsh", arguments: ["zsh", "-i", "-c", "make"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "deploy.sh"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "node", arguments: ["node"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "bash", arguments: []))
        // nix develop and nix-shell: an option's value is not a script.
        #expect(TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "--rcfile", "/tmp/nix-shell.Ab12/rc"]))
        #expect(TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "--init-file", "/tmp/x"]))
        #expect(TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "-o", "vi"]))
        #expect(TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "+O", "extglob"]))
        #expect(TabProcessTree.isInteractiveShell(name: "zsh", arguments: ["zsh", "+o", "nomatch", "-l"]))
        #expect(TabProcessTree.isInteractiveShell(name: "fish", arguments: ["fish", "-C", "set -x A 1"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "--rcfile", "f", "-c", "make"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "--rcfile", "f", "deploy.sh"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "-o", "vi", "deploy.sh"]))
        #expect(!TabProcessTree.isInteractiveShell(name: "bash", arguments: ["bash", "-C", "deploy.sh"])) // noclobber
    }
}
