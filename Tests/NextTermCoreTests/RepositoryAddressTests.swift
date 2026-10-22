import Foundation
import Testing
@testable import NextTermCore

/// A project's remote, read only to prefill Settings › Tasks: github.com and gitlab.com in their three usual spellings,
/// and nothing else.
@Suite struct RepositoryAddressTests {
    @Test func theThreeSpellingsOfGitHubAndGitLab() {
        let github = RepositoryAddress(host: .github, path: "example-org/web.app")
        for remote in ["git@github.com:example-org/web.app.git", "https://github.com/example-org/web.app",
                       "https://github.com/example-org/web.app.git", "ssh://git@github.com/example-org/web.app.git",
                       "https://GitHub.com/example-org/web.app/", " git@github.com:example-org/web.app\n"] {
            #expect(RepositoryAddress.parse(remote) == github, "\(remote)")
        }
        #expect(github.owner == "example-org" && github.repo == "web.app")
        #expect(github.destination == .github(owner: "example-org", repo: "web.app"))
        let gitlab = RepositoryAddress(host: .gitlab, path: "group/project")
        for remote in ["git@gitlab.com:group/project.git", "https://gitlab.com/group/project",
                       "ssh://git@gitlab.com/group/project.git"] {
            #expect(RepositoryAddress.parse(remote) == gitlab, "\(remote)")
        }
        #expect(gitlab.destination == .gitlab(path: "group/project"))
    }

    @Test func aGitLabSubgroupKeepsEverySegment() {
        let address = RepositoryAddress.parse("git@gitlab.com:group/sub/deeper/project.git")
        #expect(address == RepositoryAddress(host: .gitlab, path: "group/sub/deeper/project"))
        #expect(RepositoryAddress.parse("https://gitlab.com/group/sub/project.git")?.path == "group/sub/project")
        // GitHub has no subgroups: three segments are not a repository there.
        #expect(RepositoryAddress.parse("https://github.com/a/b/c") == nil)
    }

    @Test func anythingElseIsNothing() {
        for remote in ["https://github.com.evil.example/o/r.git", "git@github.com.evil.example:o/r.git",
                       "http://github.com/o/r.git", "https://github.com/o/../r", "git@github.com:../o/r.git",
                       "https://gitlab.example.com/group/project.git", "git@gitlab.example.com:group/project.git",
                       "https://github.com/o", "https://github.com/", "", "github.com/o/r", "/Users/x/repo.git",
                       "file:///srv/repo.git", "https://github.com/o/r?x=1", "https://github.com/o r/x",
                       "ssh://git@github.com:2222/o/r.git", "https://evil.example/github.com/o/r"] {
            #expect(RepositoryAddress.parse(remote) == nil, "\(remote)")
        }
    }
}
