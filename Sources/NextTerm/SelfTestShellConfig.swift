import Foundation
import NextTermCore

/// A self-test never runs the user's shell config: each zsh tab it opens, by any route (⌘T, an MCP tool, a restore,
/// run_with_secrets), reads a config of the test's own (IsolatedShellConfig), so the lines it types never reach the
/// user's history file, and no theme, plugin or slow start of the user's changes what its checks read on the screen.
extension SelfTest {
    /// The plain self-test's own zsh config folder, made at its first tab, removed when it finishes. Nil outside it.
    nonisolated static let ownShellConfig: URL? = {
        guard mode == .plain else { return nil }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nextterm-selftest-zsh-\(getpid())", isDirectory: true)
        IsolatedShellConfig.prepare(folder)
        return folder
    }()

    /// The folder a self-test's zsh tabs read their config from: the relaunch harness's, else the plain self-test's own.
    /// Nil outside a self-test, where tabs read the user's own.
    nonisolated static var shellConfigFolder: String? {
        #if DEBUG
        if let harness = SelfTestRestore.harness { return harness.zdotdir.path }
        #endif
        return ownShellConfig?.path
    }
}
