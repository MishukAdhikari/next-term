import AppKit
import NextTermCore
import SwiftTerm

/// Right and middle clicks reach a program that reads the mouse (herdr's menus, tmux, vim), as xterm reports them, and
/// stay Next Term's when it doesn't, or with Shift or ⌘ held. A stand-in program turns SGR reporting on and keeps every
/// byte it reads in a file; the clicks are NSEvents given to the terminal view, which is what AppKit does with them.
extension SelfTest {
    static func mouseReportChecks(_ c: TerminalWindowController) async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-mouse-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appendingPathComponent("received").path
        let reader = folder.appendingPathComponent("reader")
        // 1000 (presses and releases), 1002 (drags), 1006 (SGR); raw input, every byte into the file as it comes, until
        // Ctrl-C, which turns reporting off again.
        let program = """
            #!/bin/sh
            trap 'printf "\\033[?1002l\\033[?1000l\\033[?1006l"; stty sane; exit 0' INT TERM
            stty -icanon -echo min 1 time 0
            printf '\\033[?1000h\\033[?1002h\\033[?1006h'
            echo MOUSE-READY
            dd bs=1 of="$1" 2>/dev/null
            """
        try? program.write(to: reader, atomically: true, encoding: .utf8)
        chmod(reader.path, 0o755)

        let tab = c.addTab(directory: folder.path)
        defer { c.remove(tab) }
        _ = await wait(20) { tab.status.integrated }
        let view = tab.view
        check(view.passesOtherButtons(), "mouse: a tab on this Mac passes right and middle clicks to a program that reads the mouse")
        let plainClick = otherButtonEvent(.rightMouseDown, button: 1, cell: (4, 2), in: view)
        check(plainClick.map { !view.programTakes($0) } == true, "mouse: with no program reading the mouse, a right-click stays Next Term's menu")
        tab.view.send(txt: "\(ShellQuote.quote(reader.path)) \(ShellQuote.quote(kept))\r")
        guard await wait(10, { view.getTerminal().mouseMode == .buttonEventTracking && FileManager.default.fileExists(atPath: kept) }) else {
            return check(false, "mouse: the stand-in program turns mouse reporting on", tab.screenTail(4).joined(separator: " | "))
        }
        func received() -> String { (try? String(contentsOfFile: kept, encoding: .isoLatin1)) ?? "" }
        /// A right (`right`) or middle click at `cell`, dragged to `to` when given, as AppKit hands one to the view.
        func click(right: Bool, at cell: (col: Int, row: Int), drag to: (col: Int, row: Int)? = nil, flags: NSEvent.ModifierFlags = []) {
            let button = right ? 1 : 2
            if let event = otherButtonEvent(right ? .rightMouseDown : .otherMouseDown, button: button, cell: cell, in: view, flags: flags) {
                if right { view.rightMouseDown(with: event) } else { view.otherMouseDown(with: event) }
            }
            if let to, let event = otherButtonEvent(right ? .rightMouseDragged : .otherMouseDragged, button: button, cell: to, in: view, flags: flags) {
                if right { view.rightMouseDragged(with: event) } else { view.otherMouseDragged(with: event) }
            }
            if let event = otherButtonEvent(right ? .rightMouseUp : .otherMouseUp, button: button, cell: to ?? cell, in: view, flags: flags) {
                if right { view.rightMouseUp(with: event) } else { view.otherMouseUp(with: event) }
            }
        }

        // A right-click on column 5, row 3 (SGR counts from 1): button 2, and its release names it too.
        click(right: true, at: (4, 2))
        check(await wait(5) { received().contains("\u{1b}[<2;5;3M\u{1b}[<2;5;3m") },
              "mouse: a right-click reaches the program as button 2, press and release", received().debugDescription)
        // A middle-drag: button 1, its motion (32 added), its release where it ended.
        click(right: false, at: (1, 0), drag: (3, 0))
        check(await wait(5) { received().contains("\u{1b}[<1;2;1M\u{1b}[<33;4;1M\u{1b}[<1;4;1m") },
              "mouse: a middle-drag reaches it as button 1, with its motion and release", received().debugDescription)
        // Control (16) and Option (8) go with the click; the release keeps them and the button.
        click(right: true, at: (0, 0), flags: [.control])
        click(right: true, at: (0, 1), flags: [.option])
        check(await wait(5) { received().contains("\u{1b}[<18;1;1M\u{1b}[<18;1;1m") && received().contains("\u{1b}[<10;1;2M\u{1b}[<10;1;2m") },
              "mouse: Control and Option go with a right-click, and with its release", received().debugDescription)
        // Shift (the program hasn't taken it with XTSHIFTESCAPE) and ⌘ keep the click for Next Term; back and forward
        // buttons are not reported.
        let shift = otherButtonEvent(.rightMouseDown, button: 1, cell: (4, 2), in: view, flags: [.shift])
        let command = otherButtonEvent(.rightMouseDown, button: 1, cell: (4, 2), in: view, flags: [.command])
        let plain = otherButtonEvent(.rightMouseDown, button: 1, cell: (4, 2), in: view)
        let shiftTaken: Bool = shift.map(view.programTakes) ?? true
        let commandTaken: Bool = command.map(view.programTakes) ?? true
        let plainTaken: Bool = plain.map(view.programTakes) ?? false
        check(!shiftTaken && !commandTaken && plainTaken, "mouse: Shift-right-click and ⌘-right-click stay Next Term's menu")
        let before = received()
        if let back = otherButtonEvent(.otherMouseDown, button: 3, cell: (2, 2), in: view), let up = otherButtonEvent(.otherMouseUp, button: 3, cell: (2, 2), in: view) {
            view.otherMouseDown(with: back)
            view.otherMouseUp(with: up)
        }
        await pause(0.5)
        check(received() == before, "mouse: the back button is not reported", received().debugDescription)
        // A tab that keeps right and middle clicks (one Next Term's own tmux keeps) gives the program none.
        let passes = view.passesOtherButtons
        view.passesOtherButtons = { false }
        check(plain.map(view.programTakes) == false, "mouse: a tab that keeps the buttons gives the program no right-click")
        view.passesOtherButtons = passes

        // The program ends: reporting is off, and a right-click is Next Term's menu again.
        view.send(txt: "\u{3}")
        check(await wait(5) { view.getTerminal().mouseMode == .off }, "mouse: the program turns reporting off when it ends")
        let menu: NSMenu? = plain.flatMap(view.menu(for:))
        let takenAfter: Bool = plain.map(view.programTakes) ?? true
        check(!takenAfter && menu?.items.isEmpty == false, "mouse: then a right-click shows Next Term's menu again")
        check(view.pressedForProgram.isEmpty, "mouse: no button is left held for the program", "\(view.pressedForProgram)")
    }

    /// A right or other mouse button's event at the middle of `cell` (column, row from the top) of `view`. AppKit's
    /// NSEvent.mouseEvent gives every event button 0, so the button goes in through its CGEvent; a window number of 0
    /// keeps the location as given.
    static func otherButtonEvent(_ type: NSEvent.EventType, button: Int, cell: (col: Int, row: Int), in view: NextTermView,
                                 flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        let size = view.cellSize
        let point = NSPoint(x: (CGFloat(cell.col) + 0.5) * size.width, y: view.bounds.height - (CGFloat(cell.row) + 0.5) * size.height)
        let location = view.convert(point, to: nil)
        guard let made = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let event = made.cgEvent else { return nil }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return NSEvent(cgEvent: event)
    }
}
