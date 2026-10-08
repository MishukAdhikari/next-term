import Testing
@testable import NextTermCore

@Suite struct CompletionStateTests {
    let engine = CompletionProtocol.Arm()
    let system = CompletionProtocol.Arm(completionSystem: true)

    func scan(_ text: String, inPaste: Bool = false) -> InputScan {
        var paste = inPaste
        return InputScan.scan(Array(text.utf8), inPaste: &paste)
    }

    @Test func enginePathOpensAndAccepts() {
        var s = CompletionState()
        let unknown = s.startTab()
        #expect(unknown == nil) // unknown is Disarmed
        s.armed(engine)
        #expect(s.isArmed)
        let id = s.startTab()
        #expect(id == 1 && s.phase == .pending(id: 1, path: .engine) && s.holding)
        s.answered(1, .open)
        #expect(s.phase == .open(id: 1, path: .engine) && !s.holding && !s.shown)
        // An `open` answer shows nothing until the first `line` for that id.
        s.line(.init(id: 1, left: false, word: "So", unquoted: "So"))
        #expect(s.shown)
        s.closed()
        #expect(s.isArmed && !s.shown)
    }

    @Test func systemPathNeverAnswers() {
        var s = CompletionState()
        s.armed(system)
        let id = s.startTab()!
        #expect(s.path == .completionSystem)
        // Held writes go out at 120 ms, and the Tab stays in flight: no answer is owed on this path.
        let owesAnswer = s.holdExpired(id)
        #expect(owesAnswer == false && !s.holding && s.pendingID == id)
        s.loadingDue(id)
        #expect(s.openID == id && s.shown)
        s.listed(id)
        #expect(s.openID == id && s.shown)
        s.done(id, .native)
        #expect(s.phase == .steppedBack && !s.shown)
    }

    @Test func engineTimeoutStepsBack() {
        var s = CompletionState()
        s.armed(engine)
        let id = s.startTab()!
        let owesAnswer = s.holdExpired(id)
        #expect(owesAnswer) // "native" goes out first
        #expect(s.phase == .steppedBack && !s.holding)
        // A stale answer is ignored.
        s.answered(id, .open)
        #expect(s.phase == .steppedBack)
        // Typing in the word arms it again; so does the next prompt.
        s.input(scan("x"))
        #expect(s.isArmed)
    }

    @Test func doneForTheOpenIDCloses() {
        var s = CompletionState()
        s.armed(engine)
        let id = s.startTab()!
        s.answered(id, .open)
        s.done(id, .native)
        #expect(s.phase == .steppedBack && !s.shown)
        s.armed(engine)
        let next = s.startTab()!
        #expect(next == id + 1)
        s.done(next, .inserted)
        #expect(s.isArmed)
    }

    @Test func returnAndFriendsDisarm() {
        for keys in ["\r", "\n", "\u{3}", "\u{4}", "\u{1a}", "ls\r", "\u{1b}[13u", "\u{1b}[13;2u", "\u{1b}[99;5u"] {
            var s = CompletionState()
            s.armed(engine)
            _ = s.startTab()
            s.answered(1, .open)
            s.input(scan(keys))
            #expect(s.phase == .disarmed, "\(keys.debugDescription) should disarm")
        }
        // Return in the same chunk as letters; Return inside a bracketed paste does not count.
        #expect(scan("abc\r").disarms && scan("abc\r").typesInWord)
        #expect(!scan("\u{1b}[200~a\rb\u{1b}[201~").disarms && scan("\u{1b}[200~a\rb\u{1b}[201~").pasteStarts)
        #expect(!scan("a\rb", inPaste: true).disarms)
        var paste = false
        _ = InputScan.scan(Array("\u{1b}[200~ab".utf8), inPaste: &paste)
        #expect(paste)
        #expect(!InputScan.scan(Array("\r".utf8), inPaste: &paste).disarms)
        _ = InputScan.scan(Array("\u{1b}[201~".utf8), inPaste: &paste)
        #expect(!paste && InputScan.scan(Array("\r".utf8), inPaste: &paste).disarms)
        // Arrows and plain escapes neither disarm nor type.
        #expect(scan("\u{1b}[A\u{1b}OB\u{1b}[1;5C") == InputScan())
        #expect(scan("\u{7f}").typesInWord && scan("é").typesInWord)
        #expect(!scan("\u{1b}[97;5u").disarms) // ^A, kitty-encoded
    }

    @Test func eventsWhileDisarmedAreIgnored() {
        var s = CompletionState()
        s.answered(1, .open)
        s.listed(1)
        s.line(.init(id: 1, left: false))
        s.loadingDue(1)
        s.done(1, .inserted)
        let tab = s.startTab()
        #expect(s.phase == .disarmed && !s.shown && tab == nil)
        // An arm the shell can't take there (vi command mode, a search, no binding) leaves it Disarmed.
        s.armed(CompletionProtocol.Arm(keymap: "vicmd"))
        #expect(s.phase == .disarmed)
        s.armed(CompletionProtocol.Arm(bound: false))
        #expect(s.phase == .disarmed)
        s.armed(CompletionProtocol.Arm(context: "vared"))
        #expect(s.phase == .disarmed)
    }

    @Test func aNewPromptEndsWhateverWasInFlight() {
        var s = CompletionState()
        s.armed(system)
        let id = s.startTab()!
        s.listed(id)
        s.armed(system)
        #expect(s.isArmed && !s.shown)
        s.listed(id) // late chunks for the old id
        #expect(s.isArmed)
        _ = s.startTab()
        s.disarm() // a command started
        #expect(s.phase == .disarmed)
    }

    @Test func lineLeftCloses() {
        var s = CompletionState()
        s.armed(engine)
        let id = s.startTab()!
        s.answered(id, .open)
        s.line(.init(id: id, left: false))
        s.line(.init(id: id + 1, left: true)) // another id: ignored
        #expect(s.shown)
        s.line(.init(id: id, left: true))
        #expect(s.isArmed && !s.shown)
    }

    /// A config key's `arm` (zsh-autocomplete quieted) is the same line: a Tab in flight stays in flight.
    @Test func aQuietChangeKeepsTheLine() {
        var s = CompletionState()
        let autocomplete = CompletionProtocol.Arm(completionSystem: true, plugins: ["autocomplete"])
        s.armed(autocomplete)
        let id = s.startTab()!
        var quieted = autocomplete
        quieted.quieted = true
        #expect(quieted.sameLine(as: autocomplete) && !quieted.sameLine(as: engine) && !quieted.sameLine(as: nil))
        s.update(quieted)
        #expect(s.pendingID == id && s.arm?.quieted == true)
        // A shell replaced forgets what its hook said.
        s.forget()
        #expect(s.arm == nil && s.phase == .disarmed)
    }

    /// A server tab with no hook: the word comes off the screen. Its list shows as soon as it opens, the shell's
    /// own Tab leaves the next Tab to the shell too, and typing or Return start over.
    @Test func screenPathOpensAtOnceAndStepsBack() {
        var s = CompletionState()
        let id = s.startScreenTab()
        #expect(id == 1 && s.phase == .pending(id: 1, path: .screen) && s.holding)
        #expect(s.startScreenTab() == nil) // one in flight
        s.answered(1, .open)
        #expect(s.phase == .open(id: 1, path: .screen) && s.shown && !s.holding)
        #expect(s.startScreenTab() == nil) // a list is open
        s.input(scan("\r"))
        #expect(s.phase == .disarmed && !s.shown)

        let second = s.startScreenTab()!
        s.answered(second, .native)
        #expect(s.phase == .steppedBack && s.startScreenTab() == nil) // the shell's own Tab lists next
        s.input(scan("a"))
        #expect(s.isArmed)
        let third = s.startScreenTab()!
        s.answered(third, .insert)
        #expect(s.isArmed && !s.holding)
        // A server's path never owes the shell an answer when the hold ends.
        let fourth = s.startScreenTab()!
        #expect(s.holdExpired(fourth) == false && s.pendingID == fourth)
    }
}
