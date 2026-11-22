import Foundation
import Testing
@testable import NextTermCore

@Suite struct NextTermLinkTests {
    func parse(_ text: String) -> Result<NextTermLink, NextTermLink.Refusal> {
        NextTermLink.parse(URL(string: text)!, home: "/Users/me")
    }

    @Test func eachActionReads() {
        #expect(parse("nextterm://open?path=/Users/me/Code/app") == .success(.open(path: "/Users/me/Code/app")))
        #expect(parse("nextterm://open?path=~/Code/app/") == .success(.open(path: "/Users/me/Code/app")))
        #expect(parse("NextTerm://attention") == .success(.attention))
        #expect(parse("nextterm:goto") == .success(.goTo))
        #expect(parse("nextterm://tab?id=0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0") == .success(.tab(id: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")))
        #expect(parse("nextterm://agent?path=~/Code/app") == .success(.agent(path: "/Users/me/Code/app", agent: "claude")))
        #expect(parse("nextterm://agent?path=/x&agent=Codex") == .success(.agent(path: "/x", agent: "codex")))
    }

    @Test func aLinkNeverSpellsOutACommand() {
        for bad in ["nextterm://agent?path=/x&agent=rm%20-rf%20~", "nextterm://agent?path=/x&agent=bash",
                    "nextterm://run?command=ls", "nextterm://open", "nextterm://open?path=relative/dir",
                    "nextterm://tab?id=not-a-uuid", "https://open?path=/x"] {
            if case .success(let link) = parse(bad) { Issue.record("\(bad) read as \(link)") }
        }
        // A folder is normalised, so ../ can't hide where it goes.
        #expect(parse("nextterm://open?path=/Users/me/Code/app/../../.ssh") == .success(.open(path: "/Users/me/.ssh")))
    }
}
