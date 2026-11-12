import Foundation

/// A window an agent opened over MCP on a temporary folder (its scratchpad: /private/tmp/claude-501/…/scratchpad): kept
/// out of Recent Projects, the Welcome window's history and the session restore, and closed by itself once nothing has
/// run in it for a while and the user never touched it.
///
/// No timer polls for it: the window arms one grace (`grace`) when it turns quiet (`isQuiet`), cancels it when it stops
/// being so, and closes when the grace ends with it still quiet. A window the user keyed or clicked into is theirs, and
/// stays.
public enum AgentScratch {
    /// How long a quiet window waits before it closes.
    public static let grace: TimeInterval = 60

    /// The system's temporary folders, as the kernel spells them and as they are typed.
    static func roots(temporary: String) -> [String] {
        var roots: [String] = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]
        let own: String = canonicalPath(temporary)
        if !own.isEmpty, own != "/" { roots.append(own.hasSuffix("/") ? String(own.dropLast()) : own) }
        return roots
    }

    /// Whether `path` is a temporary folder, or inside one: symlinks resolved, so /tmp/x and /private/tmp/x both are.
    public static func isTemporary(_ path: String, temporary: String = NSTemporaryDirectory()) -> Bool {
        let roots: [String] = roots(temporary: temporary)
        return [path, canonicalPath(path)].contains { (spelling: String) -> Bool in
            roots.contains { spelling == $0 || spelling.hasPrefix($0 + "/") }
        }
    }

    /// Whether a project goes into Recent Projects, the history and the session restore: every one but a temporary
    /// folder an agent opened. One the user opened there themselves (a fixture in /tmp) is kept as any other.
    public static func isRemembered(_ path: String, byAgent: Bool, temporary: String = NSTemporaryDirectory()) -> Bool {
        !(byAgent && isTemporary(path, temporary: temporary))
    }

    /// One terminal of the window, as the close decision reads it.
    public struct Tab: Equatable, Sendable {
        /// A program runs in front of its shell.
        public var running: Bool
        /// Jobs left suspended or in the background.
        public var jobs: Int
        public var state: TabState
        /// On a host: what runs there is not seen here, so it never counts as quiet.
        public var remote: Bool

        public init(running: Bool = false, jobs: Int = 0, state: TabState = .idle, remote: Bool = false) {
            self.running = running
            self.jobs = jobs
            self.state = state
            self.remote = remote
        }
    }

    /// What the window is, as the close decision reads it.
    public struct Window: Equatable, Sendable {
        /// An agent opened the window over MCP, on a temporary folder.
        public var scratch: Bool
        /// The user keyed or clicked into it, or brought it to the front.
        public var touched: Bool
        /// Its editor holds unsaved files or database values.
        public var unsaved: Bool
        public var tabs: [Tab]

        public init(scratch: Bool, touched: Bool = false, unsaved: Bool = false, tabs: [Tab]) {
            self.scratch = scratch
            self.touched = touched
            self.unsaved = unsaved
            self.tabs = tabs
        }
    }

    /// Whether the window may close by itself: an agent's scratch window the user never touched, nothing unsaved, and
    /// every terminal an idle shell: nothing running or suspended, no agent working or waiting on a decision.
    public static func isQuiet(_ window: Window) -> Bool {
        guard window.scratch, !window.touched, !window.unsaved, !window.tabs.isEmpty else { return false }
        return window.tabs.allSatisfy { (tab: Tab) -> Bool in
            !tab.remote && !tab.running && tab.jobs == 0 && tab.state != .working && tab.state != .attention
        }
    }
}
