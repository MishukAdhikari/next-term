import AppKit
import NextTermCore
import SwiftTerm

/// Right and middle clicks for a program that reads the mouse: herdr's tab and pane menus, tmux, vim, mc. SwiftTerm
/// 1.20's view has no rightMouse or otherMouse handlers and reports only the left button, so a right-click always
/// showed Next Term's menu there and a middle-click did nothing. SwiftTerm 1.99 does all this itself: remove this file
/// (and NextTermView's overrides) with that upgrade.
///
/// Next Term keeps the click when the program hasn't asked for the mouse, and when Shift is held (as SwiftTerm does
/// for the left button and the wheel, unless the program took Shift with XTSHIFTESCAPE) or ⌘ (no report carries it,
/// and it is how links open). Control-click is AppKit's right-click: menu(for:) gets it first, so it always opens Next
/// Term's menu.
extension NextTermView {
    /// SwiftTerm's mouse mode in MouseReport's words (its own tests of the mode are internal to it).
    var mouseTracking: MouseReport.Tracking {
        switch getTerminal().mouseMode {
        case .off: return .off
        case .x10: return .x10
        case .vt200: return .normal
        case .buttonEventTracking: return .buttonMotion
        case .anyEvent: return .anyMotion
        }
    }

    /// The cell SwiftTerm draws and hit-tests the left button with (its cellDimension is internal): getOptimalFrameSize
    /// is that cell times the grid, plus the scroller SwiftTerm reserves (1.20 never hides it). Not the font's advance
    /// snapped again: SwiftTerm snapped it at the scale of the screen the font was set on, which may not be this one.
    var cellSize: CGSize {
        let terminal = getTerminal()
        let frame = getOptimalFrameSize()
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let width = max(1, (frame.width - scroller) / CGFloat(max(terminal.cols, 1)))
        return CGSize(width: width, height: frame.height / CGFloat(max(terminal.rows, 1)))
    }

    /// The program takes this right or middle click: it reads the mouse, the tab still takes input (a shell, or a herdr
    /// tab's ssh, can end with the mouse mode still on, and then nothing reads the report), this tab passes the buttons
    /// on, and neither Shift (unless the program took it) nor ⌘ keeps the click for Next Term.
    func programTakes(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard allowMouseReporting, acceptsInput, terminal.mouseMode != .off, passesOtherButtons() else { return false }
        let flags = event.modifierFlags
        if flags.contains(.shift), !terminal.mouseShiftCapture { return false }
        return !flags.contains(.command)
    }

    /// AppKit's number for the event's button: 1 for a right-button event, whatever it carries.
    private func appKitButton(_ event: NSEvent) -> Int {
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
        default: return event.buttonNumber
        }
    }

    /// Reports a right or middle button's press, drag or release to the program. True: the event was the program's
    /// (sent, or eaten because its press went to the program); false: Next Term's own handling goes on (super).
    func reportOther(_ event: NSEvent, _ phase: MouseReport.Phase) -> Bool {
        guard let button = MouseReport.xtermButton(appKit: appKitButton(event)) else { return false }
        switch phase {
        case .press:
            guard programTakes(event) else { return false }
            pressedForProgram.insert(button)
            // As a left click does, and as Next Term's menu did (it shows the tab): this pane takes the keyboard.
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        case .drag:
            // A press the program never saw (Next Term's menu, or the click that chose an agent's tab): not its drag.
            guard pressedForProgram.contains(button) else { return false }
        case .release:
            guard pressedForProgram.remove(button) != nil else { return false }
        }
        // The mode may have changed since the press (or is X10, presses only): what it doesn't report is eaten.
        guard MouseReport.reports(phase, mouseTracking, pressReported: true) else { return true }
        report(button: button, phase, event)
        return true
    }

    private func report(button: Int, _ phase: MouseReport.Phase, _ event: NSEvent) {
        let terminal = getTerminal()
        let point = convert(event.locationInWindow, from: nil)
        let cell = cellSize
        let at = MouseReport.position(x: Double(point.x), y: Double(point.y),
                                      width: Double(bounds.width), height: Double(bounds.height),
                                      cellWidth: Double(cell.width), cellHeight: Double(cell.height),
                                      cols: terminal.cols, rows: terminal.rows)
        let flags = event.modifierFlags
        let code = terminal.encodeButton(button: button, release: phase == .release, shift: flags.contains(.shift),
                                         meta: flags.contains(.option), control: flags.contains(.control))
        switch phase {
        case .press:
            terminal.sendEvent(buttonFlags: code, x: at.col, y: at.row, pixelX: at.pixelX, pixelY: at.pixelY)
        case .drag:
            terminal.sendMotion(buttonFlags: code, x: at.col, y: at.row, pixelX: at.pixelX, pixelY: at.pixelY)
        case .release:
            // send(source: Terminal) runs inside this call and puts the button back into an SGR release.
            releasing = button
            defer { releasing = nil }
            terminal.sendEvent(buttonFlags: code, x: at.col, y: at.row, pixelX: at.pixelX, pixelY: at.pixelY)
        }
    }
}
