import CryptoKit
import Foundation

/// The pages a browser sees while it pairs (U8): `/oauth/authorize` and its wait.
///
/// The code page shows the 6-digit code in large digits and reloads itself every 2 seconds with a meta refresh to
/// `/oauth/authorize/wait`, so it needs no script and the browser sends no `Origin` (KTD7). Once the user allows
/// it on the Mac, the next reload gets a 302 back to the client. The closed, expired, too-many and invalid pages
/// say why there is nothing to wait for. The page has no buttons (R12): everything happens on the Mac.
///
/// A page holds no script, no form and nothing from elsewhere: one inline style, allowed by its hash in the
/// `Content-Security-Policy`. Text from the request is escaped. Every page carries headers that keep it out of
/// frames, referrers and caches.
public enum RemoteAccessPages {
    /// The code page reloads this often, in seconds.
    public static let refreshSeconds = 2

    public static let waitingText = "Type this code in Next Term on your Mac."
    public static let waitingNote = "This page moves on by itself once you allow it there."
    /// R11.
    public static let closedText = "Pairing is closed. On your Mac, open Next Term › Settings › Remote Access › Connect a Client."
    public static let expiredText = "Not approved in time. Start again from your Mac."
    public static let tooManyText = "Too many pairing requests are waiting. Try again in a few minutes."

    /// A page and its headers.
    public struct Page: Sendable {
        public let status: Int
        public let headers: [(name: String, value: String)]
        /// The HTML.
        public let body: String

        /// A header's value, its name compared without case.
        public func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The HTTP answer, ready to send.
        public var response: Data {
            let pairs = headers.map { ($0.name, $0.value) }
            return RemoteAccessHTTP.response(status: status, headers: pairs, body: Data(body.utf8))
        }
    }

    /// The page for an authorization, or nil for a redirect, which has none.
    public static func page(_ authorization: RemoteAccessOAuth.Authorization) -> Page? {
        switch authorization {
        case .redirect:
            return nil
        case .waiting(let requestID, let code):
            return waiting(requestID: requestID, code: code)
        case .closed:
            return page(200, main: "<h1>\(escape(closedText))</h1>")
        case .expired:
            return page(200, main: "<h1>\(escape(expiredText))</h1>")
        case .tooMany:
            return page(429, main: "<h1>\(escape(tooManyText))</h1>")
        case .invalid(let reason):
            return page(400, main: "<h1>\(escape(reason))</h1>")
        }
    }

    /// What the door sends for an authorization: a 302 back to the client, or the page.
    public static func response(_ authorization: RemoteAccessOAuth.Authorization) -> Data {
        guard case .redirect(let link) = authorization else {
            return page(authorization)?.response ?? RemoteAccessHTTP.refusal(status: 500)
        }
        var headers: [(String, String)] = []
        headers.append(("Location", link))
        headers.append(("Cache-Control", "no-store"))
        headers.append(("Referrer-Policy", "no-referrer"))
        return RemoteAccessHTTP.response(status: 302, headers: headers)
    }

    /// Text made safe for HTML, in an element or in a quoted attribute.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: the pages

    /// The code in large digits, what to do with it, and the reload to the wait URL.
    private static func waiting(requestID: String, code: String) -> Page {
        let wait = escape(RemoteAccessOAuth.waitPath(for: requestID))
        let refresh = "<meta http-equiv=\"refresh\" content=\"\(refreshSeconds);url=\(wait)\">"
        var main = "<p class=\"code\">\(escape(code))</p>"
        main += "<h1>\(escape(waitingText))</h1>"
        main += "<p class=\"note\">\(escape(waitingNote))</p>"
        return page(200, main: main, head: refresh)
    }

    /// A whole page: the shared head, the style, and `main` in its card.
    private static func page(_ status: Int, main: String, head: String = "") -> Page {
        var html = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        html += "<meta name=\"robots\" content=\"noindex\">"
        html += head
        html += "<title>Pair with Next Term</title>"
        html += "<style>\(style)</style>"
        html += "</head><body><main><p class=\"brand\">Next Term</p>"
        html += main
        html += "</main></body></html>"
        return Page(status: status, headers: headers, body: html)
    }

    /// Every page's headers.
    private static let headers: [(name: String, value: String)] = {
        var headers: [(name: String, value: String)] = []
        headers.append(("Content-Type", "text/html; charset=utf-8"))
        headers.append(("Content-Security-Policy", contentSecurityPolicy))
        headers.append(("X-Frame-Options", "DENY"))
        headers.append(("X-Content-Type-Options", "nosniff"))
        headers.append(("Referrer-Policy", "no-referrer"))
        headers.append(("Cache-Control", "no-store"))
        return headers
    }()

    /// Nothing loads, nothing runs, no frame holds the page, and nothing posts: only the inline style, by its hash.
    static let contentSecurityPolicy: String = {
        var policy = ["default-src 'none'"]
        policy.append("style-src 'sha256-\(styleHash)'")
        policy.append("base-uri 'none'")
        policy.append("form-action 'none'")
        policy.append("frame-ancestors 'none'")
        return policy.joined(separator: "; ")
    }()

    /// The style's SHA-256, in base64, as the policy names it.
    static let styleHash: String = {
        Data(SHA256.hash(data: Data(style.utf8))).base64EncodedString()
    }()

    /// The one style every page shares: a card in the middle, light or dark as the browser is, sized for a phone.
    static let style: String = {
        var rules: [String] = []
        rules.append(":root{color-scheme:light dark;--bg:#f5f5f3;--fg:#1d1d1f;--muted:#6e6e73;--card:#fff;--line:#e2e2df}")
        rules.append("@media (prefers-color-scheme:dark){:root{--bg:#141415;--fg:#f2f2f2;--muted:#a1a1a6;"
            + "--card:#1e1e20;--line:#333336}}")
        rules.append("*{box-sizing:border-box}")
        rules.append("body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;"
            + "padding:24px 16px;background:var(--bg);color:var(--fg);"
            + "font:16px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",system-ui,sans-serif}")
        rules.append("main{width:100%;max-width:420px;padding:28px 24px;text-align:center;background:var(--card);"
            + "border:1px solid var(--line);border-radius:14px}")
        rules.append(".brand{margin:0 0 20px;font-size:13px;font-weight:600;letter-spacing:.04em;color:var(--muted)}")
        rules.append("h1{margin:0 0 10px;font-size:19px;line-height:1.35;font-weight:600;text-wrap:balance}")
        rules.append(".code{margin:4px 0 18px;padding-left:.14em;letter-spacing:.14em;"
            + "font:600 44px/1.1 ui-monospace,\"SF Mono\",Menlo,monospace;font-variant-numeric:tabular-nums}")
        rules.append(".note{margin:0;font-size:14px;color:var(--muted)}")
        return rules.joined()
    }()
}
