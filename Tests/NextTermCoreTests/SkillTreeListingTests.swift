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
        #expect(all.skills.map(\.path) == ["", "skills/.curated/gh-fix-ci", "skills/skill-creator"])
        #expect(all.skills.map(\.tree) == ["root", "t-fix", "t-creator"])
        #expect(all.skills[2].entries.contains("SKILL.md") && !all.skills[2].entries.contains { $0.hasPrefix("skills/") })
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

/// What /usr/bin/tar actually selects with the pattern list, run as the app runs it (no locale set).
@Suite struct SkillTreeListingRoundThreeTests {
    struct Entry {
        var name: [UInt8]
        var data: [UInt8] = []
        var folder = false
        /// The name goes in a pax header (as git does for long paths), not the plain header.
        var pax = false
    }

    func octal(_ value: Int, _ width: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array((String(repeating: "0", count: width - 1 - digits.count) + digits).utf8) + [0]
    }

    func header(_ name: [UInt8], size: Int, type: UInt8) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        block.replaceSubrange(0..<name.count, with: name)
        block.replaceSubrange(100..<108, with: octal(type == 0x35 ? 0o755 : 0o644, 8))
        block.replaceSubrange(108..<116, with: octal(0, 8))
        block.replaceSubrange(116..<124, with: octal(0, 8))
        block.replaceSubrange(124..<136, with: octal(size, 12))
        block.replaceSubrange(136..<148, with: octal(0, 12))
        block[156] = type
        block.replaceSubrange(257..<265, with: Array("ustar\u{0}00".utf8))
        block.replaceSubrange(148..<156, with: [UInt8](repeating: 0x20, count: 8))
        let sum = block.reduce(0) { $0 + Int($1) }
        block.replaceSubrange(148..<156, with: octal(sum, 7) + [0x20])
        return block
    }

    func padded(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: (512 - bytes.count % 512) % 512) }

    func archive(_ entries: [Entry]) -> Data {
        var out: [UInt8] = []
        for entry in entries {
            var name = entry.name
            if entry.pax {
                let body = Array(" path=".utf8) + entry.name + [0x0A]
                var length = body.count + 2
                if String(length).count + body.count != length { length += 1 }
                let record = Array(String(length).utf8) + body
                out += header(Array("PaxHeader".utf8), size: record.count, type: 0x78) + padded(record)
                name = Array("placeholder".utf8)
            }
            out += header(name, size: entry.folder ? 0 : entry.data.count, type: entry.folder ? 0x35 : 0x30)
            if !entry.folder { out += padded(entry.data) }
        }
        return Data(out + [UInt8](repeating: 0, count: 1024))
    }

    func tar(_ arguments: [String]) throws -> (status: Int32, out: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe(), errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        try process.run()
        let text = out.fileHandleForReading.readDataToEndOfFile()
        let complaints = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: text, as: UTF8.self), String(decoding: complaints, as: UTF8.self))
    }

    /// Non-ASCII folders are counted (tar prints their names as escapes here), and folders whose names
    /// decompose are found whichever way the archive stores them.
    @Test func foldersAreSelectedWhateverTheirSpelling() throws {
        let top = "example-skills-0123456"
        let nfc = "caf\u{E9}"
        // Committed decomposed (from a Mac), asked for by its composed name.
        let storedDecomposed = "re\u{301}sume\u{301}", asked = "r\u{E9}sum\u{E9}"
        let long = String(repeating: "long", count: 30) + "/\u{AC00}"
        var entries = [Entry(name: Array("\(top)/".utf8), folder: true), Entry(name: Array("\(top)/skills/".utf8), folder: true)]
        entries.append(Entry(name: Array("\(top)/skills/中文/SKILL.md".utf8), data: Array("zh".utf8)))
        for index in 0..<20 { entries.append(Entry(name: Array("\(top)/skills/中文/f\(index)".utf8), data: [0x61])) }
        entries.append(Entry(name: Array("\(top)/skills/\(nfc)/SKILL.md".utf8), data: Array("nfc".utf8)))
        entries.append(Entry(name: Array("\(top)/skills/\(long)/SKILL.md".utf8), data: Array("long".utf8), pax: true))
        entries.append(Entry(name: Array("\(top)/skills/other/SKILL.md".utf8), data: Array("other".utf8)))
        entries.append(Entry(name: Array("\(top)/skills/\(storedDecomposed)/SKILL.md".utf8), data: Array("nfd".utf8)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-tar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.tar")
        try archive(entries).write(to: file)

        func select(_ folders: [String]) throws -> (status: Int32, out: String, errors: String) {
            let patterns = root.appendingPathComponent("patterns-\(UUID().uuidString)")
            try SkillTreeListing.tarPatternList(folders.map { "\(top)/skills/\($0)" }).write(to: patterns)
            return try tar(["-tvf", file.path, "--null", "-T", patterns.path])
        }
        let chinese = try select(["中文"])
        #expect(chinese.status == 0)
        #expect(chinese.out.split(separator: "\n").count == 21)
        for folder in [nfc, long, asked] {
            let found = try select([folder])
            #expect(found.out.split(separator: "\n").count == 1, "\(folder)")
            // The spelling that isn't in the archive is reported, and only that.
            #expect(found.status == 0 || SkillTreeListing.tarErrorsAreOnlyMissingNames(found.errors), "\(found.errors)")
        }
        #expect(try select(["other"]).out.split(separator: "\n").count == 1)
        #expect(!SkillTreeListing.tarErrorsAreOnlyMissingNames("tar: Damaged tar archive\ntar: Error exit delayed from previous errors."))
    }

    @Test func eachFolderIsListedBothWays() {
        let list = SkillTreeListing.tarPatternList(["top/caf\u{E9}", "top/ok*"])
        let patterns = list.split(separator: 0).map { Array($0) }
        #expect(patterns.count == 6)
        #expect(patterns.contains(Array("top/caf\u{E9}".utf8)))
        #expect(patterns.contains(Array("top/cafe\u{301}/*".utf8)))
        #expect(patterns.contains(Array("top/ok\\*".utf8)))
    }

    /// Names as macOS decomposes them (some ranges stay whole) are in the list too, and a line
    /// separator inside a name doesn't split tar's complaint about it.
    @Test func moreSpellingsAndSeparators() {
        let patterns = SkillTreeListing.tarPatternList(["top/\u{2126}\u{E9}"]).split(separator: 0).map { Array($0) }
        #expect(patterns.contains(Array("top/\u{2126}e\u{301}".utf8)))
        #expect(SkillTreeListing.tarErrorsAreOnlyMissingNames("tar: top/a\u{2028}b: Not found in archive\ntar: Error exit delayed from previous errors.\n"))
    }

    /// A chosen folder must be reached through real folders: not through a link, even one whose name
    /// differs only in case.
    @Test func chosenFoldersAreReachedWithoutLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-real-\(UUID().uuidString)").path
        let outside = root + "-outside"
        try FileManager.default.createDirectory(atPath: root + "/skills/K", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside + "/.ssh", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/skills/K/L", withDestinationPath: outside)
        #expect(SkillTreeListing.isRealFolder("skills/K", in: root))
        #expect(SkillTreeListing.isRealFolder("", in: root))
        #expect(!SkillTreeListing.isRealFolder("skills/K/L/.ssh", in: root))
        #expect(!SkillTreeListing.isRealFolder("skills/k/L/.ssh", in: root))
        #expect(!SkillTreeListing.isRealFolder("skills/missing", in: root))
    }

    /// A long name tar unpacked decomposed gets its committed spelling back, and nothing is renamed
    /// through a link.
    @Test func namesGetTheirCommittedSpellingBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-spell-\(UUID().uuidString)").path
        let decomposed = "u\u{308}ber"
        let composed = "\u{FC}ber"
        try FileManager.default.createDirectory(atPath: root + "/refs", withIntermediateDirectories: true)
        // Made with the bytes as given (Foundation could change their spelling).
        let fd = open(root + "/refs/" + decomposed + ".md", O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        close(fd)
        #expect(SkillTreeListing.rawNames(in: root + "/refs").map { Array($0.utf8) } == [Array((decomposed + ".md").utf8)])
        SkillTreeListing.restoreSpelling(in: root, entries: ["refs", "refs/" + composed + ".md"])
        #expect(SkillTreeListing.rawNames(in: root + "/refs").map { Array($0.utf8) } == [Array((composed + ".md").utf8)])
    }
}

