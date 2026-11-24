import Foundation
#if canImport(Darwin)
import Darwin

/// Ending a listener whose accept loop runs on a thread of its own. Closing its descriptor hands the number back at once,
/// and a loop not blocked in `accept` that moment would next accept on whatever socket took the number meanwhile:
/// another listener's connections, answered by the wrong server. So the listener is retired instead: `shutdown` wakes
/// an accept under way, and the number is pointed at /dev/null, which frees the port but keeps the number from being
/// handed out, until the loop itself closes it as it ends (`loopEnded`).
public enum ListenerRetire {
    private static let null: Int32 = open("/dev/null", O_RDONLY | O_CLOEXEC)

    /// Stops listening on `fd`, from any thread; the accept loop sees an error and ends.
    public static func retire(_ fd: Int32) {
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        if null < 0 || dup2(null, fd) < 0 { close(fd) }
    }

    /// The accept loop on `fd` is ending: the number is closed once it was retired (no longer a socket). A loop that
    /// ends while its socket still listens leaves it to `retire`.
    public static func loopEnded(_ fd: Int32) {
        var info = stat()
        if fstat(fd, &info) == 0, info.st_mode & S_IFMT != S_IFSOCK { close(fd) }
    }
}
#endif
