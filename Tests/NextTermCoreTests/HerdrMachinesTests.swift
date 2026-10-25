import Foundation
import Testing
@testable import NextTermCore

/// The machines saved in a herdr on this Mac (HerdrMachines), read from a hand-written stand-in of herdr 0.9.5's
/// `machine list --json`: read only, and reached only through that herdr.
@Suite struct HerdrMachinesTests {
    func fixture(_ name: String) throws -> String {
        try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func twoMachinesOneDisabledAndNoSSHTargetKept() throws {
        let machines = try #require(HerdrMachines.parse(try fixture("machine-list-0.9.5.json")))
        #expect(machines == [HerdrMachine(id: "7f3c2a9e41b84d0c9e5a6b1d2c3f4e5a", label: "Build machine", enabled: true),
                             HerdrMachine(id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9", label: "Old box", enabled: false)])
        #expect(HerdrMachines.followedMachines(machines).map(\.label) == ["Build machine"])
    }

    @Test func anEmptyListIsNoneAndAnythingElseIsNotAList() {
        #expect(HerdrMachines.parse("[]") == [])
        #expect(HerdrMachines.parse(#"{"result":{"machines":[{"id":"m1","label":"a","enabled":true,"extra":1}]}}"#)
            == [HerdrMachine(id: "m1", label: "a")])
        #expect(HerdrMachines.parse("No saved SSH machines.") == nil)
        #expect(HerdrMachines.parse(#"{"ok":true}"#) == nil)
        // An id herdr would not give is left out; a machine with no label is named by its id.
        #expect(HerdrMachines.parse(#"[{"id":"m;1","label":"x"},{"id":"m2","label":""}]"#) == [HerdrMachine(id: "m2", label: "m2")])
    }

    @Test func fourEnabledMachinesAreReadInTurnAndAFifthWaits() {
        let five = (1...5).map { HerdrMachine(id: "m\($0)", label: "M\($0)") }
        #expect(HerdrMachines.followedMachines(five).map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect((0..<9).compactMap { HerdrMachines.machine(at: $0, of: five)?.id } == ["m1", "m2", "m3", "m4", "m1", "m2", "m3", "m4", "m1"])
        #expect(HerdrMachines.machine(at: 0, of: [HerdrMachine(id: "m9", label: "x", enabled: false)]) == nil)
    }

    @Test func anAgentOnAMachineHasItsOwnIdAndItsCommandsGoThroughMachine() throws {
        let target = try #require(HerdrTarget.parse("5c0d9a1e-0000-4000-8000-0000000000e1/@7f3c2a9e41b84d0c9e5a6b1d2c3f4e5a/w1:p1"))
        #expect(target.machine == "7f3c2a9e41b84d0c9e5a6b1d2c3f4e5a" && target.pane == "w1:p1")
        let argv = try #require(HerdrCommand.list.argv(executable: "/opt/homebrew/bin/herdr", session: nil, machine: target.machine, text: nil))
        #expect(argv.count == 1 && argv[0][0] == ["/opt/homebrew/bin/herdr", "--machine", "7f3c2a9e41b84d0c9e5a6b1d2c3f4e5a", "agent", "list"])
        // Two machines, the same pane: two agents.
        let one = AgentQueue.Item(target: .machine(tab: "T", machine: "m1", pane: "w1:p1"), key: "machine T m1\u{0}w1:p1", name: "a",
                                  group: "M1 (herdr)", state: .idle, words: "Idle")
        var other = one
        other.target = .machine(tab: "T", machine: "m2", pane: "w1:p1")
        other.key = "machine T m2\u{0}w1:p1"
        #expect(AgentQueue([one, other]).items.count == 2)
        #expect(AgentQueue.onMachine("Build machine") == "Build machine (herdr)")
    }
}
