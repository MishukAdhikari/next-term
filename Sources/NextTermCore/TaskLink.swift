import Foundation

/// The gate every task link passes before it opens. An allow-list: Things' `add`, Todoist's and OmniFocus's Quick Add,
/// and the new-issue pages of GitHub, GitLab, Linear, Trello and Azure Boards, each with only the parameters its
/// renderer writes, each at most once, and its title always there. Anything else is refused: another command of the
/// same app (`things:///update`, `things:///json`), a parameter that acts beyond adding (`auth-token`, `reveal`,
/// `x-success`), any other scheme, plain `http`, a user, password, port or fragment, another host or another path.
/// The renderers build only allowed links, so a refusal is a bug, met with a beep and nothing opened.
public enum TaskLink {
    public enum Kind: String, CaseIterable, Sendable {
        case things, todoist, omnifocus, github, gitlab, linear, trello, azureBoards

        /// It opens in an app on this Mac, not in the browser.
        public var isApp: Bool { probe != nil }

        /// The app's or the tracker's name, as messages say it.
        public var name: String {
            switch self {
            case .things: return "Things"
            case .todoist: return "Todoist"
            case .omnifocus: return "OmniFocus"
            case .github: return "GitHub"
            case .gitlab: return "GitLab"
            case .linear: return "Linear"
            case .trello: return "Trello"
            case .azureBoards: return "Azure Boards"
            }
        }

        /// A link of the app's scheme that does nothing, to ask which app would open it; nil for a page.
        public var probe: URL? {
            switch self {
            case .things: return URL(string: "things:///")
            case .todoist: return URL(string: "todoist://")
            case .omnifocus: return URL(string: "omnifocus:///")
            default: return nil
            }
        }

        /// The app comes to the front. Things saves without a window, so it stays behind; a Quick Add waits for the
        /// user's own Add, so its window must be seen.
        public var activates: Bool { self == .todoist || self == .omnifocus }

        /// The parameters the link may carry; the first is its title and must be there.
        var parameters: [String] {
            switch self {
            case .things: return ["title", "notes", "checklist-items", "when", "list"]
            case .todoist: return ["content", "description"]
            case .omnifocus: return ["name", "note"]
            case .github: return ["title", "body"]
            case .gitlab: return ["issue[title]", "issue[description]"]
            case .linear: return ["title", "description"]
            case .trello: return ["name"]
            case .azureBoards: return ["[System.Title]", "[System.Description]"]
            }
        }
    }

    /// The kind of task link `url` is, or nil when it may not open.
    public static func check(_ url: URL) -> Kind? {
        guard SafeWebLink.isPrintable(url.absoluteString),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil,
              parts.port == nil, parts.percentEncodedFragment == nil,
              let scheme = parts.scheme, let query = parts.percentEncodedQuery else { return nil }
        let path = parts.percentEncodedPath
        guard !SafeWebLink.isUnsafe(path: path) else { return nil }
        // An app link keeps the `//` of its own form: `things:///add` has an empty host, `things:/add` has none.
        guard let host = parts.percentEncodedHost else { return nil }
        let kind: Kind?
        switch scheme {
        case "things": kind = host.isEmpty && path == "/add" ? .things : nil
        case "todoist": kind = host == "openquickadd" && path.isEmpty ? .todoist : nil
        case "omnifocus": kind = host.isEmpty && path == "/add" ? .omnifocus : nil
        case "https": kind = page(host: host.lowercased(), path: path)
        default: kind = nil
        }
        guard let kind, takes(query, kind.parameters) else { return nil }
        return kind
    }

    /// The tracker whose new-issue page this is: its exact host, and its path with each part the user names filled.
    static func page(host: String, path: String) -> Kind? {
        if host == "linear.new" { return path.isEmpty || path == "/" ? .linear : nil }
        let segments: [String] = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.hasPrefix("/") else { return nil }
        let rest: [String] = Array(segments.dropFirst())
        // Every part is there, and none hides another step behind an encoded slash or backslash.
        let whole = rest.allSatisfy { (part: String) -> Bool in
            let upper = part.uppercased()
            return !part.isEmpty && !upper.contains("%2F") && !upper.contains("%5C")
        }
        guard whole else { return nil }
        switch host {
        case "github.com":
            return rest.count == 4 && rest[2] == "issues" && rest[3] == "new" ? .github : nil
        case "gitlab.com":
            let places = rest.count - 3
            let tail: [String] = Array(rest.suffix(3))
            let fits = places >= 2 && places <= TaskDestination.gitlabSegments
            let named = !rest.prefix(max(places, 0)).contains("-")
            return fits && named && tail == ["-", "work_items", "new"] ? .gitlab : nil
        case "linear.app":
            return rest.count == 3 && rest[0] == "team" && rest[2] == "new" ? .linear : nil
        case "trello.com":
            return rest == ["add-card"] ? .trello : nil
        case "dev.azure.com":
            guard rest.count == 5, rest[2] == "_workItems", rest[3] == "create" else { return nil }
            let type = rest[4].removingPercentEncoding ?? ""
            return TaskDestination.azureTypes.contains(type) ? .azureBoards : nil
        default:
            return nil
        }
    }

    /// What may stand in a query as written: the encoded value's own characters, `%` escapes, and `+` for a space.
    static let queryCharacters = TaskPayload.unreserved.union(CharacterSet(charactersIn: "%+"))

    /// The query is `name=value` pairs joined by `&`, every name one of `allowed`, none twice, the first of `allowed`
    /// there, and nothing a server might read as another separator or another parameter.
    static func takes(_ query: String, _ allowed: [String]) -> Bool {
        var seen: Set<String> = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let sides = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard sides.count == 2 else { return false }
            let plain = sides.allSatisfy { (side: Substring) -> Bool in
                side.unicodeScalars.allSatisfy { queryCharacters.contains($0) }
            }
            guard plain, let name = sides[0].removingPercentEncoding, sides[1].removingPercentEncoding != nil,
                  allowed.contains(name), seen.insert(name).inserted else { return false }
        }
        return allowed.first.map(seen.contains) ?? false
    }

    /// The start of the bundle id of the app a kind's link may open in; nil for a page, which opens in the browser.
    public static func vendorPrefix(for kind: Kind) -> String? {
        switch kind {
        case .things: return "com.culturedcode."
        case .todoist: return "com.todoist."
        case .omnifocus: return "com.omnigroup.OmniFocus"
        default: return nil
        }
    }

    /// The app with this bundle id is the vendor's own, so the link goes nowhere else.
    public static func isVendor(_ bundleID: String, for kind: Kind) -> Bool {
        guard let prefix = vendorPrefix(for: kind) else { return false }
        return bundleID.count > prefix.count && bundleID.hasPrefix(prefix)
    }
}
