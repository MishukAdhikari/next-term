import Foundation

/// What Rotate… shows for a key rotation, told on this Mac from the fixed table of key pages (`SecretKeyPages`), with
/// no network: the page its first step opens, the tip beside the paste field, and a warning when a pasted key looks
/// like another provider's than its page. Next Term never calls a provider to rotate, revoke or check a key; the user
/// makes the new key on the provider's page.
public enum SecretRotation {
    /// Said once the new value is saved.
    public static let keptMaskedLine = "Next Term keeps masking the old key for \(SecretVault.retiredDays) days, while it may "
        + "still work."

    /// The page the first step opens for a key's link: on GitHub's fine-grained tokens page, its new-token form filled
    /// with the key's name and today's date (`KeyPage.newTokenURL`), told by the link's host and path since the sheet
    /// never holds the old value; any other link as it is. No value ever goes into it.
    public static func pageToOpen(_ link: URL, name: String, date: Date, timeZone: TimeZone = .current) -> URL {
        guard let page = SecretKeyPages.page(forLink: link),
              let form = page.newTokenURL(name: name, date: date, timeZone: timeZone) else { return link }
        return form
    }

    /// The one line beside the paste field for a provider whose rotation has a twist (AWS, Azure, Stripe); nil for
    /// the others, and for a link on no provider's host.
    public static func tip(for link: URL?) -> String? {
        provider(of: link)?.tip
    }

    /// "This key looks like one from OpenRouter, but its page is OpenAI’s.", when the pasted value's head names a
    /// provider and the link's host names another. The user can still save. Nil when either names none: the old
    /// value's provider isn't known, since the sheet never holds it.
    public static func warning(value: SecretBytes, link: URL?) -> String? {
        guard let page = provider(of: link), let made = SecretKeyPages.page(forValue: value) else { return nil }
        guard made.provider != page.provider else { return nil }
        return "This key looks like one from \(made.provider), but its page is \(page.provider)\u{2019}s."
    }

    /// The page a link is, else a page of the provider whose host it is on.
    static func provider(of link: URL?) -> KeyPage? {
        guard let link else { return nil }
        if let page = SecretKeyPages.page(forLink: link) { return page }
        guard let host = link.host else { return nil }
        return SecretKeyPages.page(forHost: host)
    }
}
