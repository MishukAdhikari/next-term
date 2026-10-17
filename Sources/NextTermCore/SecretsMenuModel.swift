import Foundation

/// The Secrets menu's rules, kept apart from AppKit so they are tested: which items are on, the Pause item's title, the
/// rows of Keys Due to Rotate, and the titles and tooltips. A title, tooltip or badge holds key names and counts only:
/// never a value, any part of one, or a link.
public enum SecretsMenuModel {
    /// What the menu reads to turn its items on, all of it in memory: no disk, no Touch ID.
    public struct State: Equatable, Sendable {
        /// The vault can't be opened on this Mac, or was changed outside Next Term (`cantOpen` or `tampered`).
        public var broken: Bool
        /// A request is in its panel, its window or its import sheet now.
        public var showingRequest: Bool
        /// Requests not answered yet, the one showing among them.
        public var waiting: Int
        /// Approvals in force.
        public var grants: Int
        /// When the hour's pause ends, while it runs.
        public var pausedUntil: Date?

        public init(broken: Bool = false, showingRequest: Bool = false, waiting: Int = 0, grants: Int = 0,
                    pausedUntil: Date? = nil) {
            self.broken = broken
            self.showingRequest = showingRequest
            self.waiting = waiting
            self.grants = grants
            self.pausedUntil = pausedUntil
        }
    }

    /// The menu's commands that can be off. The due rows follow `broken` alone.
    public enum Command: String, CaseIterable, Sendable {
        case show, add, importFile, importMCP, importManager, showRequest, pause, revokeAll
    }

    /// Whether `command`'s item is on. Show Secrets and Pause/Resume always are. Add and the imports are off only while
    /// the vault is broken: with no vault yet, the first Add makes it. Show Key Request needs a request showing, and
    /// Revoke All Approvals… an approval in force.
    public static func isEnabled(_ command: Command, _ state: State) -> Bool {
        switch command {
        case .show, .pause: return true
        case .add, .importFile, .importMCP, .importManager: return !state.broken
        case .showRequest: return state.showingRequest
        case .revokeAll: return state.grants > 0
        }
    }

    /// Show Key Request's badge: the unanswered requests while one shows, else none, so an item that is off never
    /// carries a count.
    public static func requestCount(_ state: State) -> Int {
        state.showingRequest ? max(1, state.waiting) : 0
    }

    /// Pause and Resume are one item: its title while no pause runs, and while one does.
    public static func pauseTitle(_ pausedUntil: Date?) -> String {
        pausedUntil == nil ? pauseItemTitle : resumeTitle
    }

    /// Resume's tooltip: "Paused until 4:02 PM.", the clock as the list says it.
    public static func pausedHelp(_ clock: String) -> String {
        "Paused until \(clock)."
    }

    /// Revoke All Approvals…' confirm: how many approvals it ends.
    public static func revokeConfirmText(_ count: Int) -> String {
        let approvals: String = count == 1 ? "1 approval" : "\(count) approvals"
        return "This ends \(approvals) you gave. The next use of each key asks again."
    }

    /// "Keys Due to Rotate (3)": the count in the title where macOS 13 has no menu badge. Zero leaves it plain.
    public static func countedTitle(_ title: String, count: Int) -> String {
        count > 0 ? "\(title) (\(count))" : title
    }

    /// The last row when more keys are due than the submenu lists.
    public static func moreTitle(_ count: Int) -> String {
        "Show All \(count) in Secrets"
    }

    /// "1Password…", "Bitwarden…", "Bitwarden Secrets Manager…", as the list's Import From names them.
    public static func managerTitle(_ preset: SecretImportPreset) -> String {
        preset.app + "\u{2026}"
    }
}

// MARK: Keys Due to Rotate

extension SecretsMenuModel {
    /// The submenu lists this many due keys at most, as Open Recent does, then Show All.
    public static let dueLimit = 10

    /// One row of Keys Due to Rotate.
    public enum DueRow: Equatable, Sendable {
        /// A due key: its name, and its age and reminder as the Rotated cell's tooltip says them.
        case key(name: String, help: String)
        /// More keys are due than are listed: how many, and the first, which Show All selects.
        case more(count: Int, first: String)
        /// No key is due: one row, off.
        case none
        /// The vault is broken: one row, off, whatever is due.
        case cantChange
    }

    /// The submenu's rows, in the list's order: each due key, at most `dueLimit`, then `.more` when there are more.
    /// A write-only key that is due is listed: its name is no secret, and Rotate… needs no value shown.
    public static func dueRows(entries: [SecretVault.Entry], broken: Bool, now: Date,
                               calendar: Calendar = .current) -> [DueRow] {
        guard !broken else { return [.cantChange] }
        let due: [SecretVault.Entry] = dueEntries(entries, now: now, calendar: calendar)
        guard let first = due.first else { return [.none] }
        var rows: [DueRow] = due.prefix(dueLimit).map { (entry: SecretVault.Entry) -> DueRow in
            let help: String = SecretAge.dueHelp(entry: entry, now: now, calendar: calendar) ?? ""
            return .key(name: entry.name, help: help)
        }
        if due.count > dueLimit { rows.append(.more(count: due.count, first: first.name)) }
        return rows
    }

    /// Keys Due to Rotate's badge: every due key, listed or not; none while the vault is broken.
    public static func dueCount(entries: [SecretVault.Entry], broken: Bool, now: Date, calendar: Calendar = .current) -> Int {
        broken ? 0 : dueEntries(entries, now: now, calendar: calendar).count
    }

    private static func dueEntries(_ entries: [SecretVault.Entry], now: Date, calendar: Calendar) -> [SecretVault.Entry] {
        entries.filter { (entry: SecretVault.Entry) -> Bool in SecretAge.due(entry: entry, now: now, calendar: calendar) }
    }
}

// MARK: Titles, tooltips and ids

extension SecretsMenuModel {
    public static let menuTitle = "Secrets"
    public static let showTitle = "Show Secrets"
    public static let addTitle = "Add Key\u{2026}"
    /// The parent names no action of its own, so it has no "…", as Safari's File › Import From.
    public static let importTitle = "Import From"
    public static let importFileTitle = "A File\u{2026}"
    public static let importMCPTitle = "MCP Configs\u{2026}"
    public static let dueTitle = "Keys Due to Rotate"
    public static let noneDueTitle = "No Keys Due"
    public static let cantChangeTitle = "Secrets Can\u{2019}t Change Keys Now"
    public static let showRequestTitle = "Show Key Request"
    public static let pauseItemTitle = "Pause Key Requests for 1 Hour\u{2026}"
    public static let resumeTitle = "Resume Key Requests"
    /// It opens the Secrets window and confirms in a sheet there, so it has the "…".
    public static let revokeAllTitle = "Revoke All Approvals\u{2026}"

    public static let importFileHelp = "Copies keys from a .env file, a config or a password manager\u{2019}s export into "
        + "Secrets. You choose them first, and the file isn\u{2019}t changed."
    public static let importMCPHelp = "Moves keys out of your MCP configs into Secrets. You choose them before anything changes."
    public static let importManagerHelp = "Shows the line for its own command-line tool. Next Term types it into a new tab "
        + "and never runs it: you press Return."
    public static let noneDueHelp = "Set \u{201C}Remind me to rotate\u{201D} in a key\u{2019}s Edit\u{2026} sheet to be reminded."
    public static let showRequestHelp = "An agent or command is waiting for your answer. You answer it in its window."
    public static let noRequestHelp = "No agent or command is asking for a key now."
    public static let pauseHelp = "Declines every waiting request, refuses new ones for an hour, and ends every approval you gave."
    /// The list's Revoke help follows it in the tooltip.
    public static let revokeAllHelp = "Ends every approval you gave."
    public static let noGrantsHelp = "No approval is in force now."

    /// Revoke All Approvals…' confirm, on the Secrets window.
    public static let revokeConfirmTitle = "Revoke all approvals?"
    public static let revokeButton = "Revoke"
    /// The line under the list after Resume Key Requests.
    public static let resumedLine = "Key requests resumed."
    /// The line under the list when a menu item meets a sheet already open there.
    public static let busyLine = "Finish or cancel what\u{2019}s open first."

    /// Every fixed title, for the typography check.
    public static let titles: [String] = [menuTitle, showTitle, addTitle, importTitle, importFileTitle, importMCPTitle,
                                          dueTitle, noneDueTitle, cantChangeTitle, showRequestTitle, pauseItemTitle,
                                          resumeTitle, revokeAllTitle, revokeConfirmTitle, revokeButton]
    /// Every fixed tooltip and line.
    public static let tooltips: [String] = [importFileHelp, importMCPHelp, importManagerHelp, noneDueHelp, showRequestHelp,
                                            noRequestHelp, pauseHelp, revokeAllHelp, noGrantsHelp, resumedLine, busyLine]

    /// The menu's commands as Settings › Keyboard Shortcuts names them (`KeyboardShortcuts.id(of:)`): the bindable
    /// ones, none with a default key. The due rows are never among them.
    public static let commandIDs: [String] = {
        var ids: [String] = ["showSecrets:", "addSecretKey:", "importSecretsFromFile:", "importSecretsFromMCPConfigs:"]
        for preset in SecretImportPreset.allCases { ids.append("importSecretsFromManager:" + preset.rawValue) }
        ids += ["showKeyRequest:", "toggleKeyRequestPause:", "revokeAllSecretApprovals:"]
        return ids
    }()
}
