import AppKit
import NextTermCore

/// The last turns of the session selected in ⌥⌘O (plan 039 U4): its transcript's tail on this Mac, read off the main
/// thread, as the agent peek shows a tab's conversation. Claude Code's and Codex's transcripts; other agents say so.
final class SessionPreview: NSView {
    private let scroll = NSScrollView()
    let textView = NSTextView()
    private var shown: String?
    private var cache: [String: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.withAlphaComponent(0.35).cgColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = Theme.text
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The preview's text as it shows.
    var text: String { textView.string }

    /// Shows `session`'s last turns, read in the background; nil empties the preview.
    func show(_ session: AgentSession?) {
        guard let session else {
            shown = nil
            return set("")
        }
        let key = session.identity + "@\(session.updatedAt.timeIntervalSince1970)"
        guard key != shown else { return }
        shown = key
        if let cached = cache[key] { return set(cached) }
        set("Reading the conversation…", dim: true)
        let home = SessionStore.home // where the list was read, a folder of its own in the self-test
        Task.detached(priority: .userInitiated) {
            let text = Self.read(session, home: home)
            await MainActor.run { [weak self] in
                guard let self, self.shown == key else { return }
                self.cache[key] = text
                self.set(text, dim: false)
            }
        }
    }

    /// The last turns of `session`'s transcript as text, or why there are none.
    nonisolated static func read(_ session: AgentSession, home: String) -> String {
        let located = AgentTranscript.locate(agent: session.agent, sessionID: session.id)
        let path = located.flatMap { AgentTranscript.only(AgentTranscript.candidates($0, home: home, environment: ProcessInfo.processInfo.environment)) }
        switch (located, path) {
        case (.success(let locator), .success(let path)):
            guard let read = AgentTranscript.readTail(path) else { return "The transcript could not be read." }
            guard let turns = AgentTranscript.turns(tail: read.tail, kind: locator.kind), !turns.isEmpty else {
                return AgentTranscript.Unread.unparsed.reason
            }
            return AgentTranscript.text(turns, agent: session.agent.name)
        case (.failure(.notRead), _):
            return "No preview for \(session.agent.name) sessions yet: Next Term reads Claude Code’s and Codex’s conversations."
        case (.failure(let why), _), (_, .failure(let why)):
            return why.reason
        }
    }

    private func set(_ text: String, dim: Bool = false) {
        textView.string = text
        textView.textColor = dim ? Theme.textDim : Theme.text
        textView.scrollToEndOfDocument(nil)
    }
}
