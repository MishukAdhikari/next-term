import Foundation
import Testing
@testable import NextTermCore

@Suite struct StudioLinkTests {
    func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

    @Test func studioLinksForAServerOnThisMac() throws {
        // As `langgraph dev` prints them, the one it opens (with the organisation), EU, `langgraph up`, self-hosted.
        for link in ["https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024",
                     "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024&organizationId=0b0f2c3e-1d2a-4f5b-9c8d-7e6f5a4b3c2d",
                     "https://eu.smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024",
                     "https://smith.langchain.com/studio/?baseUrl=http://localhost:8123",
                     "https://smith.langchain.com/studio?baseUrl=http%3A%2F%2F0.0.0.0%3A2024",
                     "https://langsmith.example.com/studio/?baseUrl=http://[::1]:2024"] {
            #expect(StudioLink.isLocalStudio(try url(link)), "\(link)")
        }
        // A tunnel Safari can reach, a deployment, the server's own pages, and LangSmith's other pages are not.
        for link in ["https://smith.langchain.com/studio/?baseUrl=https://lunch-tour.trycloudflare.com",
                     "https://smith.langchain.com/studio/?baseUrl=https://my-agent.us.langgraph.app",
                     "http://127.0.0.1:2024/docs", "http://127.0.0.1:2024",
                     "https://smith.langchain.com/o/0b0f2c3e/projects/p/4a1b2c3d?baseUrl=http://127.0.0.1:2024",
                     "https://smith.langchain.com/studios/?baseUrl=http://127.0.0.1:2024",
                     "https://smith.langchain.com/studio/"] {
            #expect(!StudioLink.isLocalStudio(try url(link)), "\(link)")
        }
    }

    @Test func aChromiumBrowserWhenSafariIsTheDefault() throws {
        let studio = try url("https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024")
        func choice(_ link: URL = studio, default browser: String? = "com.apple.Safari", installed: Set<String>, enabled: Bool = true) -> StudioLink.Choice {
            StudioLink.choice(for: link, defaultBrowser: browser, installed: { installed.contains($0) }, enabled: enabled)
        }
        let all: Set<String> = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"]
        // Chrome, Edge, Brave, Arc: the first installed.
        #expect(choice(installed: all) == .browser(id: "com.google.Chrome"))
        #expect(choice(installed: all.subtracting(["com.google.Chrome"])) == .browser(id: "com.microsoft.edgemac"))
        #expect(choice(installed: ["company.thebrowser.Browser", "com.brave.Browser"]) == .browser(id: "com.brave.Browser"))
        #expect(choice(default: "com.apple.SafariTechnologyPreview", installed: ["company.thebrowser.Browser"]) == .browser(id: "company.thebrowser.Browser"))
        // None: Safari, with the note.
        #expect(choice(installed: ["org.mozilla.firefox"]) == .safariWithNote)
        // Another default browser, another link, or the setting off: the default browser.
        #expect(choice(default: "org.mozilla.firefox", installed: all) == .defaultBrowser)
        #expect(choice(default: "com.google.Chrome", installed: all) == .defaultBrowser)
        #expect(choice(default: nil, installed: all) == .defaultBrowser)
        #expect(choice(try url("http://127.0.0.1:2024/docs"), installed: all) == .defaultBrowser)
        #expect(choice(installed: all, enabled: false) == .defaultBrowser)
    }
}
