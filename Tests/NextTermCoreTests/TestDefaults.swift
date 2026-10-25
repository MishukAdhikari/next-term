import Foundation
@testable import NextTermCore

/// A UserDefaults suite of a test's own that leaves nothing behind. Named by a path in the temporary folder, as the
/// relaunch harness's is, its file is written there and not in ~/Library/Preferences, where removePersistentDomain
/// empties a suite but keeps its file (one 42-byte plist per suite per test run had piled up there).
enum TestDefaults {
    /// A new suite and its name (a path), for `remove` after the test.
    static func make(_ label: String) throws -> (UserDefaults, String) {
        let name = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-defaults-\(label)-\(getpid())-\(UUID().uuidString.prefix(8))"
        guard let defaults = UserDefaults(suiteName: name) else { throw CocoaError(.fileWriteUnknown) }
        return (defaults, name)
    }

    /// Empties the suite and deletes its file.
    static func remove(_ defaults: UserDefaults, _ name: String) {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
