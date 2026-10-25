import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Wrap Up's request to an agent tab: one fixed line naming a file inside the project; the file's name from the day and
/// the tab's masked title; the folder from the project's own setting, never outside the project.
@Suite struct HandoffRequestTests {
    static let path = "docs/handoffs/2026-10-18-api-tab.md"
    static let day = TaskDay("2026-10-18")!

    @Test func theRequestIsOneFixedLine() {
        let pinned = "Write a short handoff for this session to docs/handoffs/2026-10-18-api-tab.md (create the folder "
            + "if needed) with exactly these sections: ## Done, ## Next (one \"- \" line per next step, each a task "
            + "someone can start tomorrow), ## Open questions, ## How to resume. Write only that file; change nothing "
            + "else and don't commit it."
        let text = HandoffRequest.text(path: Self.path) ?? ""
        #expect(text == pinned)
        #expect(Array(text.utf8) == Array(pinned.utf8))
        #expect(HandoffRequest.version == 1)
        #expect(!text.contains("\n") && !text.contains("\r"))
        #expect(!text.contains("/Users/") && !text.contains("~"))
    }

    @Test func aPathWithALineBreakOrControlCharacterIsNeverTyped() {
        for path in ["notes\nx/a.md", "notes\rx/a.md", "a\u{1b}[31m/a.md", "a\tb/a.md", "a\u{2028}b/a.md",
                     "a\u{85}b/a.md", "a\u{0}b/a.md", "a\u{200e}b/a.md"] {
            #expect(HandoffRequest.text(path: path) == nil, "\(path.debugDescription)")
        }
    }

    @Test func aNameIsTheDayAndTheTabsTitle() {
        let none: (String) -> String = { $0 }
        let names = HandoffName.names(day: Self.day, tab: "API tab", mask: none)
        #expect(names.first == "2026-10-18-api-tab.md")
        #expect(names.count == TodoFile.lastNumber)
        #expect(names[1] == "2026-10-18-api-tab-2.md" && names.last == "2026-10-18-api-tab-99.md")

        let first = HandoffName.pick(day: Self.day, tab: "API tab", taken: { _ in false }, mask: none)
        #expect(first == "2026-10-18-api-tab.md")
        let taken: (String) -> Bool = { $0 == "2026-10-18-api-tab.md" }
        let second = HandoffName.pick(day: Self.day, tab: "API tab", taken: taken, mask: none)
        #expect(second == "2026-10-18-api-tab-2.md")
        #expect(HandoffName.pick(day: Self.day, tab: "API tab", taken: { _ in true }, mask: none) == nil)
    }

    @Test func twoTabsWithOneTitleGetTwoNames() {
        var given: Set<String> = []
        for _ in 0..<2 {
            let name = HandoffName.pick(day: Self.day, tab: "claude", taken: { given.contains($0) }, mask: { $0 })
            if let name { given.insert(name) }
        }
        #expect(given == ["2026-10-18-claude.md", "2026-10-18-claude-2.md"])
    }

    @Test func aTabTitleNamesNoStoredKey() {
        let value = "sk-ant-abc123def456"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let names = HandoffName.names(day: Self.day, tab: "fix \(value) tab", mask: { mask.mask($0) })
        let name = names[0]
        #expect(name == "2026-10-18-fix-tab.md")
        for part in ["sk-ant", "abc123", "def456", "•"] { #expect(!name.contains(part), "\(part)") }
        // A title that is only a key is named for the session, not the key.
        #expect(HandoffName.names(day: Self.day, tab: value, mask: { mask.mask($0) })[0] == "2026-10-18-session.md")
    }

    @Test func aNameIsAsciiLettersDigitsAndDashesOnly() {
        // A program can set its tab's title, so the title's own words never reach the typed path as anything else.
        let typed = HandoffName.names(day: Self.day, tab: "~ $(x) ignore-all; `rm` \"q\" <a>|b&c*", mask: { $0 })[0]
        #expect(typed == "2026-10-18-x-ignore-all-rm-q-ab-c.md")
        #expect(HandoffName.names(day: Self.day, tab: "Café • naïve", mask: { $0 })[0] == "2026-10-18-cafe-naive.md")
        #expect(HandoffName.names(day: Self.day, tab: "日本語", mask: { $0 })[0] == "2026-10-18-session.md")
        #expect(HandoffName.names(day: Self.day, tab: "-- a --", mask: { $0 })[0] == "2026-10-18-a.md")
        for tab in ["~ $(x) ignore-all", "a\u{1b}]0;x\u{7}b", "line\nbreak", "./..//x", "%2e%2e"] {
            for name in HandoffName.names(day: Self.day, tab: tab, mask: { $0 }) {
                let stem = name.dropLast(3)
                let plain = stem.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "-" || $0.properties.isAlphabetic
                    || ("0"..."9").contains($0)) }
                #expect(plain && name.hasSuffix(".md"), "\(name)")
            }
        }
    }

    @Test func aTitleWithASlashOrDotsStaysOneName() {
        let name = HandoffName.names(day: Self.day, tab: "../../etc/passwd", mask: { $0 })[0]
        #expect(!name.contains("/") && name.hasPrefix("2026-10-18-") && name.hasSuffix(".md"))
    }
    /// A path the key mask would change is never typed: no stored key reaches the agent's prompt, and a masked path
    /// would name a file Wrap Up never looks for. A path the mask leaves alone is typed as it is.
    @Test func aPathTheMaskWouldChangeIsNeverTyped() {
        let value = "made-up-" + "key-" + "0123456789abcdef"
        let mask: (String) -> String = { (text: String) -> String in
            text.replacingOccurrences(of: value, with: "•••")
        }
        #expect(HandoffRequest.text(path: "docs/\(value)/2026-10-18-api.md", mask: mask) == nil)
        let plain: String? = HandoffRequest.text(path: "docs/handoffs/2026-10-18-api.md", mask: mask)
        #expect(plain?.contains("docs/handoffs/2026-10-18-api.md") == true)
        #expect(plain?.contains("•••") == false)
    }

}

/// The handoff folder: the project's own setting, relative to it, else `docs/handoffs`. A setting that is absolute,
/// leaves the project with `..`, goes into git's folder or passes through a linked folder is never used.
@Suite struct HandoffFolderTests {
    func project() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-handoff-\(UUID().uuidString)"
        for folder in ["/project", "/elsewhere"] {
            try FileManager.default.createDirectory(atPath: dir + folder, withIntermediateDirectories: true)
        }
        return dir
    }

    func settings(_ project: String, _ folder: String?) -> TaskSettings {
        var settings = TaskSettings()
        settings.projects[TaskSettings.projectKey(project)] = ProjectTasks(handoffFolder: folder)
        return settings
    }

    @Test func noSettingIsDocsHandoffs() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        #expect(TaskSettings.defaultHandoffFolder == "docs/handoffs")
        #expect(TaskSettings().handoffFolder(for: project) == "docs/handoffs")
        #expect(settings(project, nil).handoffFolder(for: project) == "docs/handoffs")
        #expect(settings(project, "  ").handoffFolder(for: project) == "docs/handoffs")
    }

    @Test func aFolderInsideTheProjectIsUsedAsWritten() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        #expect(settings(project, "notes/handoffs").handoffFolder(for: project) == "notes/handoffs")
        #expect(settings(project, "./notes/handoffs/").handoffFolder(for: project) == "notes/handoffs")
        // Another project's setting is not this one's.
        var other = TaskSettings()
        other.projects[TaskSettings.projectKey(dir + "/elsewhere")] = ProjectTasks(handoffFolder: "notes")
        #expect(other.handoffFolder(for: project) == "docs/handoffs")
    }

    @Test func aFolderOutsideTheProjectFallsBack() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        try FileManager.default.createSymbolicLink(atPath: project + "/out", withDestinationPath: dir + "/elsewhere")
        for setting in ["/tmp/x", "~/x", "../x", "notes/../../x", ".git/handoffs", "out", "out/handoffs", "a\0b"] {
            #expect(settings(project, setting).handoffFolder(for: project) == "docs/handoffs", "\(setting)")
            #expect(TaskSettings.handoffFolder(setting, in: project) == nil, "\(setting)")
        }
        #expect(TaskSettings.handoffFolder("notes", in: project) == "notes")
        // A linked folder is refused even when it points inside the project: the agent writes where the path says.
        try FileManager.default.createDirectory(atPath: project + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/linked", withDestinationPath: project + "/real")
        #expect(TaskSettings.handoffFolder("linked", in: project) == nil)
        #expect(TaskSettings.handoffFolder("linked/more", in: project) == nil)
        #expect(TaskSettings.handoffFolder("real/more", in: project) == "real/more")
    }

    @Test func aLineBreakOrControlCharacterInTheSettingFallsBack() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        for setting in ["notes\nx", "notes\rx", "a\u{1b}[31m", "a\tb", "a\u{2028}b", "a\u{85}b", "a\u{7f}b",
                        "a\u{200e}b"] {
            #expect(TaskSettings.handoffFolder(setting, in: project) == nil, "\(setting.debugDescription)")
            #expect(settings(project, setting).handoffFolder(for: project) == "docs/handoffs")
        }
        // A line end around the whole setting is trimmed, as any space is.
        #expect(TaskSettings.handoffFolder("notes\n", in: project) == "notes")
    }

    @Test func aLinkedDocsHandoffsIsNeverUsed() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        try FileManager.default.createDirectory(atPath: project + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/docs/handoffs",
                                                   withDestinationPath: dir + "/elsewhere")
        #expect(TaskSettings().handoffFolder(for: project) == nil)
        // The project's own setting is still used when it can be.
        #expect(settings(project, "notes").handoffFolder(for: project) == "notes")
        #expect(settings(project, "out/../x/../../y").handoffFolder(for: project) == nil)
        // A linked docs folder is the same.
        let other = dir + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other + "/docs", withDestinationPath: dir + "/elsewhere")
        #expect(TaskSettings().handoffFolder(for: other) == nil)
        // A project folder that is not there has no folder.
        #expect(TaskSettings().handoffFolder(for: dir + "/gone") == nil)
    }

    @Test func aFileWhereTheFolderWouldBeFallsBack() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        FileManager.default.createFile(atPath: project + "/notes", contents: Data("x".utf8))
        #expect(settings(project, "notes").handoffFolder(for: project) == "docs/handoffs")
    }
}
