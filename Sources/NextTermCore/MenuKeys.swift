import Foundation

/// The menu bar's keys in Next Term's own set, by command id (as `KeyboardShortcuts.id(of:)` gives them), as
/// AppDelegate.buildMenu gives them. The unit tests can't build the menus, so they read these to check that no
/// default clashes in any set of keys; the self-test checks the menus as built are exactly these.
public enum MenuKeys {
    /// Every menu command that has a key before the user's changes. Commands without one are left out.
    public static let defaults: [String: KeyChord] = {
        let cmd = { (key: String) in KeyChord(key: key, command: true) }
        let shiftCmd = { (key: String) in KeyChord(key: key, command: true, shift: true) }
        let optCmd = { (key: String) in KeyChord(key: key, command: true, option: true) }
        let ctrlCmd = { (key: String) in KeyChord(key: key, command: true, control: true) }
        let up = "\u{F700}", down = "\u{F701}", left = "\u{F702}", right = "\u{F703}"
        var keys: [String: KeyChord] = [
            // Next Term
            "showSettings:": cmd(","), "hide:": cmd("h"), "hideOtherApplications:": optCmd("h"), "terminate:": cmd("q"),
            // File
            "newTab:": cmd("t"), "newWindow:": cmd("n"), "newRemoteTab:": optCmd("t"), "reopenClosedTab:": shiftCmd("t"),
            "openProjectPanel:": cmd("o"), "goToFile:": cmd("p"), "saveDocument:": cmd("s"), "saveAllDocuments:": optCmd("s"),
            "splitRight:": cmd("d"), "splitDown:": shiftCmd("d"), "renameTab:": optCmd("r"), "closeTab:": cmd("w"),
            "performClose:": shiftCmd("w"),
            // Edit
            "undo:": cmd("z"), "redo:": shiftCmd("z"), "cut:": cmd("x"), "copy:": cmd("c"), "paste:": cmd("v"), "selectAll:": cmd("a"),
            "performFindPanelAction:#1": cmd("f"), "replaceInFile:": optCmd("f"), "performFindPanelAction:#2": cmd("g"),
            "performFindPanelAction:#3": shiftCmd("g"), "performFindPanelAction:#7": cmd("e"), "findInFiles:": shiftCmd("f"),
            "replaceInFiles:": shiftCmd("r"), "goToLine:": cmd("l"), "toggleComment:": cmd("/"), "indentSelection:": cmd("]"),
            "outdentSelection:": cmd("["), "duplicateLine:": cmd("d"), "deleteLine:": shiftCmd("k"), "moveLineUp:": ctrlCmd(up),
            "moveLineDown:": ctrlCmd(down), "clearBuffer:": cmd("k"),
            // View
            "toggleProjectSidebar:": cmd("b"), "toggleEditorFocus:": KeyChord(key: "`", control: true), "toggleTerminalCollapsed:": cmd("j"),
            "showChanges:": optCmd("g"), "toggleSoftWrap:": optCmd("w"), "toggleUnifiedDiffs:": ctrlCmd("u"),
            "toggleBlameAnnotations:": KeyChord(key: "a", command: true, shift: true, control: true),
            "toggleCurrentLineBlame:": KeyChord(key: "l", command: true, shift: true, control: true),
            "increaseFontSize:": cmd("+"), "decreaseFontSize:": cmd("-"), "resetFontSize:": cmd("0"), "toggleFullScreen:": ctrlCmd("f"),
            // Agents
            "resumeSession:": optCmd("o"), "sendToAgent:": optCmd("k"), "suggestCommand:": ctrlCmd("k"),
            // Git
            "showBranches:": optCmd("b"), "gitFetch:": cmd("r"), "gitUpdate:": optCmd("u"), "gitCommit:": shiftCmd("c"),
            "gitPush:": optCmd("p"), "gitNewBranch:": shiftCmd("b"), "showGitLog:": optCmd("l"), "showGitDiff:": ctrlCmd("g"),
            // Window
            "performMiniaturize:": cmd("m"), "showNextTab:": shiftCmd("]"), "showPreviousTab:": shiftCmd("["),
            "selectPaneLeft:": optCmd(left), "selectPaneRight:": optCmd(right), "selectPaneAbove:": optCmd(up),
            "selectPaneBelow:": optCmd(down), "selectNextPane:": optCmd("]"), "selectPreviousPane:": optCmd("["),
            "toggleZoomPane:": shiftCmd("\r"),
        ]
        for n in 1...9 { keys["selectTabByNumber:#\(n)"] = cmd("\(n)") }
        return keys
    }()

    /// Keys hidden menu items answer to, with the command each belongs to: no command can take them (⌘= is Bigger).
    /// ⌘P for Go to File under a set that moves it is not one of these: it gives way to any command that has ⌘P.
    public static let aliases: [KeyChord: String] = [KeyChord(key: "=", command: true): "increaseFontSize:"]
}
