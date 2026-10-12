import Foundation

/// Where a folder opens as a project (⌘O, Open Recent, a folder dropped on the Dock icon or named by `open -a` once the
/// launch is done), and when what a launch names opens (R32).
public enum ProjectOpening {
    /// Settings › "Open Projects In", and the Ask dialog's remembered choice, by the words they are saved as.
    public enum Setting: String, CaseIterable, Sendable {
        case ask, thisWindow, newWindow
    }

    /// The window Open Project was asked from.
    public struct Target: Equatable, Sendable {
        /// Nobody has used it yet: no project, one tab, nothing run in it, nothing restored into it.
        public var pristine: Bool
        /// It holds tabs the restore brought back that the user has not put anything in yet: their put-back lines,
        /// notes and scrollback, which the user may not have seen.
        public var holdsRestore: Bool

        public init(pristine: Bool, holdsRestore: Bool) {
            self.pristine = pristine
            self.holdsRestore = holdsRestore
        }
    }

    /// Where the folder goes, once no window has its project open already.
    public enum Placement: Equatable, Sendable {
        /// The window becomes the project's.
        case adopt
        /// The user picks New Window or This Window.
        case ask
        /// This window: its tabs make way for the project's.
        case replace
        case newWindow
    }

    /// An unused window is taken over; otherwise the setting decides. A window the restore brought back, while it holds
    /// what came back, is never taken over or replaced: the folder opens in a window of its own, and nothing asks.
    public static func placement(from target: Target?, setting: Setting) -> Placement {
        guard let target, !target.holdsRestore else { return .newWindow }
        if target.pristine { return .adopt }
        switch setting {
        case .ask: return .ask
        case .thisWindow: return .replace
        case .newWindow: return .newWindow
        }
    }

    /// What `application(_:open:)` names (a folder dropped on the Dock icon, `open -a "Next Term" dir`, Finder's Open
    /// With), by when it comes. Before the launch hook it is held: the restore builds its windows first, so the request
    /// never makes a window of its own for a project the restore brings back, nor a second one for a file in it. What was
    /// held, and what comes until the launch has shown what it shows, opens as `nxtrm` opens it, in front of the restored
    /// windows (`asRequest`). After that, a folder opens as Open Project does (`placement`).
    public struct LaunchRequests: Sendable {
        public enum Arrival: Equatable, Sendable {
            case held, asRequest, asProject
        }

        /// Nil once the hook has run.
        private var held: [URL]? = []
        private var launching = true

        public init() {}

        /// Something named now: held until the hook has run, or opened now, as the launch's request or as Open Project.
        public mutating func arrive(_ urls: [URL]) -> Arrival {
            if held != nil {
                held?.append(contentsOf: urls)
                return .held
            }
            return launching ? .asRequest : .asProject
        }

        /// The launch hook ran: what was held, to open as the launch's request. Nothing is held from now on.
        public mutating func restored() -> [URL] {
            let urls = held ?? []
            held = nil
            return urls
        }

        /// The launch showed what it shows.
        public mutating func shown() {
            held = nil
            launching = false
        }
    }
}
