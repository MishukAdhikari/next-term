import Foundation
import Testing

/// Every colour the app draws comes from the theme: a ThemePalette token (through Theme), or, in a native window
/// (Settings, a sheet, an alert), the Mac's own named colour. So a new theme is one more palette and nothing else, and
/// Next Term Dark keeps every colour it has (ThemeUITokenTests freezes them).
@Suite struct ThemeTokenTests {
    /// A colour written by hand: a hex or component value, white or black by name, a mark's literal. None anywhere in
    /// the views: a new colour is a ThemePalette token (UIToken), with Next Term Dark's value in the palette.
    static let literal = try! NSRegularExpression(pattern: [
        #"NSColor\(hex: *0x"#,
        #"NSColor\((calibratedWhite|white|srgbRed|calibratedRed|deviceWhite|deviceRed|red|displayP3Red|genericGamma22White|hue): *[0-9.]"#,
        #"CGColor\((srgbRed|red|gray|genericGrayGamma2_2Gray): *[0-9.]"#, #"CGColor\.(white|black)\b"#,
        #"NSColor\.(white|black|red|green|blue|gray|orange|yellow|darkGray|lightGray|brown|cyan|magenta|purple)\b"#,
        #"[(:=,?] *\.(white|black)\b"#, #"of: *\.(white|black)\b"#, #"Theme\.mark\(0x"#, #"\[0x[0-9A-Fa-f]{6}"#,
    ].joined(separator: "|"))

    /// The literals left, each a reviewed exception that is not a colour on screen.
    static let allowedLiterals: [String: Int] = [
        "PlaceMarks.swift": 1, // the stroke of a template image: only its shape is drawn, in the menu's own colour
    ]

    /// The Mac's named colours (labelColor, systemRed…) used directly. On a themed surface they go through
    /// `Theme.system(_:)`, the same colour in Next Term's own looks and the theme's in a named theme; these files draw
    /// native windows (Settings, sheets, alerts, the system `/` menu), where the Mac's colours are the right ones.
    /// A count may only go down.
    static let allowedSystem: [String: Int] = [
        // The sidebar is a source list: AppKit draws a selected row in the Mac's accent in every theme, so its name is
        // the Mac's text for that fill (alternateSelectedControlTextColor), not a theme's.
        "SidebarCells.swift": 1,
        "AcknowledgementsWindow.swift": 2, "AddTaskDestinationViews.swift": 1, "AddTaskSheet.swift": 3,
        "AgentApprovalWindow.swift": 2, "AgentSessionSheet.swift": 1, "AgentsSettingsView.swift": 3,
        "AlternativeAlert.swift": 4, "AppDelegate.swift": 1, "Appearance.swift": 3, "ApprovalLayout.swift": 17,
        "CommandSuggestionPanel.swift": 1, "CommitSheet.swift": 7, "CompletionSettings.swift": 4,
        "ConnectTrackerSheetBuild.swift": 2, "GeneralSettingsView.swift": 1, "GhostSettings.swift": 1,
        "GitWorktrees.swift": 7, "HandoverPicker.swift": 1, "ImportUI.swift": 5, "KeyboardShortcuts.swift": 4,
        "LayoutPickerSheet.swift": 8, "LiveChatToggle.swift": 1, "MCPPasteSheet.swift": 10, "MCPServerSheet.swift": 8,
        "MCPServersSettingsView.swift": 16, "NotificationsUI.swift": 2, "PostUpdateSheet.swift": 1,
        "ProjectSkillsView.swift": 19, "RemoteCompletionConsent.swift": 1, "RemoteTabSheet.swift": 4,
        "ReviewDraft.swift": 2, "SecretApprovalPanel.swift": 11, "SecretEditSheet.swift": 7,
        "SecretFileImportDone.swift": 2, "SecretFileImportRow.swift": 6, "SecretFileImportSheet.swift": 3,
        "SecretImportBanner.swift": 3, "SecretImportSheet.swift": 12, "SecretLinkField.swift": 2,
        "RemoteAccessActivityView.swift": 3, "RemoteAccessConnectionsView.swift": 6, "RemoteAccessOptionsView.swift": 7,
        "RemoteAccessPairingWindow.swift": 7, "RemoteAccessSecuritySection.swift": 8, "RemoteAccessSettingsView.swift": 29, // Settings › Remote Access and its pairing window: native windows
        "SecretManagerImportSheetBuild.swift": 2, "SecretNewKeySettingsView.swift": 1, "SecretReminders.swift": 1,
        "SecretRequestWindow.swift": 6, "SecretRotateSheet.swift": 4, "SecretsSkillSettingView.swift": 2,
        "SecretsView.swift": 18, "SecretsViewAlways.swift": 2, "SecretsViewNeverShow.swift": 1,
        "SetupWithAgent.swift": 1, "SkillsClaudeChoice.swift": 3, "SkillsReviewSheet.swift": 1,
        "SkillsSettingsView.swift": 7, "SkillsWindow.swift": 7, "SlashMenu.swift": 5, "TabBarView.swift": 2,
        "TaskDestinationsView.swift": 3, "TaskHandoffFolderRow.swift": 2, "TaskSettingsView.swift": 2,
        "UpdateKeepSessions.swift": 3, "UpdateWindow.swift": 13, "WrapUpSheet.swift": 4,
    ]

    static let system = try! NSRegularExpression(pattern:
        #"(= |: |\(|\? |, |NSColor)\.(labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor|placeholderTextColor|separatorColor|windowBackgroundColor|controlBackgroundColor|textBackgroundColor|underPageBackgroundColor|controlAccentColor|keyboardFocusIndicatorColor|selectedContentBackgroundColor|unemphasizedSelectedContentBackgroundColor|alternateSelectedControlTextColor|selectedTextBackgroundColor|linkColor|controlTextColor|textColor|systemRed|systemGreen|systemOrange|systemBlue|systemYellow|systemPurple|systemPink|systemTeal|systemIndigo|systemGray|systemBrown|systemMint|systemCyan|shadowColor|gridColor|headerTextColor|disabledControlTextColor|selectedMenuItemTextColor)\b"#)

    static func matches(_ pattern: NSRegularExpression, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { count, line in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("//") { return count } // a comment names a colour; it doesn't draw one
            let line = String(line)
            return count + pattern.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
        }
    }

    static func views() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NextTerm")
        let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") && !($0 as NSString).lastPathComponent.hasPrefix("SelfTest") && $0 != "Theme.swift" }
        return try names.sorted().map { (($0 as NSString).lastPathComponent, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test func viewsWriteNoColourByHand() throws {
        let files = try Self.views()
        #expect(files.count > 100, "the app's views were found")
        var over: [String] = []
        for file in files {
            let count = Self.matches(Self.literal, in: file.text)
            if count > Self.allowedLiterals[file.name, default: 0] { over.append("\(file.name): \(count)") }
        }
        #expect(over.isEmpty, "colours written by hand; use a ThemePalette token (Theme.ui) instead: \(over.joined(separator: ", "))")
    }

    @Test func themedViewsTakeTheMacsColoursThroughTheTheme() throws {
        var over: [String] = []
        for file in try Self.views() {
            let count = Self.matches(Self.system, in: file.text)
            if count > Self.allowedSystem[file.name, default: 0] { over.append("\(file.name): \(count) (allowed \(Self.allowedSystem[file.name, default: 0]))") }
        }
        #expect(over.isEmpty, "the Mac's colours on a themed surface; use Theme.system(_:) (a native window's file goes in allowedSystem): \(over.joined(separator: ", "))")
    }

    /// `Theme.pair` joins two token colours (a token at two alphas), never a literal.
    @Test func pairsJoinTokensOnly() throws {
        let literalPair = try NSRegularExpression(pattern: #"Theme\.pair\([^\n]*(NSColor\(hex|\.white\b|\.black\b|0x[0-9A-Fa-f])"#)
        let found = try Self.views().filter { Self.matches(literalPair, in: $0.text) > 0 }.map(\.name)
        #expect(found.isEmpty, "Theme.pair with a literal: \(found)")
    }
}
