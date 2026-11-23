import Foundation

/// What the periodic save looks at before it captures the windows: everything a capture records that costs nothing to
/// read (the windows and their order, frames, tabs, splits, focus, each pane's folder, line, title and agent session),
/// read on the main thread every 2 seconds. A full capture reads each running tab's agent again from the kernel (its
/// arguments, environment, folder and open files), so it runs only when this moved (`SessionSaveSchedule`).
public struct SessionSignature: Equatable, Sendable {
    private var parts: [String] = []

    public init() {}

    /// One fact, by name: its words are kept apart so two facts never read as one.
    public mutating func add(_ name: String, _ values: String...) {
        add(name, values)
    }

    public mutating func add(_ name: String, _ values: [String]) {
        parts.append(([name] + values).joined(separator: "\u{1F}"))
    }

    /// A local pane's facts. The program's title is taken without the spinner frame an agent turns at its start while it
    /// works, which would otherwise make every tick a change.
    public mutating func addPane(id: UUID, directory: String, running: Bool, command: String, title: String?,
                                 agentSession: String?) {
        add("pane", id.uuidString, directory, running ? "running" : "idle", command,
            title.map { (title: String) -> String in "title:" + AgentTitle.withoutSpinnerFrame(title) } ?? "",
            agentSession ?? "")
    }
}

/// When the periodic save captures the windows in full: when the signature changed since the last capture, or
/// `refresh` has passed since it, which picks up what the signature cannot see (an agent's session id read from its open
/// files, a folder a shell without the integration moved to). An idle session then reads its agents twice a minute,
/// not every 2 seconds. The quit's save always captures in full and does not ask.
public struct SessionSaveSchedule: Sendable {
    /// The longest a full capture waits while the signature stays the same.
    public static let refresh: TimeInterval = 30

    private var last: SessionSignature?
    private var capturedAt: Date?

    public init() {}

    public func needsCapture(_ signature: SessionSignature, at now: Date) -> Bool {
        guard let last, let capturedAt else { return true }
        return last != signature || now.timeIntervalSince(capturedAt) >= Self.refresh
    }

    /// A full capture was taken with this signature.
    public mutating func captured(_ signature: SessionSignature, at now: Date) {
        last = signature
        capturedAt = now
    }

    /// The last capture was not written: the next tick captures again.
    public mutating func forget() {
        last = nil
        capturedAt = nil
    }
}
