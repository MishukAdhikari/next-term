import Foundation

/// LangGraph Studio's links, as `langgraph dev` and `langgraph up` print them:
/// `https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024`. Studio is a web page that talks to the
/// server on this Mac, and Safari won't let an HTTPS page reach plain-HTTP `127.0.0.1` ("Failed to load
/// assistants"), so a ⌘-click opens these in a Chromium browser instead when Safari is the default.
public enum StudioLink {
    /// Chromium browsers Studio works in, in the order they are chosen: Chrome, Edge, Brave, Arc.
    public static let chromiumBrowsers: [(id: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave Browser"), ("company.thebrowser.Browser", "Arc"),
    ]

    /// Safari and its Technology Preview: WebKit, which blocks Studio's requests to this Mac.
    public static let webKitBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// A Studio page for a server on this Mac: the path `/studio` (on smith.langchain.com, eu.smith.langchain.com, or
    /// a self-hosted LangSmith that `--studio-url` names), and a `baseUrl` on a loopback address, as ServedURL finds
    /// them (localhost, 127.0.0.1, 0.0.0.0, [::1]). A Studio link through a tunnel is not one: Safari reaches it.
    public static func isLocalStudio(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https" || parts.scheme == "http",
              parts.path == "/studio" || parts.path.hasPrefix("/studio/"),
              let base = parts.queryItems?.first(where: { $0.name == "baseUrl" })?.value,
              let server = URLComponents(string: base), server.scheme == "http" || server.scheme == "https",
              let host = server.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    }

    /// How to open a link.
    public enum Choice: Equatable, Sendable {
        /// In the default browser, as any link.
        case defaultBrowser
        /// In this installed Chromium browser.
        case browser(id: String)
        /// In the default browser (Safari, where Studio may not load), saying why once: no Chromium browser is installed.
        case safariWithNote
    }

    /// `defaultBrowser`: the default browser's bundle id. `installed`: whether a browser is installed, by bundle id.
    /// `enabled`: the setting (Settings › Terminal).
    public static func choice(for url: URL, defaultBrowser: String?, installed: (String) -> Bool, enabled: Bool) -> Choice {
        guard enabled, isLocalStudio(url), let defaultBrowser, webKitBrowsers.contains(defaultBrowser) else { return .defaultBrowser }
        if let browser = chromiumBrowsers.first(where: { installed($0.id) }) { return .browser(id: browser.id) }
        return .safariWithNote
    }
}
