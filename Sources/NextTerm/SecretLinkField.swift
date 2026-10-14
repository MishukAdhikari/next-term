import AppKit
import NextTermCore

/// "Where it came from" in Add…, Edit… and `request_secret`'s window: the provider's page where the key was made and
/// is revoked. Only the user's hands fill it, by typing or with Use on a suggestion Next Term makes on this Mac from
/// the value's first bytes or the key's name (`SecretKeyPages`); nothing is fetched. Under it, the one sentence that
/// says why a link can't be kept (`SecretLink`), checked against the stored keys and the value being saved.
@MainActor
final class SecretLinkField: NSStackView, NSTextFieldDelegate {
    static let caption = "Where it came from"
    static let placeholder = "https://… the page where you made this key"

    private(set) var field = NSTextField()
    private(set) var chipLabel = NSTextField(labelWithString: "")
    private(set) var useButton = NSButton(title: "Use", target: nil, action: nil)
    private(set) var refusalLabel = NSTextField(wrappingLabelWithString: "")
    private let chip: NSStackView
    /// The page suggested now, shown in the chip while the field is empty or holds an earlier suggestion.
    private(set) var suggestion: KeyPage?
    /// What Use last put in the field; the field still holding it means the link is the suggestion.
    private var used: String?
    /// The key's link as stored (Edit), and where it came from: unchanged, it isn't saved again.
    let stored: String?
    private let storedFrom: SecretVault.LinkFrom?
    /// The stored link holds a key (`SecretLink.hides`), such as one stored after the link was saved: the field starts
    /// empty rather than show it, and Save removes it unless a new link is typed.
    let hidesStored: Bool
    /// Called after the text changes, by typing or by Use.
    var onChange: () -> Void = {}
    /// The value being saved with the link, which the link must not hold. Asked each time the link is checked.
    var value: () -> SecretBytes? = { nil }

    init(stored: String? = nil, from: SecretVault.LinkFrom? = nil) {
        self.stored = stored
        storedFrom = stored == nil ? nil : from
        let mask: (String) -> Bool = { (candidate: String) -> Bool in SecretsStore.holdsStoredKey(candidate) }
        hidesStored = stored.map { (link: String) -> Bool in SecretLink.hides(link, mask: mask) } ?? false
        chip = NSStackView()
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = 4
        field.stringValue = hidesStored ? "" : (stored ?? "")
        field.placeholderString = Self.placeholder
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.setAccessibilityLabel(Self.caption)
        chipLabel.font = .systemFont(ofSize: 11)
        chipLabel.textColor = .secondaryLabelColor
        chipLabel.lineBreakMode = .byTruncatingTail
        useButton.target = self
        useButton.action = #selector(use)
        useButton.bezelStyle = .rounded
        useButton.controlSize = .small
        useButton.font = .systemFont(ofSize: 11)
        chip.setViews([chipLabel, useButton], in: .leading)
        chip.spacing = 6
        chip.isHidden = true
        refusalLabel.font = .systemFont(ofSize: 11)
        refusalLabel.textColor = .systemOrange
        refusalLabel.isHidden = true
        let caption = NSTextField(labelWithString: Self.caption)
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        for view in [caption, field, chip, refusalLabel] { addArrangedSubview(view) }
        for view in [field, refusalLabel] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        refresh()
    }

    // MARK: the link

    /// The link as typed, trimmed.
    var text: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the text differs from the stored link (Add: from none).
    var isChanged: Bool { text != (stored ?? "") }

    /// Where the link came from: a suggestion the user took with Use and left as it was, or the user's typing.
    var linkFrom: SecretVault.LinkFrom {
        if let used, text == used { return .suggested }
        if !isChanged, let storedFrom { return storedFrom }
        return .user
    }

    /// Why the link can't be kept, or nil when it can or the field is empty.
    var refusal: SecretLink.Refusal? {
        guard !text.isEmpty else { return nil }
        let mask: (String) -> Bool = { (candidate: String) -> Bool in SecretsStore.holdsStoredKey(candidate) }
        guard case .failure(let refusal) = SecretLink.check(text, mask: mask, value: value()) else { return nil }
        return refusal
    }

    /// Whether the suggestion's chip shows.
    var showsSuggestion: Bool { !chip.isHidden }

    /// Save stays off while a link the user changed can't be kept. A stored link that fails the rules is shown as one
    /// that can't be opened, and saving other changes leaves it as it is; one that holds a key isn't shown, and goes.
    var blocksSave: Bool { isChanged && refusal != nil }

    /// The suggestion for this value and name: shown while the field is empty or holds the suggestion Use put there,
    /// and never in place of a link the user typed or one stored with the key (`SecretKeyPages.offers`).
    func suggest(value: SecretBytes?, name: String) {
        suggestion = SecretKeyPages.suggest(value: value, name: name)
        refresh()
    }

    /// Under the empty field, while the stored link it hides is kept.
    static let hiddenLine = SecretLink.cantOpen + " It holds a key, so it isn\u{2019}t shown, and Save removes it."

    func refresh() {
        let showsChip: Bool = SecretKeyPages.offers(suggestion, over: text, used: used)
        if let suggestion, showsChip {
            chipLabel.stringValue = "Suggested: \(suggestion.provider) · \(suggestion.label)"
            chipLabel.toolTip = suggestion.url.absoluteString
            useButton.setAccessibilityLabel("Use \(suggestion.provider)’s \(suggestion.label) page")
        }
        chip.isHidden = !showsChip
        let refusal = self.refusal
        let sentence: String = refusal?.sentence ?? ""
        let hidden: Bool = hidesStored && text.isEmpty
        if hidden {
            refusalLabel.stringValue = Self.hiddenLine
        } else {
            refusalLabel.stringValue = isChanged || refusal == nil ? sentence : SecretLink.cantOpen + " " + sentence
        }
        let warns: Bool = hidden || refusal != nil
        refusalLabel.isHidden = !warns
        refusalLabel.setAccessibilityLabel(warns ? "Warning: \(refusalLabel.stringValue)" : nil)
    }

    @objc func use() {
        guard let suggestion else { return }
        let link = suggestion.url.absoluteString
        field.stringValue = link
        used = link
        refresh()
        onChange()
    }

    func controlTextDidChange(_ notification: Notification) {
        refresh()
        onChange()
    }

    func setEnabled(_ enabled: Bool) {
        field.isEnabled = enabled
        useButton.isEnabled = enabled
    }
}
