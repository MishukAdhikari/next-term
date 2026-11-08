import AppKit
import NextTermCore

/// A stand-in for the chat view until the native one lands (plan 037 U6, which replaces this file): the header line and
/// the transcript as plain text, read-only, so a chat tab never shows its unused terminal. It sends nothing.
final class ChatPlaceholderView: NSScrollView {
    private weak var host: ChatTabHost?
    private let text = NSTextView()

    init(host: ChatTabHost) {
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        hasVerticalScroller = true
        drawsBackground = true
        backgroundColor = Theme.background
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textColor = Theme.text
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel("Chat")
        documentView = text
        host.onChange = { [weak self] _ in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func update() {
        guard let host else { return }
        let blocks = ChatTranscript.blocks(from: host.session, expanded: host.expanded, thoughtTimes: host.thoughtTimes)
        text.string = host.header.line + "\n\n" + ChatTranscript.plainText(blocks, lastLines: 2000)
        text.scrollToEndOfDocument(nil)
    }
}
