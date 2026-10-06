import Foundation
import Testing
@testable import NextTermCore

@Suite struct ReleaseNotesTests {
    @Test func blocksFromARealReleaseBody() {
        let body = """
        **Your shortcuts come with you.**

        ### Highlights
        - **Import from VS Code.** It is offered on first launch.
          - The preview shows exactly what would change,
            each item a checkbox.
        - **VS Code and JetBrains shortcuts.**

          Your own shortcut changes stay on top.
        1. First step
        2) Second step

        ```
        nxtrm .
        ```

        ### Update
        On 0.4.0? **Check for Updates** installs it.

        ### Install
        1. Open the disk image.
        #### Gatekeeper
        Right-click it.

        ## Thanks
        **Full Changelog**: https://github.com/o/r/compare/v1...v2
        ---
        Done.
        """
        let blocks = ReleaseNotes.blocks(body)
        #expect(blocks == [
            .paragraph(depth: 0, text: "**Your shortcuts come with you.**"),
            .heading(level: 3, text: "Highlights"),
            .bullet(depth: 0, text: "**Import from VS Code.** It is offered on first launch."),
            .bullet(depth: 1, text: "The preview shows exactly what would change, each item a checkbox."),
            .bullet(depth: 0, text: "**VS Code and JetBrains shortcuts.**"),
            .paragraph(depth: 1, text: "Your own shortcut changes stay on top."),
            .numbered(depth: 0, number: "1", text: "First step"),
            .numbered(depth: 0, number: "2", text: "Second step"),
            .code("nxtrm ."),
            .heading(level: 2, text: "Thanks"),
            .paragraph(depth: 0, text: "Done."),
        ])
    }

    @Test func notHeadingsOrLists() {
        #expect(ReleaseNotes.blocks("#hashtag\n-dash\n1.5 times faster") == [.paragraph(depth: 0, text: "#hashtag -dash 1.5 times faster")])
        #expect(ReleaseNotes.blocks("") == [])
        #expect(ReleaseNotes.blocks("## Install:\nstuff\n# Fixes\n- one") == [.heading(level: 1, text: "Fixes"), .bullet(depth: 0, text: "one")])
    }

    @Test func releasesSinceThisVersion() {
        func release(_ v: String) -> ReleaseInfo {
            ReleaseInfo(version: AppVersion(v)!, tag: "v" + v, pageURL: URL(string: "https://github.com/o/r/releases/tag/v" + v)!,
                        dmgURL: nil, checksumURL: nil, notes: v)
        }
        let list = ["0.7.0", "0.6.1", "0.6.0", "0.5.0", "0.4.0"].map(release)
        // 0.7.0 is published but "latest" still says 0.6.1: nothing newer than latest is offered.
        #expect(ReleaseInfo.since(AppVersion("0.5.0")!, latest: release("0.6.1"), among: list).map(\.tag) == ["v0.6.1", "v0.6.0"])
        #expect(ReleaseInfo.since(AppVersion("0.6.0")!, latest: release("0.6.1"), among: []).map(\.tag) == ["v0.6.1"])
        #expect(ReleaseInfo.since(AppVersion("0.1.0")!, latest: release("0.7.0"), among: list, limit: 3).map(\.tag) == ["v0.7.0", "v0.6.1", "v0.6.0"])
    }

    @Test func parsesAReleaseListAndDates() {
        let json = """
        [{"tag_name":"v0.6.0","html_url":"https://github.com/o/r/releases/tag/v0.6.0","body":"New","published_at":"2026-10-07T09:30:00Z","assets":[]},
         {"tag_name":"v0.6.0-beta.1","html_url":"https://github.com/o/r/releases/tag/v0.6.0-beta.1","prerelease":true,"assets":[]},
         {"tag_name":"v0.5.0","html_url":"https://github.com/o/r/releases/tag/v0.5.0","body":"Old","assets":[]}]
        """
        let list = ReleaseInfo.parseList(Data(json.utf8))
        #expect(list.map(\.tag) == ["v0.6.0", "v0.5.0"])
        #expect(list.first?.published == ISO8601DateFormatter().date(from: "2026-10-07T09:30:00Z"))
        #expect(ReleaseInfo.parseList(Data("{}".utf8)).isEmpty)
    }
}
