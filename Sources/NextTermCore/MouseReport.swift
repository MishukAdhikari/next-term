import Foundation

/// Right and middle clicks for a program that reads the mouse (herdr's menus, tmux, vim with `mouse=a`), as xterm
/// reports them. SwiftTerm 1.20 reports only the left button; 1.99 does all of this itself, so this goes with that
/// upgrade. No AppKit or SwiftTerm here: NextTermView feeds it.
public enum MouseReport {
    /// SwiftTerm's Terminal.MouseMode: DECSET 9, 1000, 1002, 1003.
    public enum Tracking: Sendable { case off, x10, normal, buttonMotion, anyMotion }
    public enum Phase: Sendable { case press, drag, release }

    /// xterm's number for an AppKit button other than the left: right (1) is 2, middle (2) is 1. Back and forward
    /// (3, 4) are not reported, as upstream SwiftTerm does not.
    public static func xtermButton(appKit number: Int) -> Int? {
        switch number {
        case 1: return 2
        case 2: return 1
        default: return nil
        }
    }

    /// X10 reports presses only; 1000 presses and releases; 1002 and 1003 drags too. A drag or a release follows
    /// only a press that went to the program.
    public static func reports(_ phase: Phase, _ tracking: Tracking, pressReported: Bool) -> Bool {
        switch phase {
        case .press: return tracking != .off
        case .release: return pressReported && (tracking == .normal || tracking == .buttonMotion || tracking == .anyMotion)
        case .drag: return pressReported && (tracking == .buttonMotion || tracking == .anyMotion)
        }
    }

    /// The cell (0-based, clamped to the grid; a row of the screen) and the pixel (0-based points from the top left,
    /// clamped to the view) of view point `x`, `y` (origin at the bottom left), as SwiftTerm 1.20's calculateMouseHit
    /// and sharedMouseEvent compute them for the left button, so every button lands on the same cell. Except in a row
    /// SwiftTerm lays out as BiDi (Hebrew or Arabic text): there it reports the logical column and this the visual one
    /// (its mapping is internal); 1.99's own right and middle clicks remove the difference.
    public static func position(x: Double, y: Double, width: Double, height: Double, cellWidth: Double, cellHeight: Double,
                                cols: Int, rows: Int) -> (col: Int, row: Int, pixelX: Int, pixelY: Int) {
        let col = min(max(Int(x / max(cellWidth, 1)), 0), max(cols - 1, 0))
        let row = min(max(Int((height - y) / max(cellHeight, 1)), 0), max(rows - 1, 0))
        let pixelX = Int(min(max(x, 0), width))
        let pixelY = Int(height - min(max(y, 0), height))
        return (col, row, pixelX, pixelY)
    }

    /// SwiftTerm 1.20 sends every SGR release (1006, 1016) as `CSI < Cb ; x ; y m` with Cb's button bits cleared: the
    /// left button's. xterm's SGR release names its button (herdr waits for the right one's), so `button` goes back in.
    /// Anything else (a press, or an X10, UTF-8 or urxvt release, which say 3 by design) comes back unchanged.
    public static func sgrRelease(_ data: ArraySlice<UInt8>, button: Int) -> ArraySlice<UInt8> {
        let bytes = Array(data)
        guard bytes.count >= 9, bytes[0] == 0x1B, bytes[1] == UInt8(ascii: "["), bytes[2] == UInt8(ascii: "<"),
              bytes.last == UInt8(ascii: "m"), let semi = bytes[3...].firstIndex(of: UInt8(ascii: ";")),
              let cb = Int(String(decoding: bytes[3..<semi], as: UTF8.self)), cb & 3 == 0 else { return data }
        let head = Array("\u{1b}[<\(cb | (button & 3))".utf8)
        return ArraySlice(head + bytes[semi...])
    }
}
