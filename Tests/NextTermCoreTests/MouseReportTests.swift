import Foundation
import Testing
@testable import NextTermCore

/// Right and middle clicks for a program that reads the mouse (herdr's menus, tmux, vim), as xterm reports them.
@Suite struct MouseReportTests {
    func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(Array(text.utf8)) }
    func text(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

    @Test func appKitsRightAndMiddleAreXtermsTwoAndOne() {
        #expect(MouseReport.xtermButton(appKit: 1) == 2)
        #expect(MouseReport.xtermButton(appKit: 2) == 1)
        // The left button is SwiftTerm's own; back and forward are not reported.
        #expect(MouseReport.xtermButton(appKit: 0) == nil)
        #expect(MouseReport.xtermButton(appKit: 3) == nil)
        #expect(MouseReport.xtermButton(appKit: 4) == nil)
    }

    @Test func eachModeReportsWhatXtermReports() {
        let modes: [MouseReport.Tracking] = [.off, .x10, .normal, .buttonMotion, .anyMotion]
        // X10 (DECSET 9): presses only. 1000: presses and releases. 1002 and 1003: drags too.
        #expect(modes.map { MouseReport.reports(.press, $0, pressReported: false) } == [false, true, true, true, true])
        #expect(modes.map { MouseReport.reports(.release, $0, pressReported: true) } == [false, false, true, true, true])
        #expect(modes.map { MouseReport.reports(.drag, $0, pressReported: true) } == [false, false, false, true, true])
        // Never a release or a drag for a press the program didn't get.
        let orphans = modes.filter { MouseReport.reports(.release, $0, pressReported: false) || MouseReport.reports(.drag, $0, pressReported: false) }
        #expect(orphans.isEmpty)
    }

    @Test func aPointIsACellAndTopLeftPixelsClampedToTheView() {
        // An 800 × 400 view of 100 × 25 cells, 8 × 16 each; AppKit's y grows upwards.
        func at(_ x: Double, _ y: Double) -> [Int] {
            let hit = MouseReport.position(x: x, y: y, width: 800, height: 400, cellWidth: 8, cellHeight: 16, cols: 100, rows: 25)
            return [hit.col, hit.row, hit.pixelX, hit.pixelY]
        }
        #expect(at(20, 360) == [2, 2, 20, 40])
        #expect(at(0, 400) == [0, 0, 0, 0])
        // Past the right edge, above the view, below it, left of it: the nearest cell, the edge's pixel.
        #expect(at(900, 200) == [99, 12, 800, 200])
        #expect(at(20, 450) == [2, 0, 20, 0])
        #expect(at(20, -5) == [2, 24, 20, 400])
        #expect(at(-3, 200) == [0, 12, 0, 200])
        // A grid not laid out yet: no division by zero, cell 0.
        let empty = MouseReport.position(x: 5, y: 5, width: 0, height: 0, cellWidth: 0, cellHeight: 0, cols: 0, rows: 0)
        #expect(empty.col == 0 && empty.row == 0)
    }

    @Test func anSGRReleaseNamesItsButtonAgain() {
        // SwiftTerm 1.20 sends every SGR release with the button bits cleared, which reads as the left button.
        #expect(text(MouseReport.sgrRelease(bytes("\u{1b}[<0;5;7m"), button: 2)) == "\u{1b}[<2;5;7m")
        #expect(text(MouseReport.sgrRelease(bytes("\u{1b}[<0;120;45m"), button: 1)) == "\u{1b}[<1;120;45m")
        // The modifier bits stay: Control (16) on a middle release.
        #expect(text(MouseReport.sgrRelease(bytes("\u{1b}[<16;5;7m"), button: 1)) == "\u{1b}[<17;5;7m")
        // SGR-pixel (1016) releases look the same.
        #expect(text(MouseReport.sgrRelease(bytes("\u{1b}[<8;640;212m"), button: 2)) == "\u{1b}[<10;640;212m")
    }

    @Test func anythingButAnSGRReleaseIsLeftAlone() {
        for unchanged in [
            "\u{1b}[<2;5;7M", // a press
            "\u{1b}[<34;5;7M", // a drag
            "\u{1b}[M#%'", // X10's release says 3 by design
            "\u{1b}[35;5;7M", // urxvt
            "\u{1b}[<3;5;7m", // button bits already set
            "\u{1b}[<0;5;7", // cut
            "\u{1b}[<0;5m", // too short
            "\u{1b}[<x;5;7m", // not a number
            "hello world",
        ] {
            #expect(text(MouseReport.sgrRelease(bytes(unchanged), button: 2)) == unchanged, "\(unchanged.debugDescription)")
        }
    }
}
