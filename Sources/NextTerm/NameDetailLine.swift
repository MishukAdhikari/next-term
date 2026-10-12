import AppKit
import NextTermCore

/// A sidebar row's name and the dimmed detail after it ("OpenAI", "AI model · .env"), with the row's badge and ⋯ after
/// them: what Databases and Services rows share, so the two sections look the same. The name and the detail are two
/// labels on one baseline, sized by NameDetailFit for the row's width: the detail gives way first, cut at its tail, and
/// hides rather than show a sliver; the name is cut at its tail only when it alone does not fit. The badge and ⋯ keep
/// their places. The row adds the labels to itself, in its own order, and activates `place(in:badge:more:)`.
@MainActor
final class NameDetailLine {
    /// Where the name starts, past the icon; the gap the name leaves before the badge; the badge's before ⋯; ⋯'s width
    /// and its gap to the row's end. The constraints and the room the fit is given both come from these.
    static let nameStart: CGFloat = 21
    static let toBadge: CGFloat = 6
    static let toMore: CGFloat = 2
    static let moreWidth: CGFloat = 20
    static let toEnd: CGFloat = 2
    /// The space between the name's last letter and the detail's first.
    static let detailGap: CGFloat = 7

    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    private let nameWidth: NSLayoutConstraint
    private let detailWidth: NSLayoutConstraint
    private let detailLead: NSLayoutConstraint
    /// The narrowest the detail may be cut to: its first two characters and the ellipsis.
    private(set) var minimumDetail: CGFloat = 0

    init() {
        Typography.singleLine(name, truncation: .byTruncatingTail)
        Typography.singleLine(detail, truncation: .byTruncatingTail)
        // The widths come from NameDetailFit; if the two ever disagree with the badge, the detail gives way first.
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameWidth = name.widthAnchor.constraint(equalToConstant: 0)
        nameWidth.priority = .init(999)
        detailWidth = detail.widthAnchor.constraint(equalToConstant: 0)
        detailWidth.priority = .init(998)
        detailLead = detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 0)
        for view in [name, detail] { view.translatesAutoresizingMaskIntoConstraints = false }
    }

    /// The places of the name, centred in `row`, the detail on its baseline, the badge and ⋯ at the row's end. Neither
    /// label runs past the badge, which never shrinks.
    func place(in row: NSView, badge: NSView, more: NSView) -> [NSLayoutConstraint] {
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let text: [NSLayoutConstraint] = [
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.nameStart),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Self.toBadge),
            nameWidth,
            detailLead,
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Self.toBadge),
            detailWidth,
        ]
        let end: [NSLayoutConstraint] = [
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -Self.toMore),
            more.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Self.toEnd),
            more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: Self.moreWidth),
            more.heightAnchor.constraint(equalToConstant: 20),
        ]
        return text + end
    }

    /// What the line shows, for the self-test: the name, then its detail, hidden or not.
    var text: String { detail.stringValue.isEmpty ? name.stringValue : name.stringValue + " " + detail.stringValue }

    /// A label never shown, to measure text as the row's labels lay it out.
    private static let sizer = NSTextField(labelWithString: "")

    /// The line's two runs of text, each cut at its tail when it has to be. An empty detail shows the name alone.
    func show(_ title: NSAttributedString, detail line: NSAttributedString) {
        name.attributedStringValue = Typography.truncating(title, .byTruncatingTail)
        detail.attributedStringValue = Typography.truncating(line, .byTruncatingTail)
        let attributes = line.length > 0 ? line.attributes(at: 0, effectiveRange: nil) : [:]
        Self.sizer.attributedStringValue = NSAttributedString(string: String(line.string.prefix(2)) + "…", attributes: attributes)
        minimumDetail = Self.sizer.intrinsicContentSize.width
    }

    /// Sizes the name and the detail for `row`'s width and `badge`'s (NameDetailFit). The row calls it once its text and
    /// badges are set, and each time its width changes.
    func fit(in row: NSView, badge: NSView) {
        let ends: CGFloat = Self.toBadge + badge.intrinsicContentSize.width + Self.toMore + Self.moreWidth + Self.toEnd
        let room: CGFloat = row.bounds.width - Self.nameStart - ends
        let nameWhole: CGFloat = name.intrinsicContentSize.width
        let detailWhole: CGFloat = detail.stringValue.isEmpty ? 0 : detail.intrinsicContentSize.width
        let fit = NameDetailFit.fit(room: Double(room), name: Double(nameWhole), detail: Double(detailWhole),
                                    gap: Double(Self.detailGap), minimumDetail: Double(minimumDetail))
        Self.set(nameWidth, to: CGFloat(fit.name))
        Self.set(detailWidth, to: CGFloat(fit.detail ?? 0))
        Self.set(detailLead, to: fit.detail == nil ? 0 : Self.detailGap)
        detail.isHidden = fit.detail == nil
    }

    private static func set(_ constraint: NSLayoutConstraint, to constant: CGFloat) {
        if constraint.constant != constant { constraint.constant = constant }
    }
}
