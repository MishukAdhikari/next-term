import AppKit
import NextTermCore
import ObjectiveC
import SwiftTerm

/// Terminals draw only while someone can see them: a spinner draws as it prints in a window in front, a spinner in
/// a hidden app is parsed but not drawn, and once the app shows again its terminal is drawn whole, with what it
/// printed meanwhile.
extension SelfTest {
    static func drawingChecks(_ c: TerminalWindowController) async {
        let dir = canonicalPath(NSTemporaryDirectory())
        let w = AppDelegate.shared.openWindow(directory: dir)
        defer {
            if NSApp.isHidden { NSApp.unhide(nil) }
            w.window?.close()
            c.window?.makeKeyAndOrderFront(nil)
        }
        guard let window = w.window, await bringToFront(window), let tab = w.tabs.first else {
            return note("skipped 'a hidden terminal draws nothing': " + (w.window.map(notFrontmost) ?? "no window"))
        }
        let view = tab.view
        guard await wait(15, { tab.status.integrated }) else { return check(false, "drawing: the shell starts") }
        DrawCounter.install()

        // A spinner, ten frames a second for 9 s, then a last line: "spin-done-42" is printed, never typed.
        view.send(txt: "for i in {1..90}; do printf '\\rspin %d ' $i; sleep 0.1; done; echo; echo spin-done-$((6*7))\r")
        func spin() -> Int? {
            tab.screenTail(3).compactMap { line in line.hasPrefix("spin ") ? Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) : nil }.last
        }
        guard await wait(5, { (spin() ?? 0) >= 5 }) else { return check(false, "drawing: the spinner runs", tab.screenTail(3).joined(separator: " | ")) }
        DrawCounter.reset(view)
        await pause(1)
        let shownDraws = DrawCounter.count(view)
        check(shownDraws >= 5, "a terminal in a window in front draws as its program prints", "\(shownDraws) draws in 1 s at 10 frames a second")

        // Hidden: still parsed (the spinner's count goes on), never drawn.
        NSApp.hide(nil)
        let hid = await wait(3) { !window.canBeSeen }
        await pause(0.3) // a draw already under way when it hid
        DrawCounter.reset(view)
        let before = (spin: spin() ?? 0, undrawn: view.undrawnChanges)
        await pause(3)
        let hiddenDraws = DrawCounter.count(view)
        let after = (spin: spin() ?? 0, undrawn: view.undrawnChanges)
        check(hid && hiddenDraws == 0 && after.spin > before.spin && after.undrawn > before.undrawn,
              "a terminal in a hidden app draws nothing for 3 s while its program prints",
              "hidden \(hid), \(hiddenDraws) draws, spinner \(before.spin) -> \(after.spin), \(after.undrawn - before.undrawn) changes not drawn")
        let finished = await wait(10) { tab.screenTail(4).contains("spin-done-42") }

        // Shown again: drawn whole, once, with what it printed while hidden.
        DrawCounter.reset(view)
        NSApp.unhide(nil)
        _ = await bringToFront(window)
        let drew = await wait(3) { DrawCounter.count(view) > 0 }
        await pause(0.5)
        let area = DrawCounter.area(view) ?? .zero
        let whole = area.insetBy(dx: -1, dy: -1).contains(view.visibleRect)
        check(finished && drew && whole && tab.screenTail(4).contains("spin-done-42"),
              "shown again, the terminal is drawn whole with what it printed while hidden",
              "finished \(finished), \(DrawCounter.count(view)) draws covering \(NSStringFromRect(area)) of \(NSStringFromRect(view.visibleRect))")
    }
}

/// Counts SwiftTerm's draw calls per terminal view, for the checks above. TerminalView.draw(_:) is public but not
/// open, so NextTermView cannot override it: the count swaps in an implementation that counts and then calls
/// SwiftTerm's. Installed once, for the rest of the self-test run.
@MainActor enum DrawCounter {
    private static var installed = false
    private static var counts: [ObjectIdentifier: Int] = [:]
    private static var areas: [ObjectIdentifier: NSRect] = [:]

    static func install() {
        guard !installed, let method = class_getInstanceMethod(TerminalView.self, #selector(NSView.draw(_:))) else { return }
        installed = true
        typealias Draw = @convention(c) (NSView, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
        let counting: @convention(block) (NSView, NSRect) -> Void = { view, rect in
            MainActor.assumeIsolated {
                let id = ObjectIdentifier(view)
                counts[id, default: 0] += 1
                areas[id] = areas[id].map { $0.union(rect) } ?? rect
            }
            original(view, #selector(NSView.draw(_:)), rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
    }

    static func reset(_ view: NSView) {
        counts[ObjectIdentifier(view)] = 0
        areas[ObjectIdentifier(view)] = nil
    }

    static func count(_ view: NSView) -> Int { counts[ObjectIdentifier(view)] ?? 0 }

    /// What the draws since the last reset covered, in the view's coordinates.
    static func area(_ view: NSView) -> NSRect? { areas[ObjectIdentifier(view)] }
}
