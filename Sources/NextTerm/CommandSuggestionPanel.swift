import AppKit
import NextTermCore

/// Suggest a Command (Agents › Suggest a Command…, ⌃⌘K), on only when the user turned it on in Settings › Terminal.
/// A panel near the caret takes a sentence; the agent the user chose answers with one command (CommandSuggestionRunner),
/// which goes on the line and is never run. Before anything is sent, the panel says what goes with the sentence: the
/// folder, the shell and the last command, redacted. Recent output goes only when the user includes it, each time,
/// after seeing it as it would be sent.
final class CommandSuggestionPanel: NSObject, NSWindowDelegate {
    /// The panel on screen, for the self-test.
    private(set) static var current: CommandSuggestionPanel?

    private weak var tab: TerminalTab?
    private let choice: String
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
    let field = NSTextField()
    private let context = NSTextField(wrappingLabelWithString: "")
    private let outputButton = NSButton(title: "Include Recent Output…", target: nil, action: nil)
    private let outputNote = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let result = NSTextField(wrappingLabelWithString: "")
    private let notes = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let primary = NSButton(title: "Suggest", target: nil, action: nil)

    private var runner: CommandSuggestionRunner?
    /// Recent output the user included, for the next request only.
    private var includedOutput: String?
    private(set) var suggestion: CommandSuggestion.Suggestion?
    /// The tab as the request went out: a line changed since (a key, an agent's text, a command) is replaced only
    /// on the user's word.
    private var writesAtStart = 0
    private var commandsAtStart = 0
    /// The answer waits for the server's status reports to be fresh before it goes on the line (putWhenReady).
    private var waitsForReports = false

    enum Stage {
        case asking
        case waiting
        case answered
    }
    private(set) var stage = Stage.asking

    /// Opens the panel for `tab` (one at a time; one request per tab).
    static func show(for tab: TerminalTab, choice: String) {
        current?.panel.close()
        let shown = CommandSuggestionPanel(tab: tab, choice: choice)
        current = shown
        shown.place()
        shown.panel.makeKeyAndOrderFront(nil)
        shown.panel.makeFirstResponder(shown.field)
    }

    private init(tab: TerminalTab, choice: String) {
        self.tab = tab
        self.choice = choice
        super.init()
        build()
        context.stringValue = contextText()
        refresh()
    }

    private func build() {
        panel.title = "Suggest a Command"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        field.placeholderString = "What should it do? Find files over 100 MB here"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel("What the command should do")
        for label in [context, outputNote, status, notes] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        result.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        result.isSelectable = true
        result.setAccessibilityLabel("Suggested command")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        outputButton.bezelStyle = .rounded
        outputButton.controlSize = .small
        outputButton.target = self
        outputButton.action = #selector(includeOutput)
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        primary.target = self
        primary.action = #selector(go(_:))
        primary.keyEquivalent = "\r"
        let outputRow = NSStackView(views: [outputButton, outputNote])
        outputRow.spacing = 8
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 6
        let buttons = NSStackView(views: [copyButton, NSView(), cancelButton, primary])
        buttons.spacing = 8
        let stack = NSStackView(views: [field, context, outputRow, statusRow, result, notes, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 480),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
            context.widthAnchor.constraint(equalTo: field.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: field.widthAnchor, constant: -24),
            result.widthAnchor.constraint(equalTo: field.widthAnchor),
            notes.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        panel.contentView = content
    }

    // MARK: what is sent

    private var request: CommandSuggestion.Request? {
        guard let tab else { return nil }
        // A tab that shows herdr has herdr itself as its "command": no last command of the shell's to tell.
        let herdr = tab.serverPrompt?.showsHerdr == true
        let last = tab.status.commandsStarted > 0 && !herdr ? tab.status.command : ""
        return CommandSuggestion.Request(sentence: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                         directory: tab.remote == nil ? tab.liveDirectory : tab.directory,
                                         shell: Self.shell(of: tab), lastCommand: last.isEmpty ? nil : last,
                                         lastExit: last.isEmpty ? nil : tab.status.exitCode, output: includedOutput)
    }

    /// The tab's shell, as the agent is told it.
    static func shell(of tab: TerminalTab) -> String {
        if tab.remote != nil { return tab.completion.state.arm != nil ? "zsh, on a server" : "the login shell of a server (bash, zsh or sh)" }
        return (tab.shellPath as NSString).lastPathComponent
    }

    /// "Sent to Claude Code with it: …", said before anything is sent.
    private func contextText() -> String {
        guard let request else { return "" }
        let who = CompletionPreferences.suggestionName(choice)
        var parts = ["the folder \((request.directory as NSString).abbreviatingWithTildeInPath)", "the shell (\(request.shell))"]
        if let last = request.lastCommand {
            let ended = request.lastExit.map { ", exit \($0)" } ?? ""
            parts.append("the last command, “\(CompletionRanking.visible(CommandSuggestion.redactedCommand(last)))”\(ended), secrets masked")
        }
        let list = parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        let local = choice == CompletionPreferences.onDevice ? " It stays on this Mac." : " It runs with no tools, in an empty folder."
        return "Sent to \(who) with your words: \(list).\(local) The command goes on the line; nothing runs."
    }

    var contextShown: String { context.stringValue }
    var statusShown: String { status.stringValue }
    var primaryTitle: String { primary.isHidden ? "" : primary.title }

    /// Recent output, as it would be sent, for the user to include or not: this request only.
    @objc private func includeOutput() {
        guard let tab else { return }
        // Rows masked over whole lines first: a stored key the terminal wrapped is masked in each of its rows.
        let text = CommandSuggestion.redactedOutput(tab.screenTail(60, masked: SecretMask.current).joined(separator: "\n"))
        let alert = NSAlert()
        alert.messageText = "Include this output?"
        alert.informativeText = "The end of the tab’s output, as it would be sent with this request only, secrets masked."
        let view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let textView = NSTextView(frame: view.bounds)
        textView.string = text.isEmpty ? "(no output)" : text
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.documentView = textView
        view.hasVerticalScroller = true
        alert.accessoryView = view
        alert.addButton(withTitle: "Include").keyEquivalent = ""
        alert.addButton(withTitle: "Don’t Include").keyEquivalent = "\u{1b}"
        Self.outputQuestion = alert
        alert.beginSheetModal(for: panel) { [weak self] response in
            Self.outputQuestion = nil
            guard let self else { return }
            self.includedOutput = response == .alertFirstButtonReturn && !text.isEmpty ? text : nil
            self.refresh()
        }
    }

    /// The output question on screen, for the self-test.
    private(set) static var outputQuestion: NSAlert?

    // MARK: asking

    @objc private func go(_ sender: Any?) {
        switch stage {
        case .asking: ask()
        case .waiting: break
        case .answered: put(force: true)
        }
    }

    private func ask() {
        guard let tab, let request, !request.sentence.isEmpty else { return NSSound.beep() }
        writesAtStart = tab.completion.writes
        commandsAtStart = tab.status.commandsStarted
        suggestion = nil
        waitsForReports = false
        status.stringValue = "Asking \(CompletionPreferences.suggestionName(choice))…"
        stage = .waiting
        refresh()
        let prompt = CommandSuggestion.prompt(request)
        includedOutput = nil // asked again each time
        runner = CommandSuggestionRunner.start(for: tab, choice: choice, prompt: prompt) { [weak self] answer in
            self?.answered(answer)
        }
        if runner == nil {
            status.stringValue = "A suggestion for this tab is on its way already."
            stage = .asking
            refresh()
        }
    }

    private func answered(_ answer: CommandSuggestionRunner.Answer) {
        runner = nil
        switch answer {
        case .failure(let failure):
            status.stringValue = failure.message
            stage = .asking
            refresh()
            CompletionPopup.announce(failure.message)
        case .success(let made):
            suggestion = made
            stage = .answered
            status.stringValue = ""
            // Nothing hidden in it, nothing to say: it goes on the line by itself. Otherwise it waits here for the user.
            if !made.hasHidden, made.notes.isEmpty { return putWhenReady(made, until: TerminalTab.now + 10) }
            refresh()
            CompletionPopup.announce("Suggested: \(made.shown)")
        }
    }

    /// An answer goes on the line by itself only while the tab is as it was when asked. A server's shell is trusted
    /// at its prompt from the second status report after the last Return (ServerPrompt), which a quick answer can
    /// beat: then it waits for those here, up to `deadline` (10 s), and is left to copy or put by hand if they don't
    /// come. Anywhere it can't go (herdr's screen, a program in front) it waits for the user at once.
    private func putWhenReady(_ made: CommandSuggestion.Suggestion, until deadline: TimeInterval) {
        guard let tab, suggestion == made, stage == .answered, Self.current === self else { return }
        let awaits = !made.multiline && tab.serverPrompt?.awaitsReports == true
        if unchanged, awaits, TerminalTab.now < deadline {
            if !waitsForReports {
                waitsForReports = true
                refresh()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.putWhenReady(made, until: deadline) }
            return
        }
        waitsForReports = false
        if unchanged, Self.canPut(made, on: tab), put(force: false) { return }
        refresh()
        CompletionPopup.announce("Suggested: \(made.shown)")
    }

    /// The tab is as it was when the request went out: no key or text sent to it, no command started.
    private var unchanged: Bool {
        guard let tab else { return false }
        return tab.completion.writes == writesAtStart && tab.status.commandsStarted == commandsAtStart
    }

    /// Puts the suggestion on the line, if it can go there from here; closes the panel once it has.
    @discardableResult
    private func put(force: Bool) -> Bool {
        guard let tab, let made = suggestion, Self.canPut(made, on: tab) else {
            NSSound.beep()
            refresh()
            return false
        }
        guard force || unchanged else { return false }
        Self.put(made, on: tab)
        CompletionPopup.announce("Put on the line: \(made.shown)")
        panel.close()
        return true
    }

    /// Whether `made` can go on `tab`'s line: at a shell prompt; several lines only through the hook of a zsh on
    /// this Mac (one edit there); one line through a hooked server's zsh, or typed in as a paste elsewhere.
    static func canPut(_ made: CommandSuggestion.Suggestion, on tab: TerminalTab) -> Bool {
        guard CommandSuggestionController.atPrompt(tab) else { return false }
        if tab.completion.takesLine { return !made.multiline || tab.remote == nil }
        return !made.multiline
    }

    static func put(_ made: CommandSuggestion.Suggestion, on tab: TerminalTab) {
        tab.userInput() // on the user's word: a restored action waiting in the tab is dropped, never run after it
        if tab.completion.takesLine {
            tab.completion.takeLine(made.command)
        } else {
            tab.view.typeIn(made.command)
        }
    }

    @objc private func copy(_ sender: Any?) {
        guard let made = suggestion else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(made.command, forType: .string)
        status.stringValue = "Copied."
    }

    @objc private func cancel(_ sender: Any?) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        runner?.cancel()
        runner = nil
        panel.parent?.removeChildWindow(panel)
        if let tab, let window = tab.view.window { window.makeFirstResponder(tab.view) }
        if Self.current === self { Self.current = nil }
    }

    // MARK: showing

    private func refresh() {
        let answered = stage == .answered
        field.isEditable = stage == .asking
        outputButton.isHidden = stage != .asking
        outputNote.isHidden = stage != .asking
        outputNote.stringValue = includedOutput.map { "Included: \($0.split(separator: "\n").count) lines, with this request only." }
            ?? "Not included."
        if stage == .waiting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        result.isHidden = !answered
        notes.isHidden = !answered
        copyButton.isHidden = !answered
        primary.isHidden = stage == .waiting
        cancelButton.title = stage == .waiting ? "Cancel" : (answered ? "Close" : "Cancel")
        guard answered, let made = suggestion, let tab else {
            primary.title = "Suggest"
            primary.isEnabled = stage == .asking
            return
        }
        result.stringValue = made.shown
        var said = made.notes
        if made.hasHidden { said.insert("It holds invisible or direction-changing characters, spelled out above.", at: 0) }
        let fits = Self.canPut(made, on: tab)
        if fits, !unchanged { said.append("Something was typed in the tab, or a command started, while it was asked.") }
        if !fits { said.append(Self.whyNot(made, on: tab, waiting: waitsForReports)) }
        notes.stringValue = said.joined(separator: " ")
        primary.isHidden = !fits
        // Only the shell's hook replaces the line; elsewhere it is typed in where the cursor is.
        primary.title = unchanged || !tab.completion.takesLine ? "Put on Line" : "Replace Line"
    }

    /// Why `made` can't go on `tab`'s line from here, for the panel's notes.
    private static func whyNot(_ made: CommandSuggestion.Suggestion, on tab: TerminalTab, waiting: Bool) -> String {
        let server = tab.serverPrompt
        // herdr's panes, and which has the keys, are out of Next Term's sight.
        if server?.showsHerdr == true { return "This tab shows herdr: copy it into the pane you want." }
        if made.multiline { return "It has more than one line, which only a zsh tab with Tab completion takes as one edit: copy it." }
        if waiting { return "It goes on the line once the server reports its shell at the prompt again." }
        if server?.inMode == true { return "The tab’s tmux pane is in copy mode (q leaves it): copy it, or leave copy mode and ask again." }
        if server?.awaitsReports == true { return "The server hasn’t reported its shell at the prompt since the last Return: copy it." }
        return "The tab isn’t at a shell prompt now: copy it."
    }

    /// Below the caret's line, on the caret's screen.
    private func place() {
        guard let tab, let window = tab.view.window else { return panel.center() }
        window.addChildWindow(panel, ordered: .above)
        if let content = panel.contentView { panel.setContentSize(content.fittingSize) }
        let caret = tab.view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let size = panel.frame.size
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var origin = NSPoint(x: caret.minX - 20, y: caret.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = caret.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// For the self-test.
    func type(_ sentence: String) { field.stringValue = sentence }
    func submit() { go(nil) }
    func askToIncludeOutput() { includeOutput() }
    var resultShown: String { result.isHidden ? "" : result.stringValue }
    var notesShown: String { notes.isHidden ? "" : notes.stringValue }
}

/// Agents › Suggest a Command…: while it is off in Settings, it opens Settings › Terminal at Suggestions, saying how to
/// turn it on (never a silent beep); on, it is on where the tab in front may be asked (mayAsk).
final class CommandSuggestionController: NSObject, NSMenuItemValidation {
    static let shared = CommandSuggestionController()

    @objc func suggestCommand(_ sender: Any?) {
        guard let choice = CompletionPreferences.suggestion else { return AppDelegate.shared.showSuggestionSettings() }
        guard let tab = Self.frontTab, Self.mayAsk(tab) else { return NSSound.beep() }
        CommandSuggestionPanel.show(for: tab, choice: choice)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(suggestCommand(_:)) else { return true }
        guard CompletionPreferences.suggestion != nil else { return true } // it opens Settings
        guard let tab = Self.frontTab else { return false }
        return Self.mayAsk(tab)
    }

    static var frontTab: TerminalTab? {
        (NSApp.keyWindow?.windowController as? TerminalWindowController)?.activeTab
    }

    /// The panel may open for `tab`: at its shell's prompt; on a server, by what the status checks said last, fresh or
    /// not (nothing is typed in until they are), and in a tab that shows herdr once it is connected, its answer to copy.
    static func mayAsk(_ tab: TerminalTab) -> Bool {
        guard !tab.exited else { return false }
        if let server = tab.serverPrompt { return server.mayAsk }
        return atPrompt(tab)
    }

    /// A shell waits at its prompt, so a command can be typed in: nothing runs in front (no agent, no editor, no
    /// full-screen program, nothing a key binding started). On a server, by the rule Tab completion's screen follows
    /// too (ServerPrompt): connected, the shell in front by two status reports since the last Return, not in tmux's
    /// copy mode, and never in a tab that shows herdr.
    static func atPrompt(_ tab: TerminalTab) -> Bool {
        guard !tab.exited else { return false }
        if let server = tab.serverPrompt { return server.atPrompt }
        guard !tab.status.running, tab.shellAlone else { return false }
        return !tab.view.getTerminal().isCurrentBufferAlternate
    }
}
