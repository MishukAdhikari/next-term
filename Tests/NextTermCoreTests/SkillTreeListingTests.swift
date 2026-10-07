import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillTreeListingTests {
    let listing = Data("""
        {"sha": "root", "truncated": false, "tree": [
          {"path": "README.md", "type": "blob", "sha": "a"},
          {"path": "skills", "type": "tree", "sha": "t-skills"},
          {"path": "skills/skill-creator", "type": "tree", "sha": "t-creator"},
          {"path": "skills/skill-creator/SKILL.md", "type": "blob", "sha": "b"},
          {"path": "skills/.curated", "type": "tree", "sha": "t-curated"},
          {"path": "skills/.curated/gh-fix-ci", "type": "tree", "sha": "t-fix"},
          {"path": "skills/.curated/gh-fix-ci/SKILL.md", "type": "blob", "sha": "c"},
          {"path": "SKILL.md", "type": "blob", "sha": "d"}
        ]}
        """.utf8)

    @Test func findsEverySkillFolderWithItsTree() throws {
        let all = try #require(SkillTreeListing.parse(listing, rootTree: "root", prefix: ""))
        #expect(all.skills == [SkillFolder(path: "", tree: "root"), SkillFolder(path: "skills/.curated/gh-fix-ci", tree: "t-fix"),
                               SkillFolder(path: "skills/skill-creator", tree: "t-creator")])
        #expect(all.skills[0].skillPath == "SKILL.md" && all.skills[2].skillPath == "skills/skill-creator/SKILL.md")
        #expect(!all.truncated)
        let one = try #require(SkillTreeListing.parse(listing, rootTree: "root", prefix: "skills/skill-creator"))
        #expect(one.skills.map(\.path) == ["skills/skill-creator"])
        // A prefix matches whole folder names only.
        #expect(SkillTreeListing.parse(listing, rootTree: "root", prefix: "skills/skill")?.skills.isEmpty == true)
        #expect(SkillTreeListing.parse(Data("[]".utf8), rootTree: "root", prefix: "") == nil)
    }

    @Test func aTruncatedListingSaysSo() throws {
        let data = Data(#"{"truncated": true, "tree": []}"#.utf8)
        #expect(try #require(SkillTreeListing.parse(data, rootTree: "r", prefix: "")).truncated)
    }

    /// GitHub serves a fork's commits under the parent's name: only a commit on the default branch counts.
    @Test func onlyCommitsOnTheBranchCount() {
        #expect(SkillTreeListing.commitIsOnBranch(compareStatus: "identical"))
        #expect(SkillTreeListing.commitIsOnBranch(compareStatus: "ahead"))
        #expect(!SkillTreeListing.commitIsOnBranch(compareStatus: "behind"))
        #expect(!SkillTreeListing.commitIsOnBranch(compareStatus: "diverged"))
        #expect(!SkillTreeListing.commitIsOnBranch(compareStatus: nil))
    }
}

@Suite struct SkillTreeListingRoundTwoTests {
    /// A folder named with a wildcard would be read by tar as a pattern: such folders are left out.
    @Test func foldersWithPatternCharactersAreLeftOut() throws {
        let data = Data(#"{"tree": [{"path": "skills/*", "type": "tree", "sha": "t1"}, {"path": "skills/*/SKILL.md", "type": "blob", "sha": "b"}, {"path": "skills/ok", "type": "tree", "sha": "t2"}, {"path": "skills/ok/SKILL.md", "type": "blob", "sha": "c"}]}"#.utf8)
        #expect(try #require(SkillTreeListing.parse(data, rootTree: "r", prefix: "")).skills.map(\.path) == ["skills/ok"])
    }

    @Test func tarPatternsAreLiteral() {
        #expect(SkillTreeListing.tarLiteral("top/skills/a*b?[c]\\d") == "top/skills/a\\*b\\?\\[c\\]\\\\d")
        #expect(SkillTreeListing.tarLiteral("top/skills/plain") == "top/skills/plain")
    }
}
