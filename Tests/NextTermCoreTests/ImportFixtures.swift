import Foundation
import Testing
@testable import NextTermCore

/// The hand-written fixture configs in Fixtures/Import/<app> (never copied from a real Mac), and the checks
/// every importer's tests share: no reader starts a process, and no planted secret comes out.
enum ImportFixtures {
    /// Fixtures/Import, in the source tree.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Import")

    /// The fake secrets the fixtures plant (each shaped so SecretGuard knows it), which nothing an import
    /// returns may hold.
    static let plantedSecrets = [
        "eyJhbGciOiJIUzI1NiJ9.eyJmaXh0dXJlIjoic2VjcmV0In0.bm90LWEtcmVhbC1zaWduYXR1cmU",
        "FixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ]

    /// A copy of the fixture `name` in a new temp folder (a test may add dates or databases to it), as its
    /// real path. The caller removes it.
    static func copy(_ name: String) throws -> String {
        let folder = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-fx-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let home = folder + "/home"
        try FileManager.default.copyItem(atPath: root.appendingPathComponent(name).path, toPath: home)
        return home
    }

    /// Every planted secret found in `value`'s full description (a plan, detected apps, anything).
    static func secrets(in value: Any) -> [String] {
        let text = String(describing: value)
        return plantedSecrets.filter { text.contains($0) }
    }

    /// Detection and every found app's plan in a fixture `home`, with the files the readers opened meanwhile
    /// (ImportFile.opened): relative to `home`, sorted. A file outside the home keeps its full path, so a test
    /// comparing against its list sees it.
    static func watched(home: String, detect: () -> [DetectedApp],
                        plan: (DetectedApp) -> ImportPlan) -> (opened: [String], plans: [(app: DetectedApp, plan: ImportPlan)]) {
        let files = ImportFile.OpenedFiles()
        let plans = ImportFile.$opened.withValue(files) { detect().map { (app: $0, plan: plan($0)) } }
        let opened = files.all.map { $0.hasPrefix(home + "/") ? String($0.dropFirst(home.count + 1)) : $0 }
        return (opened.sorted(), plans)
    }

    /// Next Term's commands with no keys at all, so no imported row clashes.
    static var noKeys: [String: KeyChord?] { Dictionary(uniqueKeysWithValues: ImportShortcuts.titles.keys.map { ($0, KeyChord?.none) }) }

    /// The preview_import answers an agent gets for each app in `plans`, by app name, as MCPImportControl builds them
    /// (settled against no keys; the window's titles stubbed; the plan_id, which hashes the temp home's paths, fixed).
    static func previews(_ plans: [(app: DetectedApp, plan: ImportPlan)], home: String) -> String {
        let context = MCPImport.PreviewContext(currentPreset: .nextTerm, keysNow: noKeys, title: { "\($0.key) title" }, home: home)
        var answer: [String: Any] = [:]
        for (app, raw) in plans {
            var preview = MCPImport.preview(source: app.name, plan: raw.settlingShortcuts(current: noKeys), planID: "p-0", context: context)
            preview["plan_id"] = "p-(differs with the home folder)"
            answer[app.name] = preview
        }
        return MCPImport.text(answer, home: home, hiding: plans.map(\.app.configPath)) + "\n"
    }

    /// The golden file Fixtures/Import/<name>/preview.golden.json and the previews now: NEXTTERM_UPDATE_GOLDEN=1
    /// writes the file anew first (read it by hand before committing it).
    static func golden(_ name: String, _ text: String) throws -> String {
        let file = root.appendingPathComponent(name).appendingPathComponent("preview.golden.json")
        if ProcessInfo.processInfo.environment["NEXTTERM_UPDATE_GOLDEN"] == "1" { try text.write(to: file, atomically: true, encoding: .utf8) }
        return try String(contentsOf: file, encoding: .utf8)
    }
}

@Suite struct ImportFixturesTests {
    /// No import reader starts a program or runs another app's code: none of them names a way to.
    @Test func importReadersNeverStartAProcess() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var files: [URL] = []
        for target in ["NextTermCore", "NextTerm"] {
            let folder = sources.appendingPathComponent(target)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            files += names.filter { $0.hasPrefix("Import") && $0.hasSuffix(".swift") }.map { folder.appendingPathComponent($0) }
        }
        #expect(files.count >= 13)
        let patterns = [#"\bProcess\b"#, #"\bNSTask\b"#, #"\bsystem\("#, #"posix_spawn"#, #"\bpopen\("#, #"\bexecv"#, #"\bfork\("#,
                        #"NSAppleScript"#, #"\bdlopen\("#]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(file.lastPathComponent): \(pattern)")
            }
        }
    }

    /// Readers open files only where the opening is recorded (ImportFile.record, which the file-access tests watch):
    /// every read handle and SQLite open in an import reader is followed by one, and no other way to read a file
    /// appears in them.
    @Test func importReadersOpenFilesOnlyWhereItIsRecorded() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NextTermCore")
        let names = try FileManager.default.contentsOfDirectory(atPath: core.path).filter { $0.hasPrefix("Import") && $0.hasSuffix(".swift") }
        #expect(names.count >= 13)
        let others = [#"contents\(atPath"#, #"\bData\(contentsOf"#, #"\bString\(contentsOf"#, #"NSDictionary\(contentsOf"#,
                      #"NSData\(contentsOf"#, #"\bfopen\("#, #"XMLParser\(contentsOf"#, #"InputStream\("#, #"forReadingFrom"#,
                      #"(?<![\w.])open\("#, #"\bmmap\("#, #"sqlite3_open\("#]
        var opens = 0
        for name in names {
            let text = try String(contentsOf: core.appendingPathComponent(name), encoding: .utf8)
            func count(_ pattern: String) -> Int {
                let regex = try? NSRegularExpression(pattern: pattern)
                return regex?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
            }
            let opening = count(#"FileHandle\(forReadingAtPath"#) + count(#"sqlite3_open_v2\("#)
            #expect(opening == count(#"ImportFile\.record\("#), "\(name)")
            for pattern in others { #expect(count(pattern) == 0, "\(name): \(pattern)") }
            opens += opening
        }
        #expect(opens == 5, "ImportFile.data, ImportVSCode.readText, ImportJetBrains.read and the two SQLite opens")
    }

    @Test func fixturesPlantTheirSecrets() throws {
        let home = try ImportFixtures.copy("VSCodeFamily")
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let settings = try String(contentsOfFile: home + "/Library/Application Support/Trae/User/settings.json", encoding: .utf8)
        #expect(!ImportFixtures.secrets(in: settings).isEmpty)
        #expect(ImportFixtures.plantedSecrets.allSatisfy(SecretGuard.looksSecret))
    }

    /// Each terminal's fixture plants both fake secrets somewhere, so its tests' "none comes out" checks mean something.
    @Test func terminalFixturesPlantTheirSecrets() throws {
        for name in ["Alacritty", "kitty", "WezTerm", "cmux", "iTerm2"] {
            let folder = ImportFixtures.root.appendingPathComponent(name).path
            var text = ""
            let walker = FileManager.default.enumerator(atPath: folder)
            while let relative = walker?.nextObject() as? String {
                let path = (folder as NSString).appendingPathComponent(relative)
                if isRegularFile(path), let contents = try? String(contentsOfFile: path, encoding: .utf8) { text += contents }
            }
            let found: [String] = ImportFixtures.secrets(in: text)
            #expect(found == ImportFixtures.plantedSecrets, "\(name)")
        }
    }
}
