import AppKit
import NextTermCore

/// Settings › Secrets' defaults for new keys. They live beside the reminders' settings (`SecretReminderRecords.defaults`),
/// not in the vault, so changing them asks for no Touch ID. Names of settings only, never a value.
@MainActor
enum SecretNewKeyDefaults {
    /// "Never show their values": off unless set.
    static let neverShowKey = "secretsNewKeyNeverShow"
    /// "Ask for Touch ID every time they’re used": on unless turned off.
    static let asksEveryUseKey = "secretsNewKeyAsksEveryUse"

    /// Whether "Never show this key" starts ticked in Add…, `request_secret`'s window and every import row.
    static var neverShow: Bool {
        get { SecretReminderRecords.defaults.object(forKey: neverShowKey) as? Bool ?? false }
        set { SecretReminderRecords.defaults.set(newValue, forKey: neverShowKey) }
    }

    /// Whether a new key asks for Touch ID every time it's used: Add…'s box starts so, and every other new key
    /// (`request_secret`, `store_secret`, the imports) is saved so.
    static var asksEveryUse: Bool {
        get { SecretReminderRecords.defaults.object(forKey: asksEveryUseKey) as? Bool ?? true }
        set { SecretReminderRecords.defaults.set(newValue, forKey: asksEveryUseKey) }
    }

    /// A key's own box, in Add… and Edit….
    static let keyNeverShowTitle = "Never show this key"
    static let keyAsksTitle = "Ask for Touch ID every time it\u{2019}s used"
    static let keyAsksHelp = "When it\u{2019}s off, you can allow a command to use it for 15 minutes, or until the Mac locks."
    /// The list's lock mark.
    static let neverShownHelp = "Never shown"
}

/// Settings › Secrets' New keys group, under the list (the Secrets window shows it too): "Never show their values" and
/// "Ask for Touch ID every time they’re used". A change in one window shows in the other.
@MainActor
final class SecretNewKeySettingsView: NSStackView {
    static let changed = Notification.Name("NextTermSecretNewKeySettingsChanged")
    static let heading = "New keys"
    static let neverShowTitle = "Never show their values"
    static let neverShowHelp = "Ticks \u{201C}Never show this key\u{201D} when you add a key, when an agent asks you for one, "
        + "and on each row of an import. Commands you allow still get them."
    static let asksTitle = "Ask for Touch ID every time they\u{2019}re used"
    static let asksHelp = "Each use of a key asks again, with no approval for 15 minutes or until the Mac locks. Untick it for "
        + "one key in its Edit\u{2026} sheet."

    private(set) var neverShowBox = NSButton(checkboxWithTitle: SecretNewKeySettingsView.neverShowTitle, target: nil, action: nil)
    private(set) var asksBox = NSButton(checkboxWithTitle: SecretNewKeySettingsView.asksTitle, target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let heading = NSTextField(labelWithString: Self.heading)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        neverShowBox.target = self
        neverShowBox.action = #selector(neverShowChanged)
        asksBox.target = self
        asksBox.action = #selector(asksChanged)
        let neverShowHelp: NSTextField = Self.help(Self.neverShowHelp)
        let asksHelp: NSTextField = Self.help(Self.asksHelp)
        for view in [heading, neverShowBox, neverShowHelp, asksBox, asksHelp] { addArrangedSubview(view) }
        for view in [neverShowHelp, asksHelp] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Self.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static func help(_ text: String) -> NSTextField {
        let label = SecretApprovalPanel.label(text, size: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The settings as saved.
    @objc func reload() {
        neverShowBox.state = SecretNewKeyDefaults.neverShow ? .on : .off
        asksBox.state = SecretNewKeyDefaults.asksEveryUse ? .on : .off
    }

    @objc func neverShowChanged() {
        SecretNewKeyDefaults.neverShow = neverShowBox.state == .on
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    @objc func asksChanged() {
        SecretNewKeyDefaults.asksEveryUse = asksBox.state == .on
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
