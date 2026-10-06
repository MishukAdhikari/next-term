import Foundation
import Testing
@testable import NextTermCore

@Suite struct UpdatesTests {
    @Test func versions() {
        let v = { AppVersion($0)! }
        #expect(v("0.10.0") > v("0.9.2"))
        #expect(v("v1.2.3") == v("1.2.3"))
        #expect(v("1.2") == v("1.2.0"))
        #expect(v("1.0.0-beta.2") < v("1.0.0"))
        #expect(v("1.0.0-beta.2") > v("1.0.0-beta.1"))
        #expect(v("1.0.0-beta.10") > v("1.0.0-beta.9"))
        #expect(!(v("1.0.0") < v("1.0.0-rc.1")))
        #expect(AppVersion("dev") == nil && AppVersion("1.x") == nil && AppVersion("") == nil)
    }

    @Test func parsesTheLatestRelease() throws {
        let json = """
        {"tag_name":"v0.1.1","html_url":"https://github.com/MishukAdhikari/next-term/releases/tag/v0.1.1","draft":false,"prerelease":false,
         "body":"Fixes","assets":[
           {"name":"NextTerm-0.1.1.dmg","browser_download_url":"https://github.com/MishukAdhikari/next-term/releases/download/v0.1.1/NextTerm-0.1.1.dmg"},
           {"name":"NextTerm-0.1.1.dmg.sha256","browser_download_url":"https://github.com/MishukAdhikari/next-term/releases/download/v0.1.1/NextTerm-0.1.1.dmg.sha256"}]}
        """
        let info = try #require(ReleaseInfo.parse(Data(json.utf8)))
        #expect(info.version == AppVersion("0.1.1")! && info.tag == "v0.1.1")
        #expect(info.dmgURL?.lastPathComponent == "NextTerm-0.1.1.dmg")
        #expect(info.checksumURL?.lastPathComponent == "NextTerm-0.1.1.dmg.sha256")
        #expect(info.notes == "Fixes")
    }

    @Test func ignoresUnsafeOrUnfinishedReleases() {
        for url in ["https://evil.example/a.dmg", "http://github.com/a.dmg", "https://evilgithub.com/a.dmg", "file:///tmp/a.dmg"] {
            let foreign = #"{"tag_name":"v9.0.0","html_url":"https://github.com/x/y","assets":[{"name":"a.dmg","browser_download_url":"\#(url)"}]}"#
            #expect(ReleaseInfo.parse(Data(foreign.utf8))?.dmgURL == nil, "\(url)") // assets only from GitHub, over https
        }
        let local = #"{"tag_name":"v9.0.0","html_url":"https://github.com/x/y","assets":[{"name":"a.dmg","browser_download_url":"file:///tmp/a.dmg"}]}"#
        #expect(ReleaseInfo.parse(Data(local.utf8), allowingFileURLs: true)?.dmgURL?.path == "/tmp/a.dmg")
        let draft = #"{"tag_name":"v9.0.0","html_url":"https://github.com/x/y","draft":true}"#
        #expect(ReleaseInfo.parse(Data(draft.utf8)) == nil)
        let pre = #"{"tag_name":"v9.0.0-rc.1","html_url":"https://github.com/x/y","prerelease":true}"#
        #expect(ReleaseInfo.parse(Data(pre.utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("not json".utf8)) == nil)
    }

    @Test func checksumLines() {
        let hex = String(repeating: "ab", count: 32)
        #expect(ReleaseInfo.checksum(fromShasumLine: "\(hex)  NextTerm-0.1.1.dmg\n") == hex)
        #expect(ReleaseInfo.checksum(fromShasumLine: "nothex  x") == nil)
    }
}
