import AppKit
import NextTermCore

/// The Add Task sheet's destination controls, built here and driven by the sheet: the Destination popup, the Agent tab
/// popup for Through your agent, Use Todo Folder after the line, the What's sent disclosure with the exact text that
/// leaves, and the one-time offer of another destination.
@MainActor
final class AddTaskDestinationViews {
    let destination = NSPopUpButton()
    let destinationRow: NSStackView
    let agent = NSPopUpButton()
    let agentRow: NSStackView
    let useTodoFolder: NSButton
    let sentToggle = NSButton()
    let sentRow: NSStackView
    let sentText: NSTextView
    let sentScroll: NSScrollView
    let offerChoose: NSButton
    let offerClose: NSButton
    let offerRow: NSStackView

    /// What's sent stays open or closed as the user left it, while Next Term runs.
    static var sentOpen = false

    init(target: AnyObject, destinationChanged: Selector, agentChanged: Selector, useTodoFolder use: Selector,
         toggleSent: Selector, choose: Selector, dismissOffer: Selector) {
        destination.target = target
        destination.action = destinationChanged
        destination.autoenablesItems = false
        destination.setAccessibilityLabel("Destination")
        destination.toolTip = "Where this task goes. Changing it here changes this Add only; Settings › Tasks sets "
            + "where the project’s tasks go."
        destinationRow = NSStackView(views: [NSTextField(labelWithString: "Destination:"), destination])
        destinationRow.spacing = 8

        agent.target = target
        agent.action = agentChanged
        agent.autoenablesItems = false
        agent.setAccessibilityLabel("Agent tab")
        agent.toolTip = "The agent tab the request is typed into, with no Return. Only a tab that is ready can be chosen."
        let connect = NSButton(title: "Connect a Tracker…", target: TasksMenu.shared, action: #selector(TasksMenu.connectTracker(_:)))
        connect.bezelStyle = .inline
        connect.toolTip = "Your agent’s own command to add the tracker’s MCP server, typed into a new tab for you to run."
        agentRow = NSStackView(views: [NSTextField(labelWithString: "Agent tab:"), agent, connect])
        agentRow.spacing = 8
        agentRow.isHidden = true

        useTodoFolder = NSButton(title: "Use Todo Folder", target: target, action: use)
        useTodoFolder.controlSize = .small
        useTodoFolder.bezelStyle = .rounded
        useTodoFolder.isHidden = true
        useTodoFolder.toolTip = "Adds this task to the project’s todo folder instead, this time only."

        sentToggle.setButtonType(.pushOnPushOff)
        sentToggle.bezelStyle = .disclosure
        sentToggle.title = ""
        sentToggle.target = target
        sentToggle.action = toggleSent
        sentToggle.setAccessibilityLabel("What’s sent")
        let sentLabel = NSTextField(labelWithString: "What’s sent")
        sentLabel.font = .systemFont(ofSize: 11)
        sentLabel.textColor = .secondaryLabelColor
        sentRow = NSStackView(views: [sentToggle, sentLabel])
        sentRow.spacing = 4

        sentScroll = NSTextView.scrollableTextView()
        sentText = sentScroll.documentView as! NSTextView
        sentText.isEditable = false
        sentText.isSelectable = true
        sentText.isRichText = false
        sentText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sentText.textContainerInset = NSSize(width: 4, height: 4)
        sentText.setAccessibilityLabel("What’s sent")
        sentScroll.borderType = .bezelBorder
        sentScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let offer = NSTextField(labelWithString: "Tasks go to the todo folder. Send them to Reminders or Things instead?")
        offer.font = .systemFont(ofSize: 11)
        offer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        offerChoose = NSButton(title: "Choose…", target: target, action: choose)
        offerChoose.controlSize = .small
        offerClose = NSButton(title: "×", target: target, action: dismissOffer)
        offerClose.controlSize = .small
        offerClose.isBordered = false
        offerClose.setAccessibilityLabel("Don’t Ask Again")
        offerClose.toolTip = "Keep the todo folder, and don’t ask again."
        offerRow = NSStackView(views: [offer, offerChoose, offerClose])
        offerRow.spacing = 6
        offerRow.isHidden = true

        sentToggle.state = Self.sentOpen ? .on : .off
        sentScroll.isHidden = !Self.sentOpen
    }

    /// The Destination popup's rows, then a separator and Set Up Destinations…; `selected` is the row chosen.
    func fill(_ rows: [DestinationChoices.Row], selected: Int, setUp: Selector, target: AnyObject) {
        destination.removeAllItems()
        for (index, row) in rows.enumerated() {
            destination.addItem(withTitle: row.title)
            destination.lastItem?.tag = index
            destination.lastItem?.isEnabled = row.enabled
        }
        destination.menu?.addItem(.separator())
        let item = NSMenuItem(title: "Set Up Destinations…", action: setUp, keyEquivalent: "")
        item.target = target
        item.tag = -1
        destination.menu?.addItem(item)
        destination.selectItem(withTag: selected)
    }

    /// The Agent tab popup's rows: each tab running an agent, a tab that isn't ready greyed with why.
    func fill(_ choices: [TaskAgentRequest.Choice], selected: Int?) {
        agent.removeAllItems()
        for (index, choice) in choices.enumerated() {
            agent.addItem(withTitle: choice.title)
            agent.lastItem?.tag = index
            agent.lastItem?.isEnabled = choice.isReady
        }
        if choices.isEmpty { agent.addItem(withTitle: "No agent tab") }
        if let selected {
            agent.selectItem(withTag: selected)
            return
        }
        // No tab is ready: the popup shows that rather than a greyed tab as if it were picked.
        guard !choices.isEmpty else { return }
        agent.insertItem(withTitle: "No Tab Is Ready", at: 0)
        agent.item(at: 0)?.tag = -1
        agent.item(at: 0)?.isEnabled = false
        agent.selectItem(at: 0)
    }

    func showSent(_ open: Bool) {
        Self.sentOpen = open
        sentToggle.state = open ? .on : .off
        sentScroll.isHidden = !open
    }
}
