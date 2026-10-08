import AppKit
import NextTermCore
import SwiftTerm

// Settings › Terminal: the cursor, the scrollback a tab keeps and where ⌘T opens a tab (NextTermCore/
// TerminalSettings.swift). Applied at once to every open terminal; an import can set them too.

extension Preferences {
    static var terminalCursorShape: CursorShape {
        get { CursorShape(rawValue: UserDefaults.standard.string(forKey: "terminalCursorShape") ?? "") ?? .block }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "terminalCursorShape") }
    }

    /// On unless turned off, as the terminal's cursor always was.
    static var terminalCursorBlinks: Bool {
        get { UserDefaults.standard.object(forKey: "terminalCursorBlink") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "terminalCursorBlink") }
    }

    /// The shape and blinking as the terminal takes them.
    static var terminalCursorStyle: CursorStyle {
        let blinks = terminalCursorBlinks
        switch terminalCursorShape {
        case .block: return blinks ? .blinkBlock : .steadyBlock
        case .bar: return blinks ? .blinkBar : .steadyBar
        case .underline: return blinks ? .blinkUnderline : .steadyUnderline
        }
    }

    /// Lines each terminal keeps above the screen.
    static var terminalScrollback: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: "terminalScrollback")
            return saved > 0 ? Scrollback.clamped(saved) : NextTermView.scrollbackLines
        }
        set { UserDefaults.standard.set(Scrollback.clamped(newValue), forKey: "terminalScrollback") }
    }

    static var terminalStartFolder: StartFolder {
        get { StartFolder(stored: UserDefaults.standard.string(forKey: "terminalStartFolder")) }
        set { UserDefaults.standard.set(newValue.stored, forKey: "terminalStartFolder") }
    }
}

extension AppDelegate {
    /// Sets the cursor's shape or blinking (nil: as it is) in every open terminal. A program that set its own
    /// cursor (vim in insert mode) gets this one back too; it sets its own again when it next needs to.
    func setTerminalCursor(shape: CursorShape? = nil, blinks: Bool? = nil) {
        if let shape { Preferences.terminalCursorShape = shape }
        if let blinks { Preferences.terminalCursorBlinks = blinks }
        let style = Preferences.terminalCursorStyle
        for controller in controllers { for tab in controller.tabs { tab.view.getTerminal().setCursorStyle(style) } }
    }

    /// Sets the scrollback in every open terminal (nil: the default). Fewer lines drops the oldest at once.
    func setTerminalScrollback(_ lines: Int?) {
        if let lines { Preferences.terminalScrollback = lines } else { UserDefaults.standard.removeObject(forKey: "terminalScrollback") }
        let kept = Preferences.terminalScrollback
        for controller in controllers {
            for tab in controller.tabs where tab.view.getTerminal().options.scrollback != kept {
                tab.view.getTerminal().changeScrollback(kept)
            }
        }
    }
}

extension NextTermView {
    /// The terminal options a new view starts with: the cursor and the scrollback from Settings › Terminal.
    static var startingOptions: TerminalOptions {
        TerminalOptions(cursorStyle: Preferences.terminalCursorStyle, scrollback: Preferences.terminalScrollback)
    }
}

extension TerminalWindowController {
    /// Where ⌘T opens a tab (Settings › Terminal › New tabs open in). A tab on a server has no folder here.
    func newTabDirectory() -> String? {
        let current = activeTab.flatMap { $0.remote == nil ? $0.currentDirectory() : nil }
        return Preferences.terminalStartFolder.directory(project: project, current: current, home: NSHomeDirectory()) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

/// Settings › Terminal's rows for the cursor, the scrollback and where new tabs open.
final class TerminalBehaviourControls: NSObject {
    let shape = NSPopUpButton()
    let blink = NSButton(checkboxWithTitle: "Blink", target: nil, action: nil)
    let scrollback = NSPopUpButton()
    let startFolder = NSPopUpButton()

    static let scrollbackChoices = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000]

    override init() {
        super.init()
        for shape in CursorShape.allCases {
            self.shape.addItem(withTitle: shape.title)
            self.shape.lastItem?.representedObject = shape.rawValue
        }
        shape.target = self
        shape.action = #selector(shapeChanged)
        blink.target = self
        blink.action = #selector(blinkChanged)
        scrollback.target = self
        scrollback.action = #selector(scrollbackChanged)
        scrollback.toolTip = "Lines each terminal keeps above the screen. Fewer lines drops the oldest in open terminals at once."
        startFolder.target = self
        startFolder.action = #selector(startFolderChanged)
        startFolder.toolTip = "Where ⌘T opens a tab. Splits open in the folder of the pane they split from."
    }

    /// The rows, made with the settings view's own row maker.
    func rows(_ row: (String, [NSView]) -> NSStackView) -> [NSView] {
        [row("Cursor:", [shape, blink]),
         row("Scrollback:", [scrollback, NSTextField(labelWithString: "lines")]),
         row("New tabs:", [startFolder])]
    }

    func refresh() {
        shape.selectItem(at: CursorShape.allCases.firstIndex(of: Preferences.terminalCursorShape) ?? 0)
        blink.state = Preferences.terminalCursorBlinks ? .on : .off
        scrollback.removeAllItems()
        let lines = Preferences.terminalScrollback
        for choice in Set(Self.scrollbackChoices + [lines]).sorted() {
            scrollback.addItem(withTitle: Self.formatted(choice))
            scrollback.lastItem?.tag = choice
        }
        scrollback.selectItem(withTag: lines)
        fillStartFolder()
    }

    static func formatted(_ lines: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
    }

    private func fillStartFolder() {
        startFolder.removeAllItems()
        let current = Preferences.terminalStartFolder
        let choices: [(String, StartFolder)] = [("In the project’s folder", .project), ("In the current tab’s folder", .current),
                                               ("In your home folder", .home)]
        for (title, folder) in choices {
            startFolder.addItem(withTitle: title)
            startFolder.lastItem?.representedObject = folder.stored
        }
        startFolder.menu?.addItem(.separator())
        if case .folder(let path) = current {
            startFolder.addItem(withTitle: "In " + RecentProjects.abbreviate(path))
            startFolder.lastItem?.representedObject = path
            startFolder.lastItem?.toolTip = path
        }
        startFolder.addItem(withTitle: "Choose Folder…")
        startFolder.selectItem(at: max(0, startFolder.indexOfItem(withRepresentedObject: current.stored)))
        startFolder.itemArray.first?.toolTip = "In a window without a project, the folder of the tab in front"
    }

    @objc private func shapeChanged() {
        guard let raw = shape.selectedItem?.representedObject as? String, let chosen = CursorShape(rawValue: raw) else { return }
        AppDelegate.shared.setTerminalCursor(shape: chosen)
    }

    @objc private func blinkChanged() {
        AppDelegate.shared.setTerminalCursor(blinks: blink.state == .on)
    }

    @objc private func scrollbackChanged() {
        guard let item = scrollback.selectedItem else { return }
        AppDelegate.shared.setTerminalScrollback(item.tag)
    }

    @objc private func startFolderChanged() {
        if let stored = startFolder.selectedItem?.representedObject as? String {
            Preferences.terminalStartFolder = StartFolder(stored: stored)
            return
        }
        // Choose Folder…
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "New tabs open in this folder."
        if panel.runModal() == .OK, let url = panel.url {
            Preferences.terminalStartFolder = .folder(canonicalPath(url.path))
        }
        fillStartFolder()
    }
}
