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

    @Test func picksTheVersionedAssetsOnly() throws {
        // The unversioned copies (for the website's releases/latest/download link) have no signature.
        let base = "https://github.com/MishukAdhikari/next-term/releases/download/v0.9.0/"
        let names = ["NextTerm.dmg", "NextTerm.dmg.sha256", "NextTerm-0.9.0.dmg", "NextTerm-0.9.0.dmg.sha256", "NextTerm-0.9.0.dmg.sha256.sig"]
        let assets = names.map { #"{"name":"\#($0)","browser_download_url":"\#(base + $0)"}"# }.joined(separator: ",")
        let json = #"{"tag_name":"v0.9.0","html_url":"https://github.com/MishukAdhikari/next-term/releases/tag/v0.9.0","assets":[\#(assets)]}"#
        let info = try #require(ReleaseInfo.parse(Data(json.utf8)))
        #expect(info.dmgURL?.lastPathComponent == "NextTerm-0.9.0.dmg")
        #expect(info.checksumURL?.lastPathComponent == "NextTerm-0.9.0.dmg.sha256")
        #expect(info.signatureURL?.absoluteString == base + "NextTerm-0.9.0.dmg.sha256.sig")
        // Only the unversioned copies, or another version's: nothing to install.
        for kept in [Array(names.prefix(2)), ["NextTerm-0.8.0.dmg", "NextTerm-0.8.0.dmg.sha256"]] {
            let assets = kept.map { #"{"name":"\#($0)","browser_download_url":"\#(base + $0)"}"# }.joined(separator: ",")
            let json = #"{"tag_name":"v0.9.0","html_url":"https://github.com/MishukAdhikari/next-term/releases/tag/v0.9.0","assets":[\#(assets)]}"#
            let info = try #require(ReleaseInfo.parse(Data(json.utf8)))
            #expect(info.dmgURL == nil && info.checksumURL == nil && info.signatureURL == nil, "\(kept)")
        }
    }

    @Test func ignoresUnsafeOrUnfinishedReleases() {
        for url in ["https://evil.example/a.dmg", "http://github.com/a.dmg", "https://evilgithub.com/a.dmg", "file:///tmp/a.dmg"] {
            let foreign = #"{"tag_name":"v9.0.0","html_url":"https://github.com/x/y","assets":[{"name":"NextTerm-9.0.0.dmg","browser_download_url":"\#(url)"}]}"#
            #expect(ReleaseInfo.parse(Data(foreign.utf8))?.dmgURL == nil, "\(url)") // assets only from GitHub, over https
        }
        let local = #"{"tag_name":"v9.0.0","html_url":"https://github.com/x/y","assets":[{"name":"NextTerm-9.0.0.dmg","browser_download_url":"file:///tmp/a.dmg"}]}"#
        #expect(ReleaseInfo.parse(Data(local.utf8), allowingFileURLs: true)?.dmgURL?.path == "/tmp/a.dmg")
        let draft = #"{"tag_name":"v9.0.0","html_url":"https://github.com/x/y","draft":true}"#
        #expect(ReleaseInfo.parse(Data(draft.utf8)) == nil)
        let pre = #"{"tag_name":"v9.0.0-rc.1","html_url":"https://github.com/x/y","prerelease":true}"#
        #expect(ReleaseInfo.parse(Data(pre.utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("not json".utf8)) == nil)
    }

    @Test func fallsBackToTheReleasesPage() {
        let page = URL(string: "https://github.com/MishukAdhikari/next-term/releases/tag/v0.2.0")!
        let info = ReleaseInfo.fromLatestRedirect(page, repository: "MishukAdhikari/next-term")
        #expect(info?.version == AppVersion("0.2.0")! && info?.tag == "v0.2.0")
        #expect(info?.dmgURL?.absoluteString == "https://github.com/MishukAdhikari/next-term/releases/download/v0.2.0/NextTerm-0.2.0.dmg")
        #expect(info?.checksumURL?.lastPathComponent == "NextTerm-0.2.0.dmg.sha256")
        #expect(info?.signatureURL?.lastPathComponent == "NextTerm-0.2.0.dmg.sha256.sig")
        // Still on the "latest" page (no releases), another repository, or not GitHub: nothing.
        #expect(ReleaseInfo.fromLatestRedirect(URL(string: "https://github.com/MishukAdhikari/next-term/releases")!, repository: "MishukAdhikari/next-term") == nil)
        #expect(ReleaseInfo.fromLatestRedirect(URL(string: "https://github.com/evil/x/releases/tag/v9.0.0")!, repository: "MishukAdhikari/next-term") == nil)
        #expect(ReleaseInfo.fromLatestRedirect(URL(string: "https://github.com/xMishukAdhikari/next-term/releases/tag/v9.0.0")!, repository: "MishukAdhikari/next-term") == nil)
        #expect(ReleaseInfo.fromLatestRedirect(URL(string: "https://evil.example/MishukAdhikari/next-term/releases/tag/v9.0.0")!, repository: "MishukAdhikari/next-term") == nil)
    }

    /// GitHub decides which release is latest, the release key does not: a pre-release made latest is
    /// not installed, as install.sh refuses it unless its version is asked for.
    @Test func neverTakesAPreReleaseAsLatest() {
        let page = URL(string: "https://github.com/MishukAdhikari/next-term/releases/tag/v9.0.0-rc1")!
        #expect(ReleaseInfo.fromLatestRedirect(page, repository: "MishukAdhikari/next-term") == nil)
        let json = #"{"tag_name":"v9.0.0-rc1","html_url":"\#(page.absoluteString)","prerelease":false,"assets":[]}"#
        #expect(ReleaseInfo.parse(Data(json.utf8)) == nil)
        #expect(ReleaseInfo.parseList(Data("[\(json)]".utf8)).isEmpty)
    }
}
