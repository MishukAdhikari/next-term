import AppKit
import NextTermCore

extension TerminalWindowController {
    /// Agents › New Chat… (plan 037 R16): which agent (those installed, the last one picked first) and which folder (the
    /// window's project, recent projects, or Choose…), then a chat tab with its input box focused. No command is typed
    /// and none is shown.
    @objc func newChat(_ sender: Any?) {
        let agents = NewChatChoices.ordered(ACPSessionTabs.installed)
        let alert = NSAlert()
        alert.messageText = "New Chat"
        guard !agents.isEmpty else {
            alert.informativeText = "None of the agents Next Term runs in a chat is installed here: "
                + ACPAgent.known.prefix(6).map(\.name).joined(separator: ", ") + " and others. Install one, then try again."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        alert.informativeText = "Runs the agent installed here, signed in as you signed it in, in a chat tab: its replies, "
            + "tool calls and permission requests in Next Term\u{2019}s own view."
        let agentPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        agentPicker.addItems(withTitles: agents.map(\.name))
        agentPicker.setAccessibilityLabel("Agent")
        // What still needs the agent's own terminal tab (Claude Code's and Codex's), under the picker, for the one picked.
        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        let folderPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        folderPicker.setAccessibilityLabel("Folder")
        let label = { (text: String) -> NSTextField in
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            return field
        }
        let stack = NSStackView(views: [label("Agent"), agentPicker, note, label("Folder"), folderPicker])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: note)
        agentPicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        folderPicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        let choices = NewChatChoices(agents: agents, note: note, folders: folderPicker,
                                     project: project ?? searchRoot, recent: AppDelegate.shared.recentProjects) { [weak alert] in
            DialogFit.fitAccessory(stack, width: 320, in: alert)
        }
        agentPicker.target = choices
        agentPicker.action = #selector(NewChatChoices.pickedAgent(_:))
        folderPicker.target = choices
        folderPicker.action = #selector(NewChatChoices.pickedFolder(_:))
        choices.showAgent(0)
        alert.window.initialFirstResponder = agentPicker
        let start: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            withExtendedLifetime(choices) {} // the pickers' target lives as long as the sheet
            guard let self, response == .alertFirstButtonReturn else { return }
            let agent = agents[max(agentPicker.indexOfSelectedItem, 0)]
            NewChatChoices.remember(agent)
            let folder = choices.folder
            guard let tab = ChatTabs.open(ChatStart(agentID: agent.id, folder: folder), in: self) else { return NSSound.beep() }
            // The input box takes the keyboard, so the first prompt can be typed at once.
            if let input = tab.chatHost?.view.input.textView { self.window?.makeFirstResponder(input) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: start) } else { start(alert.runModal()) }
    }
}

/// The New Chat sheet's pickers: the note follows the agent picked, and the folder popup lists the window's project,
/// then up to 8 recent projects, then Choose…, which asks for a folder and puts it first.
@MainActor
final class NewChatChoices: NSObject {
    /// The defaults key of the agent picked last, which the next sheet lists first.
    static let lastAgentKey = "newChat.agent"

    private let agents: [ACPAgent]
    private let note: NSTextField
    private let folders: NSPopUpButton
    private let refit: () -> Void
    /// The folders listed, in order; Choose… follows them.
    private var listed: [String]
    private var picked = 0

    init(agents: [ACPAgent], note: NSTextField, folders: NSPopUpButton, project: String, recent: [String],
         refit: @escaping () -> Void) {
        self.agents = agents
        self.note = note
        self.folders = folders
        self.refit = refit
        var listed = [project]
        for folder in recent where !listed.contains(folder) && listed.count < 9 { listed.append(folder) }
        self.listed = listed
        super.init()
        fillFolders()
    }

    /// The installed agents with the one picked last first.
    static func ordered(_ agents: [ACPAgent]) -> [ACPAgent] {
        guard let last = UserDefaults.standard.string(forKey: lastAgentKey), let index = agents.firstIndex(where: { $0.id == last }) else {
            return agents
        }
        var ordered = agents
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    static func remember(_ agent: ACPAgent) {
        UserDefaults.standard.set(agent.id, forKey: lastAgentKey)
    }

    /// The folder the chat runs in.
    var folder: String { listed[min(picked, listed.count - 1)] }

    func showAgent(_ index: Int) {
        let words = agents.indices.contains(index) ? agents[index].terminalNote : nil
        note.stringValue = words ?? ""
        note.isHidden = words == nil
        refit()
    }

    @objc func pickedAgent(_ sender: NSPopUpButton) {
        showAgent(max(sender.indexOfSelectedItem, 0))
    }

    @objc func pickedFolder(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index >= 0, index < listed.count {
            picked = index
            return
        }
        // Choose…: a folder of the user's, then first in the list and picked.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.standardizedFileURL.path
            listed.removeAll { $0 == path }
            listed.insert(path, at: 0)
            picked = 0
        }
        fillFolders()
    }

    private func fillFolders() {
        folders.removeAllItems()
        for path in listed {
            folders.addItem(withTitle: (path as NSString).abbreviatingWithTildeInPath)
            folders.lastItem?.toolTip = path
        }
        folders.menu?.addItem(.separator())
        folders.addItem(withTitle: "Choose\u{2026}")
        folders.selectItem(at: picked)
    }
}
