import AppKit

/// How Next Term's own dialogs and sheets fit their content, so none looks broken: a window as tall as what it shows (a
/// short page leaves no empty space under its buttons, and rows hidden later take their space with them), its top edge
/// where it was, and the button row 20 points from the bottom and side edges with buttons at least 80 wide, as macOS's
/// own dialogs have them (2026-11-02: the import window kept a fixed 560 points for a two-row page).
enum DialogFit {
    /// The margins around a dialog's content and its button row.
    static let insets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    /// The narrowest a dialog's button is.
    static let buttonWidth: CGFloat = 80

    /// The window's content made as tall as its views need at `width` (the window's own when nil), its top edge kept.
    /// A sheet stays attached and slides to its new height.
    static func fit(_ window: NSWindow?, width: CGFloat? = nil) {
        guard let window, let content = window.contentView else { return }
        // Never narrower than its widest row needs, so the width pinned below can always hold.
        content.layoutSubtreeIfNeeded()
        let needed: CGFloat = content.fittingSize.width
        let wide: CGFloat = max(width ?? window.contentRect(forFrameRect: window.frame).width, needed)
        // Measured at that width, so a wrapped label counts the lines it takes there.
        let pinned: NSLayoutConstraint = content.widthAnchor.constraint(equalToConstant: wide)
        pinned.priority = .required
        pinned.isActive = true
        content.layoutSubtreeIfNeeded()
        let tall: CGFloat = content.fittingSize.height
        pinned.isActive = false
        guard tall > 0 else { return }
        let frame: NSRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: wide, height: tall)))
        // Nothing to do when it is that size already: no frame set on every keystroke.
        if abs(frame.height - window.frame.height) < 0.5, abs(frame.width - window.frame.width) < 0.5 { return }
        let top: CGFloat = window.frame.maxY
        window.setFrame(NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
                        display: true, animate: false)
    }

    /// An alert's accessory view as tall as its views need at `width`, the alert laid out again: a wrapped line that grows
    /// or shrinks (a problem under a field, a list of steps) is neither cut off nor followed by empty space.
    /// Sized by constraints, not its frame: once NSAlert has laid it out it ignores the frame, and the alert would change
    /// width on each fit. One required width constraint stays; the height constraint follows what the views need.
    static func fitAccessory(_ view: NSView, width: CGFloat, in alert: NSAlert?) {
        view.translatesAutoresizingMaskIntoConstraints = false
        let wide: NSLayoutConstraint = constraint(of: view, named: "DialogFit.width", attribute: .width, constant: width)
        wide.constant = width
        let tall: NSLayoutConstraint = constraint(of: view, named: "DialogFit.height", attribute: .height, constant: 1)
        tall.isActive = false
        view.layoutSubtreeIfNeeded()
        tall.constant = max(view.fittingSize.height, 1)
        tall.isActive = true
        alert?.layout()
    }

    /// The accessory's own width or height constraint, made once and found again by its identifier.
    private static func constraint(of view: NSView, named name: String, attribute: NSLayoutConstraint.Attribute,
                                   constant: CGFloat) -> NSLayoutConstraint {
        if let found = view.constraints.first(where: { $0.identifier == name }) { return found }
        let made: NSLayoutConstraint = NSLayoutConstraint(item: view, attribute: attribute, relatedBy: .equal, toItem: nil,
                                                          attribute: .notAnAttribute, multiplier: 1, constant: constant)
        made.identifier = name
        made.priority = .required
        made.isActive = true
        return made
    }

    /// Each button at least `buttonWidth` wide.
    static func widen(_ buttons: [NSButton]) {
        for button in buttons { button.widthAnchor.constraint(greaterThanOrEqualToConstant: buttonWidth).isActive = true }
    }
}
