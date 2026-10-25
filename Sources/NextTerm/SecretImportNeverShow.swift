import AppKit
import NextTermCore

/// "Never show" on each row of an import: Import from MCP Configs, and Import from a File (which piped keys, the
/// password managers and an agent's import_secrets also open). Each box starts as Settings › Secrets' New keys default
/// says, and a key ticked so is saved write-only.
extension SecretImportSheet {
    static let neverShowTitle = "Never show"
    static let neverShowHelp = "Next Term never shows or copies this key once it\u{2019}s in Secrets. Commands you allow still get it."

    /// The confirm's line for the keys it saves never shown. A move's Undo puts values back into the configs, which it
    /// can't do for these (`inConfigs`); a copy-in's Undo only deletes keys.
    static func neverShownNote(_ names: [String], inConfigs: Bool = true) -> String {
        let one: Bool = names.count == 1
        let lead: String = "\(SecretRun.keysText(names)) will never be shown"
        guard inConfigs else { return lead + ". This can\u{2019}t be undone." }
        return lead + ", so Undo can\u{2019}t put " + (one ? "it" : "them") + " back into your configs."
    }
}

extension FileImportRow {
    static let neverShowHeader = "Never show"

    /// A row's "Never show" box: off for a value that can't be stored, as its tick is.
    static func neverShowBox(for row: SourceRow) -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.state = SecretNewKeyDefaults.neverShow ? .on : .off
        box.isEnabled = row.refusal == nil
        box.toolTip = SecretImportSheet.neverShowHelp
        box.setAccessibilityLabel("Never show \(row.name)")
        return box
    }
}
