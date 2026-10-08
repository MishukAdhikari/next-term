import AppKit
import NextTermCore

/// The lines between panes show only where a pane shows on each side of them: the sidebar and the work area,
/// the editor and the terminal (folded to its rail too), a tab's panes. Never over or through a pane.
/// Reported on 0.9.0: with the sidebar on the left and the terminal on the right, a file double-clicked in the
/// sidebar and closed with ⌘W left the editor's line running down through the terminal's tab bar and over its
/// text, where the editor had ended (AppKit kept that divider, in a layer above the panes); once the window
/// was laid out again, down the terminal's edge. The steps are a hand's: a double-click on the file's row, and
/// ⌘W, ⌘J and the sidebar's key pressed through the menus.
extension SelfTest {
    static func dividerLineChecks(_ c: TerminalWindowController, proj: URL, tab: TerminalTab) async {
        guard let window = c.window, let work = c.editorArea.superview as? HairlineSplitView,
              let outer = window.contentView as? HairlineSplitView, let terminal = c.tabBar.superview else {
            return check(false, "lines: the window's split views draw their own lines")
        }
        let app = AppDelegate.shared!
        let area = c.editorArea
        let defaults = UserDefaults.standard
        let saved = (position: app.terminalPosition, side: app.sidebarSide, fraction: defaults.object(forKey: "editorFraction"),
                     width: defaults.object(forKey: "sidebarWidth"), sidebar: c.isSidebarVisible, frame: window.frame)
        func restore(_ key: String, _ value: Any?) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let readme = proj.appendingPathComponent("README.md")
        area.closeAll()
        c.show(tab) // the project's tab: the sidebar lists README.md
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        // The reporter's layout: the sidebar on the left, the terminal on the right, the editor's share 0.3185.
        app.terminalPosition = .right
        app.sidebarSide = .left
        app.editorFraction = 0.3185279187817259
        c.applyLayout()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let byHand = await wait(3) { NSApp.isActive && window.isKeyWindow }
        if !byHand { note("lines: the app is not frontmost, so files open and close through the app's own calls, not a hand's clicks and keys") }
        _ = await wait(5) { c.sidebar.root?.path == canonicalPath(proj.path) }

        /// A hand's clicks and keys reach the window only while the app is in front with the window key: brought
        /// back before each, in case another app took the front meanwhile.
        func front() async -> Bool {
            guard byHand else { return false }
            if !NSApp.isActive || !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return await wait(2) { NSApp.isActive && window.isKeyWindow }
        }
        /// Double-clicked in the sidebar, as the reporter opened it.
        func open() async -> Bool {
            let hand = await front()
            if hand { doubleClickRow(c, readme) }
            if !(await wait(3) { !area.isHidden }) {
                if hand { note("lines: the double-click did not open README.md; opened through the app") }
                c.openFile(readme)
            }
            window.layoutIfNeeded()
            return !area.isHidden
        }
        /// ⌘W, the editor in front: the editor's last file closes and the editor hides.
        func close() async {
            if let view = area.activeTextView { window.makeFirstResponder(view) }
            // ⌘W anywhere else closes a terminal tab: only with the editor in front.
            let hand = await front() && c.isEditorFocused
            if hand { await pressMenuKey("closeTab:", in: window) }
            if !(await wait(3) { area.isHidden }) {
                if hand {
                    note("lines: ⌘W did not close README.md (the keyboard in \(window.firstResponder.map { "\(type(of: $0))" } ?? "nothing")); closed through the app")
                }
                area.closeAll()
            }
            window.layoutIfNeeded()
        }
        /// ⌘J: the terminal folds beside the editor (to its rail, on the right), or unfolds.
        func fold() async {
            let was = c.terminalCollapsed
            if await front() { await pressMenuKey("toggleTerminalCollapsed:", in: window) }
            if !(await wait(2) { c.terminalCollapsed != was }) { c.toggleTerminalCollapsed(nil) }
            window.layoutIfNeeded()
        }
        var shot = false
        /// Whatever draws a line where it must not: over the terminal (its tab bar and terminals, or its rail),
        /// or anywhere not between two panes that show; then, as the window shows it, in the terminal's margins.
        func noStrayLines(_ name: String) async {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            var found = linesOver(terminal) + linesNotBetweenPanes(in: window)
            let seen = await linesOverTerminal(c)
            if !seen.isEmpty { found.append("on screen: \(seen)") }
            check(found.isEmpty, name, found.joined(separator: "; "))
            if !found.isEmpty, !shot {
                shot = true
                await screenshot(c, suffix: "-stray-line")
            }
        }

        // A file open: one line between the editor and the terminal, as the window shows it, and the sidebar's.
        let opened = await open()
        let lines = work.drawnLines
        let between = lines.count == 1 && lines[0].minX == area.frame.maxX && lines[0].maxX == terminal.frame.minX
            && lines[0].height == work.bounds.height
        let colour = lines.first.flatMap { screenColour(window, at: work.convert(NSPoint(x: $0.midX, y: $0.midY), to: nil)) }
        check(opened && between && colour.map { WorkSplitView.line.matches($0) } == true && outer.drawnLines.count == 1,
              "lines: a file open, one line shows between the editor and the terminal, and one beside the sidebar",
              "editor \(area.frame), terminal \(terminal.frame), lines \(lines), on screen \(colour.map { "\($0)" } ?? "none"), sidebar's \(outer.drawnLines)")
        await noStrayLines("lines: none over the terminal while the file is open")

        // The reported steps: closed with ⌘W.
        await close()
        check(area.isHidden && work.drawnLines.isEmpty, "lines: the file closed, the editor hides and its line goes with it", "\(work.drawnLines)")
        await noStrayLines("lines: the file closed with ⌘W, no line is left over the terminal where the editor ended")
        // Laid out again (the window resized), AppKit moved its old divider to the terminal's first column.
        var frame = window.frame
        frame.size.width += 1
        window.setFrame(frame, display: true)
        frame.size.width -= 1
        window.setFrame(frame, display: true)
        await noStrayLines("lines: … nor down the terminal's edge once the window is laid out again")

        // Folded and unfolded first, then closed; and closed while folded to the rail.
        if await open() {
            await fold()
            await fold()
            await close()
            await noStrayLines("lines: folded with ⌘J and back, then closed: none over the terminal")
        }
        if await open() {
            await fold()
            let railed = c.terminalRailed
            let besideRail = work.drawnLines.count == 1 && work.drawnLines[0].maxX == terminal.frame.minX
            check(railed && besideRail, "lines: folded to the rail, its line shows between the editor and the rail",
                  "railed \(railed), lines \(work.drawnLines), rail \(terminal.frame)")
            await close()
            await noStrayLines("lines: closed while folded to the rail: none where the rail was")
        }

        // The terminal on the other sides: the line ran down or across it the same way.
        for position in [AppDelegate.TerminalPosition.left, .bottom, .top] {
            app.terminalPosition = position
            c.applyLayout()
            if await open() {
                check(work.drawnLines.count == 1, "lines: terminal on the \(position.rawValue), a file open: one line between it and the editor",
                      "\(work.drawnLines)")
                await close()
                await noStrayLines("lines: terminal on the \(position.rawValue), the file closed: no line across the terminal")
            }
        }
        app.terminalPosition = .right
        c.applyLayout()

        // The sidebar hidden: its line went with it, not left across the terminal's tab bar and terminals.
        if await front() { await pressMenuKey("toggleProjectSidebar:", in: window) }
        if !(await wait(2) { !c.isSidebarVisible }) { c.toggleProjectSidebar(nil) }
        check(!c.isSidebarVisible && outer.drawnLines.isEmpty, "lines: the sidebar hidden, its line goes with it", "\(outer.drawnLines)")
        await noStrayLines("lines: the sidebar hidden, no line is left over the terminal at its edge")
        if await front() { await pressMenuKey("toggleProjectSidebar:", in: window) }
        if !(await wait(2) { c.isSidebarVisible }) { c.toggleProjectSidebar(nil) }
        window.layoutIfNeeded()
        let sidebarLine = outer.drawnLines
        check(c.isSidebarVisible && sidebarLine.count == 1 && sidebarLine[0].minX == c.sidebar.frame.maxX,
              "lines: shown again, the sidebar's line is back beside it", "\(sidebarLine), sidebar \(c.sidebar.frame)")

        // A tab's panes: a line between them, none while one fills the tab.
        if let group = c.activeGroup, let base = c.activeTab, let new = c.split(vertical: true) {
            _ = await wait(10) { new.status.integrated }
            window.layoutIfNeeded()
            let split = group.paneView(base).superview as? HairlineSplitView
            let left = group.paneView(base).frame, right = group.paneView(new).frame
            let paneLines = split?.drawnLines ?? []
            check(paneLines.count == 1 && paneLines[0].minX == left.maxX && paneLines[0].maxX == right.minX && linesNotBetweenPanes(in: window).isEmpty,
                  "lines: a tab split in two has one line between its panes", "\(paneLines), panes \(left) \(right)")
            c.toggleZoomPane(nil)
            window.layoutIfNeeded()
            let zoomedLines = group.view.subviews.compactMap { $0 as? HairlineSplitView }.flatMap(\.drawnLines)
            check(group.zoomed != nil && zoomedLines.isEmpty && linesOver(terminal).isEmpty, "lines: one pane filling the tab, no line over it",
                  "\(zoomedLines) \(linesOver(terminal))")
            c.toggleZoomPane(nil)
            c.remove(new)
            window.layoutIfNeeded()
            await noStrayLines("lines: its other pane closed, no line is left over the terminal")
        }

        // Back as it was: the frame first (resizing moves the sidebar), then the sizes it saved.
        area.closeAll()
        window.setFrame(saved.frame, display: true)
        app.terminalPosition = saved.position
        app.sidebarSide = saved.side
        if c.isSidebarVisible != saved.sidebar { c.toggleProjectSidebar(nil) }
        restore("sidebarWidth", saved.width)
        c.applyLayout()
        restore("editorFraction", saved.fraction)
        restore("sidebarWidth", saved.width) // laying out saves the width it placed
    }

    /// A menu command's key, pressed as a hand presses it: into the app's event queue, where the main menu
    /// finds it. `command` is its id (as Settings › Keyboard Shortcuts has it), so it is whatever key it has now.
    static func pressMenuKey(_ command: String, in window: NSWindow) async {
        guard let item = KeyboardShortcuts.shared.commands.first(where: { $0.id == command })?.item, !item.keyEquivalent.isEmpty else {
            return note("lines: \(command) has no key")
        }
        let key = item.keyEquivalent
        let codes: [String: UInt16] = ["w": 13, "j": 38, "b": 11]
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: item.keyEquivalentModifierMask,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: codes[key] ?? 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        await pause(0.2)
    }

    /// The split views' lines over `pane` (in it or crossing it), from split views outside it: theirs, and any
    /// divider AppKit draws in a layer of its own with a colour. Lines of split views inside it (its own panes')
    /// are its business; `linesNotBetweenPanes` sees to them.
    static func linesOver(_ pane: NSView) -> [String] {
        guard let window = pane.window, let root = window.contentView?.superview, !pane.isHiddenOrHasHiddenAncestor else { return [] }
        let area = pane.convert(pane.bounds, to: nil).insetBy(dx: 0.5, dy: 0.5)
        var found: [String] = []
        for split in splitViews(in: root) where !split.isDescendant(of: pane) {
            for line in drawn(by: split) where split.convert(line.frame, to: nil).intersects(area) {
                found.append("\(line.what) of \(type(of: split)) at \(split.convert(line.frame, to: nil)) over the terminal at \(area.insetBy(dx: -0.5, dy: -0.5))")
            }
        }
        return found
    }

    /// Lines drawn anywhere but between two panes that show: over a pane, or beside one that is hidden.
    static func linesNotBetweenPanes(in window: NSWindow) -> [String] {
        guard let root = window.contentView?.superview else { return [] }
        var found: [String] = []
        for split in splitViews(in: root) {
            let shown = split.arrangedSubviews.filter { !$0.isHidden && $0.frame.width >= 1 && $0.frame.height >= 1 }.map(\.frame)
            for line in drawn(by: split) {
                let over = shown.filter { $0.intersects(line.frame.insetBy(dx: 0.25, dy: 0.25)) }
                // A pane touching it on each side: before it and after it across the split.
                let before = shown.contains { split.isVertical ? abs($0.maxX - line.frame.minX) < 0.5 : abs($0.maxY - line.frame.minY) < 0.5 }
                let after = shown.contains { split.isVertical ? abs($0.minX - line.frame.maxX) < 0.5 : abs($0.minY - line.frame.maxY) < 0.5 }
                if !over.isEmpty || !before || !after {
                    found.append("\(line.what) of \(type(of: split)) at \(split.convert(line.frame, to: nil))"
                                 + (over.isEmpty ? " with no pane on \(before ? "one" : "its") side" : " over a pane"))
                }
            }
        }
        return found
    }

    private static func splitViews(in view: NSView) -> [NSSplitView] {
        guard !view.isHidden else { return [] }
        return ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
    }

    /// What a split view draws as lines, in its coordinates: its own lines, and AppKit's dividers, layers of
    /// their own beside the panes' that show when they have a colour.
    private static func drawn(by split: NSSplitView) -> [(what: String, frame: NSRect)] {
        var lines = (split as? HairlineSplitView)?.drawnLines.map { (what: "a line", frame: $0) } ?? []
        for layer in split.layer?.sublayers ?? [] where !split.subviews.contains(where: { $0.layer === layer }) {
            guard !layer.isHidden, layer.opacity > 0, let colour = layer.backgroundColor, colour.alpha > 0 else { continue }
            lines.append((what: "AppKit's divider", frame: layer.frame))
        }
        return lines
    }

    /// The colour the window shows at a point (window coordinates), as the capture has it (0–255 a channel).
    private static func screenColour(_ window: NSWindow, at point: NSPoint) -> [Int]? {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .nominalResolution]),
              image.width > 0 else { return nil }
        let scale = CGFloat(image.width) / window.frame.width
        // In the capture's own colour space: the numbers the window drew.
        guard let colour = NSBitmapImageRep(cgImage: image).colorAt(x: Int(point.x * scale), y: Int((window.frame.height - point.y) * scale)),
              colour.type == .componentBased, colour.colorSpace.colorSpaceModel == .rgb else { return nil }
        return [colour.redComponent, colour.greenComponent, colour.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// Lines drawn over the terminal in front, as the window shows it: in its margins, which are plain
    /// background (along the row between its tab bar and its text, and down its first column), any pixel not
    /// the background's is one. Empty when there is none. It looks at a tab of one pane, the terminal on
    /// screen: otherwise it says why it could not look.
    static func linesOverTerminal(_ c: TerminalWindowController) async -> String {
        guard let window = c.window, let group = c.activeGroup, !group.isSplit, !c.terminalRailed,
              !group.view.isHiddenOrHasHiddenAncestor else { return "could not look: the tab in front is split, or the terminal is folded" }
        window.displayIfNeeded()
        await pause(0.4)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .nominalResolution]),
              image.width > 0 else { return "could not look: no capture of the window" }
        let scale = CGFloat(image.width) / window.frame.width
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "could not look: no bitmap"
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let i = (y * width + x) * 4
            return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])]
        }
        // In the window (y up), then in the image (top down).
        let frame = group.view.convert(group.view.bounds, to: nil)
        func row(_ y: CGFloat) -> Int { min(height - 1, max(0, Int((window.frame.height - y) * scale))) }
        func column(_ x: CGFloat) -> Int { min(width - 1, max(0, Int(x * scale))) }
        let background = pixel(column(frame.minX + 4), row(frame.maxY - 2))
        func isBackground(_ x: Int, _ y: Int) -> Bool { !zip(pixel(x, y), background).contains { abs($0 - $1) > 6 } }
        let top = row(frame.maxY - 2), edge = column(frame.minX)
        let across = (column(frame.minX)..<column(frame.maxX)).filter { !isBackground($0, top) }
        // Clear of the window's rounded corners when the terminal starts at its edge.
        let corner: CGFloat = frame.minX < 1 ? 40 : 16
        let down = (row(frame.maxY - 8)..<row(frame.minY + corner)).filter { !isBackground(edge, $0) }
        var found: [String] = []
        if !across.isEmpty { found.append("across the top margin at x \(across.prefix(4).map { CGFloat($0) / scale })") }
        if !down.isEmpty { found.append("down the first column, \(down.count) pixels") }
        return found.joined(separator: "; ")
    }
}

private extension NSColor {
    /// The same colour as the window shows `pixel` (0–255 a channel, as captured), give or take a few steps.
    func matches(_ pixel: [Int]) -> Bool {
        guard let rgb = usingColorSpace(.sRGB), pixel.count == 3 else { return false }
        let own = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return !zip(own, pixel).contains { abs($0 - $1) > 6 }
    }
}
