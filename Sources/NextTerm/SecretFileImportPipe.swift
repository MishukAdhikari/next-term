import AppKit
import NextTermCore

/// The copy sheet for keys piped into `nxtrm secret import`: there is no file, so nothing goes to the Trash and no line
/// says a file still holds them. The header names a preset only when its tab ran its line as typed, else the tab by its
/// place; under it, a warning when an agent ran the command or no tab did. The done view says how to end the password
/// manager's session, going by the line the tab's shell said it ran: Bitwarden is locked again when that line ends
/// with bw lock, and 1Password's authorization lasts until its tab closes, which Close Tab does with the tab's own
/// close rules (never an agent's tab).
extension SecretFileImportSheet {
    static let closeTabTitle = "Close Tab"

    /// Keys on standard input, with no file.
    var isPiped: Bool { client?.origin.piped == true }

    /// Where piped keys came from, as the Touch ID line and Recent imports name them: "1Password", "standard input".
    var pipedSource: String {
        if let preset = client?.origin.preset { return preset.app }
        return report?.exportedBy ?? SecretPipeImport.standardInput
    }

    /// "From 1Password, through op in the tab Import from 1Password." or "From standard input in tab 2 of rag-api,
    /// read as a .env file."
    func pipedHeader(_ report: SourceReport) -> String {
        let origin: SecretPipeImport.Origin? = client?.origin
        if let preset = origin?.preset {
            return "From \(preset.app), through \(preset.program) in the tab \u{201C}\(preset.tabTitle)\u{201D}."
        }
        let place: String = origin?.place.map { (text: String) -> String in " in \(text)" } ?? ""
        let source: String = report.exportedBy ?? SecretPipeImport.standardInput
        return "From \(source)\(place), piped into nxtrm secret import, read as \(Self.pipedFormatText(report))."
    }

    /// How piped keys were read: a password manager's items, not an export file.
    static func pipedFormatText(_ report: SourceReport) -> String {
        switch report.format {
        case .onePassword: return "1Password\u{2019}s items"
        case .bitwarden: return "Bitwarden\u{2019}s items"
        case .bws: return "Bitwarden Secrets Manager\u{2019}s secrets"
        default: return formatText(report)
        }
    }

    /// The warning under the header: an agent ran the importer, or no tab did, so an agent may have seen the keys.
    func addOriginWarning(_ text: String) {
        guard let stack = headerLabel.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: headerLabel) else { return }
        let warning: NSTextField = Self.warning(text)
        stack.insertArrangedSubview(warning, at: index + 1)
        warning.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
    }

    /// How to end the password manager's session, once keys came from it.
    var pipedDoneLine: String? {
        guard isPiped, let format = report?.format, let origin = client?.origin else { return nil }
        return SecretImportPreset.sessionLine(format: format, command: origin.command, tabPreset: origin.tabPreset,
                                              inTab: origin.tabID != nil)
    }

    /// Close Tab, for the tab 1Password's authorization lasts in; never an agent's tab.
    func addCloseTab() {
        guard pipedDoneLine == SecretImportPreset.onePasswordLine, client?.origin.agent == nil else { return }
        let button = NSButton(title: Self.closeTabTitle, target: self, action: #selector(closeImportTab))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("Close the tab the import ran in")
        addDone(button)
    }

    /// The sheet ends first, so the importer hears how it ended and leaves; then the tab closes as ⌘W would close it.
    @objc func closeImportTab() {
        guard let id = client?.origin.tabID else { return }
        finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let tabs: [TerminalTab] = AppDelegate.shared.controllers.flatMap(\.tabs)
            guard let tab = tabs.first(where: { (tab: TerminalTab) -> Bool in tab.id == id }),
                  let controller = MCPControl.controller(of: tab) else { return }
            controller.requestClose(tab)
        }
    }
}
