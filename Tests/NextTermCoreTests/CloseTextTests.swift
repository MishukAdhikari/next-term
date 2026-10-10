import Foundation
import Testing
@testable import NextTermCore

/// What the close and quit alerts say, from the same plans the hangup follows.
struct CloseTextTests {
    @Test func namesAsTheAlertsShowThem() {
        #expect(TabProcessTree.displayName(command: "node", arguments: ["next-server (v16.4.0)", "", ""]) == "next-server")
        #expect(TabProcessTree.displayName(command: "node", arguments: ["npm run dev agent"]) == "npm")
        #expect(TabProcessTree.displayName(command: "node", arguments: ["node", "/opt/homebrew/bin/claude", "--resume"]) == "claude")
        #expect(TabProcessTree.displayName(command: "node", arguments: ["node", "--inspect", "server.js"]) == "node")
        #expect(TabProcessTree.displayName(command: "Python", arguments: ["/Library/Frameworks/Python.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python", "manage.py", "runserver"]) == "manage.py")
        #expect(TabProcessTree.displayName(command: "zsh", arguments: ["-zsh"]) == "zsh")
        #expect(TabProcessTree.displayName(command: "claude", arguments: ["claude"]) == "claude")
        #expect(TabProcessTree.displayName(command: "vite", arguments: []) == "vite")
        #expect(TabProcessTree.displayName(command: "sleep", arguments: ["", ""]) == "sleep")
    }

    static func note(_ tab: String, _ program: String?) -> CloseNote {
        TabProcessTree.closeNote(Suite.plan(tab), running: true, program: program)
    }

    @Test func theAgentAndTheServerItStartedAreNamed() {
        let note = Self.note("H", "“claude”")
        #expect(note.stops == ["“claude” (running)", "“next-server” (started by “claude”)"])
        #expect(note.keeps.isEmpty)
    }

    @Test func aProgramIgnoringSIGHUPIsSaidToKeepRunning() {
        let note = Self.note("B", "“python3 ntmark-hupign.py”")
        #expect(note.stops.isEmpty)
        #expect(note.keeps == ["“python3 ntmark-hupign.py”"])
    }

    @Test func plainProgramsAsBefore() {
        #expect(Self.note("A", "“npm run dev”").stops == ["“npm run dev” (running)"])
        #expect(Self.note("K", "“node ntmark-hupnode.js”").stops == ["“node ntmark-hupnode.js” (running)"])
        #expect(Self.note("G", "“sh -c 'python3 ntmark-setpgid.py & wait'”").stops
                == ["“sh -c 'python3 ntmark-setpgid.py & wait'” (running)", "“ntmark-setpgid.py” (started by “sh”)"])
        #expect(TabProcessTree.closeNote(.none, running: true, program: nil).stops == ["a running process"])
        #expect(TabProcessTree.closeNote(.none, running: false, program: "“x”").isEmpty)
    }

    @Test func theQuitAlert() {
        let text = CloseText.text(lead: "Quitting stops", notes: [Self.note("H", "“claude”"), Self.note("B", "“python3 ntmark-hupign.py”")])
        #expect(text == "Quitting stops “claude” (running), “next-server” (started by “claude”). “python3 ntmark-hupign.py” keeps running: it ignores hangups.")
    }

    @Test func manyTabsAndManyNames() {
        let notes = (1...6).map { CloseNote(stops: ["“job \($0)” (running)"]) }
        #expect(CloseText.text(lead: "Quitting stops", notes: notes)
                == "Quitting stops “job 1” (running); “job 2” (running); “job 3” (running); “job 4” (running); and more in 2 other tabs.")
        let two = CloseText.text(lead: "This stops", notes: [CloseNote(keeps: ["“a”"]), CloseNote(keeps: ["“b”"])])
        #expect(two == "“a” and “b” keep running: they ignore hangups.")
        let window = CloseText.text(lead: "Closing the window’s last tab closes the window and stops", notes: [Self.note("B", "“py”")],
                                    otherwise: "Closing the window’s last tab closes the window.")
        #expect(window == "Closing the window’s last tab closes the window. “py” keeps running: it ignores hangups.")

        // Several servers from one agent: the first three by name.
        var snapshot = Suite.snapshot
        for (i, name) in ["vite", "next-server", "storybook", "tsc", "vite"].enumerated() {
            let pid = Int32(810 + i)
            snapshot.append(Suite.p(pid, parent: 801, group: pid, tty: Suite.noTTY, name))
        }
        let busy = TabProcessTree.closeNote(Suite.plan("H", in: snapshot), running: true, program: "“claude”")
        #expect(busy.stops == ["“claude” (running)", "“next-server”, “vite”, “storybook” and 1 more (started by “claude”)"])
    }
}
