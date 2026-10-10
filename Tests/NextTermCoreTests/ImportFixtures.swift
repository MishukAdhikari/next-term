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
