import Foundation
import Testing
@testable import NextTermCore

/// The Secrets menu's rules: which items are on, the Pause item's title, the rows of Keys Due to Rotate, the counted
/// titles, and the typography and "no default key" decisions. Every key and date is made up.
@Suite struct SecretsMenuModelTests {
    typealias Model = SecretsMenuModel

    static let calendar: Calendar = SecretAgeTests.calendar
    static let now: Date = SecretAgeTests.now

    /// A made-up key whose value was last set `days` days before now, with a reminder of `remind` days (nil: none).
    static func entry(_ name: String, setDaysAgo days: Int, remind: Int?, writeOnly: Bool = false) -> SecretVault.Entry {
        let set: Date = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        // Added a month before its value was last set: it reads "94 days ago", not "Added 94 days ago".
        let created: Date = calendar.date(byAdding: .day, value: -30, to: set) ?? set
        var entry = SecretVault.Entry(id: "made-up-" + name, name: name, purpose: "", purposeBy: .user, origin: .settings,
                                      writeOnly: writeOnly, created: created, changed: set, box: Data(), marks: [])
        entry.valueSet = set
        entry.remindDays = remind
        return entry
    }

    static func rows(_ entries: [SecretVault.Entry], broken: Bool = false) -> [Model.DueRow] {
        Model.dueRows(entries: entries, broken: broken, now: now, calendar: calendar)
    }

    static func names(_ rows: [Model.DueRow]) -> [String] {
        rows.compactMap { (row: Model.DueRow) -> String? in
            if case .key(let name, _) = row { return name }
            return nil
        }
    }

    // MARK: on and off

    @Test func showAndPauseAreAlwaysOn() {
        let states: [Model.State] = [Model.State(), Model.State(broken: true), Model.State(pausedUntil: Self.now)]
        for state in states {
            #expect(Model.isEnabled(.show, state))
            #expect(Model.isEnabled(.pause, state))
        }
    }

    @Test func addAndTheImportsAreOffOnlyWhenBroken() {
        let imports: [Model.Command] = [.add, .importFile, .importMCP, .importManager]
        for command in imports {
            #expect(!Model.isEnabled(command, Model.State(broken: true)))
            // No vault yet is not broken: the first Add makes it.
            #expect(Model.isEnabled(command, Model.State()))
        }
    }

    @Test func showKeyRequestIsOnOnlyWhileARequestShows() {
        #expect(!Model.isEnabled(.showRequest, Model.State()))
        #expect(!Model.isEnabled(.showRequest, Model.State(waiting: 2)))
        #expect(Model.isEnabled(.showRequest, Model.State(showingRequest: true, waiting: 1)))
    }

    @Test func revokeAllNeedsAnApprovalInForce() {
        #expect(!Model.isEnabled(.revokeAll, Model.State()))
        #expect(!Model.isEnabled(.revokeAll, Model.State(broken: true)))
        #expect(Model.isEnabled(.revokeAll, Model.State(grants: 1)))
        #expect(Model.isEnabled(.revokeAll, Model.State(broken: true, grants: 3)))
    }

    @Test func theRequestBadgeCountsOnlyWhileOneShows() {
        #expect(Model.requestCount(Model.State()) == 0)
        // Waiting for a tab's pipe, with nothing on screen: no badge on an item that is off.
        #expect(Model.requestCount(Model.State(waiting: 2)) == 0)
        #expect(Model.requestCount(Model.State(showingRequest: true, waiting: 3)) == 3)
        #expect(Model.requestCount(Model.State(showingRequest: true, waiting: 0)) == 1)
    }

    // MARK: Pause and Resume

    @Test func pauseIsOneItemWhoseTitleFollowsThePause() {
        #expect(Model.pauseTitle(nil) == "Pause Key Requests for 1 Hour\u{2026}")
        #expect(Model.pauseTitle(Self.now) == "Resume Key Requests")
        #expect(Model.pausedHelp("4:02 PM") == "Paused until 4:02 PM.")
    }

    @Test func pauseAsksOverAnAgentsImportSheetButOverNoOtherSheet() {
        #expect(Model.pauseConfirm(listHasSheet: false, requestSheetOnly: false, copying: false) == .onList)
        // An agent's import_secrets sheet has no Pause of its own: Pause asks over it, and ends that request.
        #expect(Model.pauseConfirm(listHasSheet: true, requestSheetOnly: true, copying: false) == .overRequest)
        // Copying keys in, nothing closes the sheet; and a sheet the user opened, or one over the request's, is theirs.
        #expect(Model.pauseConfirm(listHasSheet: true, requestSheetOnly: true, copying: true) == .busy)
        #expect(Model.pauseConfirm(listHasSheet: true, requestSheetOnly: false, copying: false) == .busy)
    }

    @Test func revokeAllsConfirmSaysHowManyApprovalsItEnds() {
        #expect(Model.revokeConfirmText(3) == "This ends 3 approvals you gave. The next use of each key asks again.")
        #expect(Model.revokeConfirmText(1) == "This ends 1 approval you gave. The next use of each key asks again.")
        #expect(Model.revokeConfirmTitle == "Revoke all approvals?")
    }

    // MARK: Keys Due to Rotate

    @Test func noKeyDueGivesOneRowAndBrokenGivesAnother() {
        #expect(Self.rows([]) == [.none])
        #expect(Self.rows([Self.entry("FRESH_KEY", setDaysAgo: 2, remind: 30)]) == [.none])
        // Broken: whatever is due, the one row says Secrets can't change keys.
        let due: [SecretVault.Entry] = [Self.entry("OLD_KEY", setDaysAgo: 100, remind: 90)]
        #expect(Self.rows(due, broken: true) == [.cantChange])
        #expect(Model.dueCount(entries: due, broken: true, now: Self.now, calendar: Self.calendar) == 0)
    }

    @Test func dueKeysComeInTheListsOrderWithTheirHelp() {
        let one: [SecretVault.Entry] = [Self.entry("FIRST_DUE_KEY", setDaysAgo: 94, remind: 90)]
        let help = "94 days ago. Due: you asked to be reminded to rotate it after 90 days."
        #expect(Self.rows(one) == [.key(name: "FIRST_DUE_KEY", help: help)])
        let three: [SecretVault.Entry] = [Self.entry("ZETA_KEY", setDaysAgo: 40, remind: 30),
                                          Self.entry("NOT_DUE_KEY", setDaysAgo: 3, remind: 30),
                                          Self.entry("ALPHA_KEY", setDaysAgo: 10, remind: 7),
                                          Self.entry("MID_KEY", setDaysAgo: 400, remind: 365)]
        #expect(Self.names(Self.rows(three)) == ["ZETA_KEY", "ALPHA_KEY", "MID_KEY"])
        #expect(Model.dueCount(entries: three, broken: false, now: Self.now, calendar: Self.calendar) == 3)
    }

    @Test func aWriteOnlyKeyIsListedAndAKeyWithNoReminderNever() {
        let entries: [SecretVault.Entry] = [Self.entry("HIDDEN_DUE_KEY", setDaysAgo: 31, remind: 30, writeOnly: true),
                                            Self.entry("NO_REMINDER_KEY", setDaysAgo: 2000, remind: nil)]
        #expect(Self.names(Self.rows(entries)) == ["HIDDEN_DUE_KEY"])
    }

    @Test func exactlyTheReminderAgeCountsAsDue() {
        #expect(Self.names(Self.rows([Self.entry("EDGE_KEY", setDaysAgo: 30, remind: 30)])) == ["EDGE_KEY"])
        #expect(Self.rows([Self.entry("EDGE_KEY", setDaysAgo: 29, remind: 30)]) == [.none])
    }

    @Test func atMostTenRowsThenShowAll() {
        let ten: [SecretVault.Entry] = (1...10).map { (n: Int) -> SecretVault.Entry in
            Self.entry("DUE_KEY_\(n)", setDaysAgo: 50, remind: 30)
        }
        let tenRows: [Model.DueRow] = Self.rows(ten)
        #expect(tenRows.count == 10 && Self.names(tenRows).count == 10)
        let eleven: [SecretVault.Entry] = ten + [Self.entry("DUE_KEY_11", setDaysAgo: 50, remind: 30)]
        let elevenRows: [Model.DueRow] = Self.rows(eleven)
        #expect(Self.names(elevenRows) == ten.map(\.name))
        #expect(elevenRows.last == .more(count: 11, first: "DUE_KEY_1"))
        #expect(elevenRows.count == 11)
        #expect(Model.dueLimit == 10)
        #expect(Model.moreTitle(11) == "Show All 11 in Secrets")
    }

    @Test func aCountedTitleShowsOnlyACountAboveZero() {
        #expect(Model.countedTitle(Model.dueTitle, count: 0) == "Keys Due to Rotate")
        #expect(Model.countedTitle(Model.dueTitle, count: 3) == "Keys Due to Rotate (3)")
        #expect(Model.countedTitle(Model.showRequestTitle, count: 1) == "Show Key Request (1)")
    }

    // MARK: typography and keys

    @Test func titlesUseTheEllipsisAndCurlyQuotes() {
        for text in Model.titles + Model.tooltips {
            #expect(!text.contains("..."), "\(text)")
            #expect(!text.contains("'"), "\(text)")
            #expect(!text.contains("\""), "\(text)")
        }
        let asking: [String] = [Model.addTitle, Model.importFileTitle, Model.importMCPTitle, Model.pauseTitle(nil),
                                Model.revokeAllTitle] + SecretImportPreset.allCases.map(Model.managerTitle)
        for title in asking { #expect(title.hasSuffix("\u{2026}"), "\(title)") }
        let acting: [String] = [Model.showTitle, Model.importTitle, Model.dueTitle, Model.showRequestTitle, Model.resumeTitle,
                                Model.noneDueTitle, Model.cantChangeTitle, Model.moreTitle(12)]
        for title in acting { #expect(!title.contains("\u{2026}"), "\(title)") }
        #expect(Model.cantChangeTitle == "Secrets Can\u{2019}t Change Keys Now")
        #expect(SecretImportPreset.allCases.map(Model.managerTitle)
                == ["1Password\u{2026}", "Bitwarden\u{2026}", "Bitwarden Secrets Manager\u{2026}"])
    }

    @Test func aFilesTooltipSaysAnMCPConfigIsChanged() {
        // A File… hands an MCP config to the MCP-config import, which rewrites it once the user chooses.
        #expect(!Model.importFileHelp.contains("isn\u{2019}t changed"))
        #expect(Model.importFileHelp.contains("Only an MCP config is changed"))
    }

    @Test func noSecretsCommandHasADefaultKey() {
        #expect(Model.commandIDs.contains("showSecrets:"))
        #expect(Model.commandIDs.contains("importSecretsFromMCPConfigs:"))
        #expect(Model.commandIDs.contains("importSecretsFromManager:bws"))
        #expect(Set(Model.commandIDs).count == Model.commandIDs.count)
        for id in Model.commandIDs { #expect(MenuKeys.defaults[id] == nil, "\(id)") }
    }
}
