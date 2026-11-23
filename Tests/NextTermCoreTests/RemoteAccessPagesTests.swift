import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// The pages a browser sees while it pairs (`/oauth/authorize` and its wait): the code page that reloads itself
/// every 2 seconds, and the closed, expired, too-many and invalid pages. None holds a script, a form or anything
/// from elsewhere, text from the request is escaped, and every page carries the headers that keep it out of
/// frames, referrers and caches.
@Suite struct RemoteAccessPagesTests {
    typealias Pages = RemoteAccessPages
    typealias OAuth = RemoteAccessOAuth

    static let requestID = "q8Jx3vLr2nP0aT5sW7yZ1A"
    static let start = RemoteAccessOAuthTests.start

    /// Every page a browser can get.
    static var everyPage: [Pages.Page] {
        let authorizations: [OAuth.Authorization] = [
            .waiting(requestID: requestID, code: "482913"),
            .closed,
            .expired,
            .tooMany,
            .invalid("The callback was not registered."),
        ]
        return authorizations.compactMap { Pages.page($0) }
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// The text between `<style>` and `</style>`.
    func style(_ body: String) -> String? {
        guard let open = body.range(of: "<style>"),
              let close = body.range(of: "</style>", range: open.upperBound..<body.endIndex) else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
    }

    /// A pairing request waiting for its code, from a client registered with the claude.ai callback.
    func waiting(state: String) throws -> (oauth: OAuth, requestID: String, page: Pages.Page) {
        var oauth = RemoteAccessOAuthTests.authority()
        let client = try #require(RemoteAccessOAuthTests.register(&oauth, now: Self.start))
        oauth.openPairing(now: Self.start)
        let parameters = RemoteAccessOAuthTests.authorizeParameters(client: client, state: state)
        let authorization = oauth.authorize(parameters, now: Self.start)
        guard case .waiting(let requestID, _) = authorization else {
            Issue.record("authorize did not wait: \(authorization)")
            throw RemoteAccessOAuthTests.Failure("authorize did not wait")
        }
        let page = try #require(Pages.page(authorization))
        return (oauth, requestID, page)
    }

    // MARK: the code page

    @Test func theCodePageHoldsTheCodeAndReloadsToTheWaitURLEveryTwoSeconds() throws {
        let page = try #require(Pages.page(.waiting(requestID: Self.requestID, code: "482913")))
        #expect(page.status == 200)
        #expect(page.body.contains(">482913<"))
        #expect(page.body.contains("Type this code in Next Term on your Mac."))
        let wait = OAuth.waitPath(for: Self.requestID)
        #expect(page.body.contains("<meta http-equiv=\"refresh\" content=\"2;url=\(wait)\">"))
        #expect(Pages.refreshSeconds == 2)
    }

    @Test func onlyTheCodePageReloads() {
        for page in Self.everyPage where !page.body.contains(">482913<") {
            #expect(!page.body.contains("http-equiv"))
        }
    }

    // MARK: headers

    @Test func everyPageCarriesTheHeaders() throws {
        #expect(Self.everyPage.count == 5)
        for page in Self.everyPage {
            let policy = try #require(page.header("Content-Security-Policy"))
            #expect(policy.contains("default-src 'none'"))
            #expect(policy.contains("frame-ancestors 'none'"))
            #expect(!policy.contains("unsafe"))
            #expect(page.header("X-Frame-Options") == "DENY")
            #expect(page.header("Referrer-Policy") == "no-referrer")
            #expect(page.header("Cache-Control") == "no-store")
            #expect(page.header("Content-Type") == "text/html; charset=utf-8")
            #expect(page.header("x-content-type-options") == "nosniff")
        }
    }

    @Test func theInlineStyleIsAllowedByItsHashOnly() throws {
        for page in Self.everyPage {
            let css = try #require(style(page.body))
            let digest = Data(SHA256.hash(data: Data(css.utf8))).base64EncodedString()
            let policy = try #require(page.header("Content-Security-Policy"))
            #expect(policy.contains("style-src 'sha256-\(digest)'"))
            #expect(page.body.components(separatedBy: "<style").count == 2)
            #expect(!page.body.contains("style=\""))
        }
    }

    @Test func theResponseIsThePageWithItsHeaders() throws {
        let authorization = OAuth.Authorization.waiting(requestID: Self.requestID, code: "482913")
        let page = try #require(Pages.page(authorization))
        let answer = text(Pages.response(authorization))
        #expect(answer.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let parts = answer.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        #expect(parts.last == page.body)
        #expect(answer.contains("Content-Length: \(Data(page.body.utf8).count)\r\n"))
        #expect(answer.contains("Content-Security-Policy: \(page.header("Content-Security-Policy") ?? "")\r\n"))
        #expect(answer.contains("X-Frame-Options: DENY\r\n"))
        #expect(!answer.lowercased().contains("server:"))
        #expect(!answer.lowercased().contains("access-control-"))
    }

    @Test func aRedirectIsA302WithItsLinkAndNoPage() {
        let link = "https://claude.ai/api/mcp/auth_callback?code=abc&state=s-123&iss=https%3A%2F%2Fmcp.example.com"
        #expect(Pages.page(.redirect(link)) == nil)
        let answer = text(Pages.response(.redirect(link)))
        #expect(answer.hasPrefix("HTTP/1.1 302 Found\r\n"))
        #expect(answer.contains("Location: \(link)\r\n"))
        #expect(answer.contains("Cache-Control: no-store\r\n"))
        #expect(answer.contains("Referrer-Policy: no-referrer\r\n"))
        #expect(answer.contains("Content-Length: 0\r\n"))
        #expect(answer.hasSuffix("\r\n\r\n"))
    }

    // MARK: nothing runs, nothing comes from elsewhere

    @Test func noPageHoldsAScriptAFormOrAnythingFromElsewhere() {
        let refused = ["<script", "<form", "<iframe", "<img", "<link", "<object", "<embed", "<input", "<button",
                       "src=", "href=", "http://", "https://", "javascript:", "@import", "url("]
        for page in Self.everyPage {
            let body = page.body.lowercased()
            for word in refused {
                #expect(!body.contains(word), "a page holds \(word)")
            }
        }
    }

    @Test func everyPageFitsAPhone() {
        for page in Self.everyPage {
            #expect(page.body.hasPrefix("<!doctype html>"))
            #expect(page.body.contains("<html lang=\"en\">"))
            #expect(page.body.contains("<meta charset=\"utf-8\">"))
            #expect(page.body.contains("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"))
        }
    }

    // MARK: text from the request is escaped

    @Test func aStateHoldingAScriptComesOutEscaped() throws {
        let state = "\"><script>alert(1)</script>"
        var (oauth, requestID, page) = try waiting(state: state)
        #expect(!page.body.lowercased().contains("<script"))
        #expect(!page.body.contains("alert(1)"))
        let polled = try #require(Pages.page(oauth.poll(requestID, now: Self.start)))
        #expect(!polled.body.lowercased().contains("<script"))
        // Declined, the state goes back to the client in the redirect's query, never into a page.
        oauth.decline(requestID, now: Self.start)
        let declined = oauth.poll(requestID, now: Self.start)
        #expect(Pages.page(declined) == nil)
        let answer = text(Pages.response(declined))
        #expect(answer.hasPrefix("HTTP/1.1 302 Found\r\n"))
        #expect(!answer.contains("<script"))
    }

    @Test func markupInAnyTextComesOutEscaped() throws {
        let markup = "\"><script>alert(1)</script><b>"
        let waiting = try #require(Pages.page(.waiting(requestID: markup, code: markup)))
        let invalid = try #require(Pages.page(.invalid(markup)))
        for page in [waiting, invalid] {
            #expect(!page.body.lowercased().contains("<script"))
            #expect(!page.body.contains("<b>"))
            #expect(page.body.contains("&lt;script&gt;alert(1)&lt;/script&gt;&lt;b&gt;"))
        }
        #expect(invalid.status == 400)
    }

    @Test func escapingCoversTheFiveCharactersAndNothingElse() {
        #expect(Pages.escape("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
        #expect(Pages.escape("Next Term › Settings") == "Next Term › Settings")
        #expect(Pages.escape("") == "")
    }

    // MARK: the texts

    @Test func theClosedAndExpiredPagesHoldTheirExactTexts() throws {
        let closedText = "Pairing is closed. On your Mac, open Next Term › Settings › Remote Access › Connect a Client."
        let expiredText = "Not approved in time. Start again from your Mac."
        #expect(Pages.closedText == closedText)
        #expect(Pages.expiredText == expiredText)
        let closed = try #require(Pages.page(.closed))
        let expired = try #require(Pages.page(.expired))
        #expect(closed.body.contains(closedText))
        #expect(expired.body.contains(expiredText))
        #expect(!closed.body.contains(expiredText))
        #expect(!expired.body.contains(closedText))
        #expect(closed.status == 200)
        #expect(expired.status == 200)
    }

    @Test func tooManyWaitingGets429AndAnInvalidRequestItsReason() throws {
        let tooMany = try #require(Pages.page(.tooMany))
        #expect(tooMany.status == 429)
        #expect(tooMany.body.contains(Pages.tooManyText))
        let reason = "This app is not registered with Next Term. Remove the connector and add it again."
        let invalid = try #require(Pages.page(.invalid(reason)))
        #expect(invalid.status == 400)
        #expect(invalid.body.contains(reason))
    }

    @Test func aClosedPairingShowsTheClosedPage() throws {
        // Pairing never opened.
        var oauth = RemoteAccessOAuthTests.authority()
        let client = try #require(RemoteAccessOAuthTests.register(&oauth, now: Self.start))
        let parameters = RemoteAccessOAuthTests.authorizeParameters(client: client)
        let refused = try #require(Pages.page(oauth.authorize(parameters, now: Self.start)))
        #expect(refused.body.contains(Pages.closedText))
        // The pairing window closed on the Mac before its code was typed.
        var (opened, requestID, _) = try waiting(state: "s-123")
        opened.closePairing(now: Self.start)
        let closed = try #require(Pages.page(opened.poll(requestID, now: Self.start)))
        #expect(closed.body.contains(Pages.closedText))
    }

    @Test func aRequestPastItsTenMinutesShowsTheExpiredPage() throws {
        var (oauth, requestID, _) = try waiting(state: "s-123")
        // Connect a Client again keeps pairing open past the first request's 10 minutes.
        oauth.openPairing(now: Self.start.addingTimeInterval(5 * 60))
        let late = Self.start.addingTimeInterval(OAuth.requestLifetime + 1)
        let expired = try #require(Pages.page(oauth.poll(requestID, now: late)))
        #expect(expired.body.contains(Pages.expiredText))
    }
}
