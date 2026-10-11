import AppKit
import NextTermCore

/// What a Remote access connection may do (U8): the three presets, the grouped checkbox list of the Connection
/// Options, and R22's sentences. The pairing window shows it for a new connection, and Settings › Remote Access
/// shows it again for Edit… (U11) with the connection's options and its own Save button.
///
/// Read only, Control and Custom are radio buttons. Custom opens the list below, set to the Custom starting values;
/// "Each option" opens it for any preset without changing a value. Ticking a box keeps the list's values, and the
/// radio buttons then show the preset those values carry the name of (R22's rule), so Control with "Notify on this
/// Mac" off still shows as Control. The labels are U1's table, word for word.
///
/// The sentences sit at the bottom, right above the window's Allow or Save: Control's whenever the options carry
/// Control's name, and the write tools' while "Next Term's write tools" is on.
@MainActor
final class RemoteAccessOptionsView: NSView {
    /// The options shown now: what Allow or Save takes.
    private(set) var options: RemoteAccessOptions
    /// Told after each change the user makes, with the options shown.
    var onChange: ((RemoteAccessOptions) -> Void)?

    /// The radio button of each preset.
    private(set) var presetButtons: [RemoteAccessPreset: NSButton] = [:]
    /// The checkbox of each option.
    private(set) var checkboxes: [RemoteAccessOption.ID: NSButton] = [:]
    /// The sentence labels, in order: Control's, then the write tools'.
    private(set) var sentenceLabels: [NSTextField] = []

    private let disclosure = NSButton()
    private let listScroll = NSScrollView()
    private let sentenceRows = NSStackView()
    private var sentenceRowViews: [NSView] = []

    /// The list's height: the rest scrolls, so the window fits a small screen.
    static let listHeight: CGFloat = 230
    static let width: CGFloat = 484

    /// The view for `options`. Pairing opens with the list closed (Read only picked); Edit… opens it.
    init(options: RemoteAccessOptions, showsList: Bool) {
        self.options = options
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        build()
        setListShown(showsList)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The preset the options carry the name of: the radio button shown on.
    var preset: RemoteAccessPreset { options.preset }

    /// Whether the grouped list shows.
    var isListShown: Bool { !listScroll.isHidden }

    /// The sentences that show now.
    var sentences: [String] {
        guard !sentenceRows.isHidden else { return [] }
        let shown = sentenceRowViews.indices.filter { !sentenceRowViews[$0].isHidden }
        return shown.map { sentenceLabels[$0].stringValue }
    }

    // MARK: changes, as a click makes them

    /// Picks a preset, as its radio button does: Read only and Control set their values; Custom opens the list,
    /// at its starting values unless the options already carry Custom's name.
    func pick(_ preset: RemoteAccessPreset) {
        switch preset {
        case .readOnly, .control:
            if options.preset != preset { options = preset.options }
        case .custom:
            if options.preset != .custom { options = .customStart }
            setListShown(true)
        }
        changed()
    }

    /// Turns one option on or off, as its checkbox does.
    func set(_ id: RemoteAccessOption.ID, _ on: Bool) {
        options[id] = on
        changed()
    }

    /// Opens or closes the list, as "Each option" does. No value changes.
    func setListShown(_ shown: Bool) {
        listScroll.isHidden = !shown
        disclosure.state = shown ? .on : .off
        window?.contentView?.needsLayout = true
    }

    private func changed() {
        refresh()
        onChange?(options)
    }

    /// The radio buttons, the boxes and the sentences, from `options`.
    private func refresh() {
        let named = options.preset
        for (preset, button) in presetButtons {
            button.state = preset == named ? .on : .off
        }
        for (id, box) in checkboxes {
            box.state = options[id] ? .on : .off
        }
        let shown = options.sentences
        for (index, label) in sentenceLabels.enumerated() {
            sentenceRowViews[index].isHidden = !shown.contains(label.stringValue)
        }
        sentenceRows.isHidden = shown.isEmpty
    }

    // MARK: actions

    @objc private func presetClicked(_ sender: NSButton) {
        guard let preset = presetButtons.first(where: { $0.value === sender })?.key else { return }
        pick(preset)
    }

    @objc private func boxClicked(_ sender: NSButton) {
        guard let id = checkboxes.first(where: { $0.value === sender })?.key else { return }
        set(id, sender.state == .on)
    }

    @objc private func disclosureClicked(_ sender: NSButton) {
        setListShown(sender.state == .on)
        onChange?(options)
    }

    @objc private func disclosureLabelClicked(_ sender: Any?) {
        setListShown(listScroll.isHidden)
        onChange?(options)
    }

    // MARK: building

    private func build() {
        var views: [NSView] = []
        for preset in RemoteAccessPreset.allCases {
            views.append(presetRow(preset))
        }
        views.append(disclosureRow())
        buildList()
        views.append(listScroll)
        buildSentences()
        views.append(sentenceRows)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: views[RemoteAccessPreset.allCases.count - 1])
        stack.setCustomSpacing(10, after: listScroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            listScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listScroll.heightAnchor.constraint(equalToConstant: Self.listHeight),
            sentenceRows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// A radio button and what its preset gives, on one line.
    private func presetRow(_ preset: RemoteAccessPreset) -> NSView {
        let button = NSButton(radioButtonWithTitle: preset.title, target: self, action: #selector(presetClicked(_:)))
        button.font = .systemFont(ofSize: 13, weight: .medium)
        presetButtons[preset] = button
        let summary = NSTextField(labelWithString: Self.summary(preset))
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        button.setAccessibilityHelp(summary.stringValue)
        button.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let row = NSStackView(views: [button, summary])
        row.spacing = 4
        return row
    }

    /// "Each option": opens the list without changing a value.
    private func disclosureRow() -> NSView {
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked(_:))
        disclosure.setAccessibilityLabel("Each option")
        let label = NSTextField(labelWithString: "Each option")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(disclosureLabelClicked(_:))))
        let row = NSStackView(views: [disclosure, label])
        row.spacing = 2
        return row
    }

    /// The groups and their boxes, in the table's order, each with a line on what it does.
    private func buildList() {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        // The list's insets, the indent under each box, and room for a scroller.
        let textWidth = Self.width - 70
        for group in RemoteAccessOption.Group.allCases {
            let rows = RemoteAccessOption.all.filter { $0.group == group }
            guard !rows.isEmpty else { continue }
            let title = NSTextField(labelWithString: group.title)
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            if let last = list.arrangedSubviews.last { list.setCustomSpacing(12, after: last) }
            list.addArrangedSubview(title)
            for option in rows {
                list.addArrangedSubview(optionRow(option, textWidth: textWidth))
            }
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        listScroll.documentView = document
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .bezelBorder
        listScroll.drawsBackground = true
        listScroll.backgroundColor = .controlBackgroundColor
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = listScroll.contentView
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
    }

    /// A box with the option's label, and its line below.
    private func optionRow(_ option: RemoteAccessOption, textWidth: CGFloat) -> NSView {
        let box = NSButton(checkboxWithTitle: option.label, target: self, action: #selector(boxClicked(_:)))
        box.font = .systemFont(ofSize: 12)
        checkboxes[option.id] = box
        let detail = NSTextField(wrappingLabelWithString: Self.detail(option.id))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = textWidth
        detail.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        box.setAccessibilityHelp(detail.stringValue)
        let indented = NSStackView(views: [detail])
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 2, right: 0)
        let row = NSStackView(views: [box, indented])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 1
        return row
    }

    /// R22's two sentences, each with a mark, shown as `refresh` says.
    private func buildSentences() {
        sentenceRows.orientation = .vertical
        sentenceRows.alignment = .leading
        sentenceRows.spacing = 6
        let texts = [RemoteAccessOptions.controlSentence, RemoteAccessOptions.writeToolsSentence]
        for (index, text) in texts.enumerated() {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: index == 0 ? .semibold : .regular)
            label.preferredMaxLayoutWidth = Self.width - 24
            label.widthAnchor.constraint(equalToConstant: Self.width - 24).isActive = true
            sentenceLabels.append(label)
            let mark = NSImageView()
            let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            mark.image = symbol
            mark.contentTintColor = index == 0 ? .systemOrange : .secondaryLabelColor
            mark.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [mark, label])
            row.alignment = .top
            row.spacing = 6
            sentenceRowViews.append(row)
            sentenceRows.addArrangedSubview(row)
        }
    }

    // MARK: words

    /// What a preset gives, next to its radio button.
    static func summary(_ preset: RemoteAccessPreset) -> String {
        switch preset {
        case .readOnly: return "Tabs, screens, projects, files and diffs."
        case .control: return "Every option on, and this Mac doesn't ask first."
        case .custom: return "Only what you tick. It starts with this Mac asking first."
        }
    }

    /// The line under each option's box.
    static func detail(_ id: RemoteAccessOption.ID) -> String {
        switch id {
        case .tabs:
            return "List tabs and their agents' states, read their screens, and wait for them."
        case .projectFiles:
            return "List projects, read and search their files, and see git status and diffs."
        case .editor:
            return "See the files open in the editor and the selected text."
        case .serversRead:
            return "List your saved servers, check them, and read what changed in a folder there."
        case .typeAsking:
            return "Send text and keys to an agent whose screen shows a mode that asks before it runs a command."
        case .typeNeverAsking:
            return "Also reach agents in a bypass or auto-approve mode, and agents whose mode Next Term can't read."
        case .answerOnce:
            return "Answer an agent's question with No, or with a choice that allows it once, such as Yes. "
                + "A Yes runs what the agent asked to run."
        case .answerStanding:
            return "Also pick choices that keep allowing, such as always or don't ask again."
        case .slashAllowlist:
            return "Text may start with /clear, /compact, /status, /cost, /usage, /context or /help."
        case .anySlash:
            return "Text may start with any / command."
        case .shellAndMemory:
            return "Text may start with !, which the agent runs as a shell command, or #, which Claude Code saves "
                + "to its memory."
        case .safeKeys:
            return "Press the arrow keys, Return and Escape while an agent's input line shows. Escape stops an agent."
        case .everyKey:
            return "Press any key, Tab and Control keys included, and send text without Return. With it, a remote "
                + "can type any text and pick any choice on a prompt."
        case .typeShells:
            return "Send text and keys to a plain shell, or to a command that is not an agent. A shell runs what "
                + "it gets."
        case .openAgentTab:
            return "Open a tab in an open project that starts one agent, such as claude, with no arguments."
        case .openAnyTab:
            return "Open a tab that runs any command, or a plain shell."
        case .closeIdleTabs:
            return "Close a tab where nothing runs, a shell at its prompt included."
        case .closeBusyTabs:
            return "Close any tab, and stop what runs in it."
        case .showOnMac:
            return "Open folders as projects, bring tabs to the front, open files in the editor, and open a new "
                + "tab outside the open projects."
        case .servers:
            return "Add and remove saved servers, and open tabs on them."
        case .skills:
            return "List, install and remove your agent skills."
        case .writeTools:
            return "Propose edits, write and create files, stage, commit, arrange panes and change settings. "
                + RemoteAccessOptions.writeToolsSentence
        case .askOnMac:
            return "Each change waits for Allow on this Mac. With it off, nothing asks on this Mac: typing, "
                + "answers, the write tools and skill installs run without a window, and only the chat app's "
                + "confirmation is left, which “always allow” there removes. propose_edit still opens its diff."
        case .notify:
            return "Show a notification on this Mac for each change a remote makes, with the first line of what it sent."
        case .rateLimit:
            return "Hold this connection to 10 changes a minute. Reading never counts."
        }
    }
}

/// A document view that lays out from the top, as a list reads.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
