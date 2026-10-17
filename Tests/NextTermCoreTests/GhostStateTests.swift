import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostStateTests {
    typealias Report = GhostProtocol.BufferReport

    func report(_ buffer: String?, line: Int = 1, gen: Int, cursor: Int? = nil, keymap: String = "main", context: String = "start",
                post: String? = "", region: Bool = false, isearch: Bool = false) -> Report {
        Report(line: line, gen: gen, cursor: cursor ?? buffer?.unicodeScalars.count ?? 0, keymap: keymap, context: context, buffer: buffer,
               postdisplay: post, region: region, isearch: isearch)
    }

    /// A state at line 1 with a key of yours pressed on it.
    func keyed() -> GhostState {
        var state = GhostState()
        _ = state.report(report("", gen: 1), gates: GhostGates())
        state.userKey()
        return state
    }

    @Test func aReportAsksWithItsGeneration() {
        var state = keyed()
        let step1 = state.report(report("git ch", gen: 7), gates: GhostGates())
        #expect(step1 == .ask(gen: 7, prefix: "git ch"))
        let step2 = state.answer(gen: 7, command: "git checkout main")
        #expect(step2 && state.shown?.remainder == "eckout main")
    }

    @Test func anAnswerForAnOlderGenerationIsDropped() {
        var state = keyed()
        _ = state.report(report("git c", gen: 7), gates: GhostGates())
        _ = state.report(report("git ch", gen: 8), gates: GhostGates())
        let step3 = state.answer(gen: 7, command: "git checkout main")
        #expect(!step3 && state.shown == nil)
        let step4 = state.answer(gen: 8, command: "git checkout main")
        #expect(step4)
        // No match: nothing shows.
        _ = state.report(report("git chx", gen: 9), gates: GhostGates())
        let step5 = state.answer(gen: 9, command: nil)
        #expect(!step5 && state.shown == nil)
    }

    @Test func typingThroughTrimsWithoutAsking() {
        var state = keyed()
        _ = state.report(report("git ch", gen: 2), gates: GhostGates())
        _ = state.answer(gen: 2, command: "git cherry-pick abc")
        let step6 = state.report(report("git che", gen: 3), gates: GhostGates())
        #expect(step6 == .trimmed && state.shown?.remainder == "rry-pick abc")
        // A character it doesn't go on with hides it and asks for the new line.
        let step7 = state.report(report("git chec", gen: 4), gates: GhostGates())
        #expect(step7 == .ask(gen: 4, prefix: "git chec") && state.shown == nil)
        // The same line again (a cursor round trip): it stays.
        _ = state.answer(gen: 4, command: "git checkout main")
        let step8 = state.report(report("git chec", gen: 5), gates: GhostGates())
        #expect(step8 == .none && state.shown != nil)
    }

    @Test func aDeletionHidesUntilTheNextInsertion() {
        var state = keyed()
        _ = state.report(report("git ch", gen: 2), gates: GhostGates())
        _ = state.answer(gen: 2, command: "git checkout main")
        let step9 = state.report(report("git c", gen: 3), gates: GhostGates())
        #expect(step9 == .hidden && state.deletedSinceInsert)
        let step10 = state.report(report("git", gen: 4), gates: GhostGates())
        #expect(step10 == .none)
        let step11 = state.report(report("git", gen: 5, cursor: 1), gates: GhostGates())
        #expect(step11 == .none)
        let step12 = state.report(report("gitx", gen: 6), gates: GhostGates())
        #expect(step12 == .ask(gen: 6, prefix: "gitx") && !state.deletedSinceInsert)
    }

    @Test func escHidesForTheRestOfTheLine() {
        var state = keyed()
        _ = state.report(report("git ch", gen: 2), gates: GhostGates())
        _ = state.answer(gen: 2, command: "git checkout main")
        state.escape()
        let step13 = state.report(report("git che", gen: 3), gates: GhostGates())
        #expect(state.shown == nil && step13 == .none)
        // A new line: suggestions again, after a key of yours.
        _ = state.report(report("", line: 2, gen: 4), gates: GhostGates())
        let step14 = state.report(report("git", line: 2, gen: 5), gates: GhostGates())
        #expect(step14 == .none)
        state.userKey()
        let step15 = state.report(report("git c", line: 2, gen: 6), gates: GhostGates())
        #expect(step15 == .ask(gen: 6, prefix: "git c"))
    }

    @Test func whereNothingShows() {
        let hidden: [Report] = [
            report("git ch", gen: 2, cursor: 3),
            report("git ch", gen: 2, context: "cont"),
            report("git ch", gen: 2, keymap: "vicmd"),
            report("git ch", gen: 2, region: true),
            report("git ch", gen: 2, isearch: true),
            report("git ch", gen: 2, post: "eckout main"),
            report("git ch", gen: 2, post: nil),
            report(nil, gen: 2, cursor: 3000),
            report("   ", gen: 2),
        ]
        for line in hidden {
            var state = keyed()
            let step16 = state.report(line, gates: GhostGates())
            #expect(step16 == .none, "\(line)")
        }
        // In vi insert mode it shows.
        var vi = keyed()
        let step17 = vi.report(report("git", gen: 2, keymap: "viins"), gates: GhostGates())
        #expect(step17 == .ask(gen: 2, prefix: "git"))
        // Each gate closed hides it.
        let closed = [GhostGates(on: false), GhostGates(shellAlone: false), GhostGates(viewReady: false), GhostGates(noTabList: false),
                      GhostGates(focused: false), GhostGates(notDriven: false), GhostGates(noPlugin: false)]
        for gates in closed {
            var state = keyed()
            _ = state.report(report("git ch", gen: 2), gates: GhostGates())
            _ = state.answer(gen: 2, command: "git checkout main")
            let step18 = state.report(report("git che", gen: 3), gates: gates)
            #expect(step18 == .hidden, "\(gates)")
        }
        // No key of yours on this line (an agent's text, a restored line): nothing.
        var untouched = GhostState()
        _ = untouched.report(report("", gen: 1), gates: GhostGates())
        let step19 = untouched.report(report("git ch", gen: 2), gates: GhostGates())
        #expect(step19 == .none)
    }

    // MARK: keys

    @Test func theKeysSendWhatSwiftTermSends() {
        #expect(GhostKeys.bytes(.right, applicationCursor: false, optionAsMeta: false) == [0x1B, 0x5B, 0x43])
        #expect(GhostKeys.bytes(.right, applicationCursor: true, optionAsMeta: false) == [0x1B, 0x4F, 0x43])
        #expect(GhostKeys.bytes(.end, applicationCursor: false, optionAsMeta: false) == [0x1B, 0x5B, 0x46])
        #expect(GhostKeys.bytes(.end, applicationCursor: true, optionAsMeta: false) == [0x1B, 0x4F, 0x46])
        #expect(GhostKeys.bytes(.ctrlE, applicationCursor: true, optionAsMeta: true) == [0x05])
        #expect(GhostKeys.bytes(.ctrlF, applicationCursor: false, optionAsMeta: false) == [0x06])
        #expect(GhostKeys.bytes(.optionRight, applicationCursor: false, optionAsMeta: true) == Array("\u{1b}[1;3C".utf8))
        #expect(GhostKeys.bytes(.optionRight, applicationCursor: false, optionAsMeta: false).isEmpty)
    }

    /// A state showing `git checkout main` after `git ch`, in `keymap`.
    func showing(keymap: String = "emacs") -> GhostState {
        var state = keyed()
        _ = state.report(report("git ch", gen: 12, keymap: keymap), gates: GhostGates())
        _ = state.answer(gen: 12, command: "git checkout main")
        return state
    }

    @Test func whichKeysAreTaken() {
        let emacs = showing()
        #expect([.right, .end, .ctrlE, .ctrlF, .optionRight, .escape].allSatisfy { emacs.takes($0) } && !emacs.escapeGoesOn)
        let vi = showing(keymap: "viins")
        #expect(!vi.takes(.ctrlE) && !vi.takes(.ctrlF) && vi.takes(.right) && vi.takes(.end) && vi.escapeGoesOn)
        // Nothing showing: nothing taken.
        var none = keyed()
        _ = none.report(report("git ch", gen: 3), gates: GhostGates())
        #expect(!none.takes(.right))
        #expect(none.accept(.right, bytes: [0x1B, 0x5B, 0x43]) == nil)
    }

    @Test func acceptingAllSendsTheWholeCommand() {
        var state = showing()
        let frame = state.accept(.right, bytes: [0x1B, 0x5B, 0x43])
        let expected = GhostProtocol.acceptFrame(gen: 12, seen: "git ch", new: "git checkout main", key: [0x1B, 0x5B, 0x43])
        #expect(frame != nil && frame == expected && state.shown == nil)
        // The shell's report of the whole line asks again (a longer command may start with it).
        let step = state.report(report("git checkout main", gen: 13), gates: GhostGates())
        #expect(step == .ask(gen: 13, prefix: "git checkout main"))
    }

    @Test func acceptingAWordKeepsTheRest() {
        var state = showing()
        let frame = state.accept(.optionRight, bytes: [])
        #expect(frame == GhostProtocol.acceptFrame(gen: 12, seen: "git ch", new: "git checkout", key: []))
        // The shell's report of the longer line trims it, with no ask; ⌥→ again takes the rest.
        let step = state.report(report("git checkout", gen: 13), gates: GhostGates())
        #expect(step == .trimmed && state.shown?.remainder == " main")
        #expect(state.accept(.optionRight, bytes: []) == GhostProtocol.acceptFrame(gen: 13, seen: "git checkout", new: "git checkout main", key: []))
    }

    /// Smart case: the line takes the command's own case.
    @Test func acceptingTakesTheCommandsCase() {
        var state = keyed()
        _ = state.report(report("cd ~/code", gen: 2), gates: GhostGates())
        _ = state.answer(gen: 2, command: "cd ~/Code/next-term")
        #expect(state.accept(.end, bytes: [0x1B, 0x5B, 0x46]) == GhostProtocol.acceptFrame(gen: 2, seen: "cd ~/code", new: "cd ~/Code/next-term",
                                                                                           key: [0x1B, 0x5B, 0x46]))
    }
}
