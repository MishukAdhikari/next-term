import AppKit
import NextTermCore

/// The clipboard for Secrets, on an injected pasteboard: the app passes `.general`, the self-test a
/// private named one, so the user's clipboard is never read or cleared by a check.
///
/// - **Copy** prepares the pasteboard for this Mac only (`.currentHostOnly`), then writes the value and the concealed
///   and transient markers in one item, in one write, so clipboard managers and Universal Clipboard are asked to leave
///   it and none sees the value without them. After 60 seconds, when nothing else was copied since, Next Term clears it,
///   by the wall clock, so a clear that comes due while the Mac sleeps runs on wake. Quitting (an update's restart too), or
///   the Mac locking or going to sleep, clears it sooner, when it is still there.
/// - **A paste into a value field** records the pasteboard's change count. On Save the pasteboard is cleared only when
///   that count is unchanged. Next Term never reads the pasteboard, so macOS's paste alert never shows.
@MainActor
final class SecretClipboard {
    static let shared = SecretClipboard(pasteboard: SelfTest.isRequested
        ? NSPasteboard(name: NSPasteboard.Name("NextTermSelfTest-\(UUID().uuidString)")) : .general)

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let copiedLine = "Copied. Next Term clears the clipboard in 60 seconds."
    static let clearedLine = "Cleared the clipboard, which held this key."

    let pasteboard: NSPasteboard
    /// How long a copied key stays (the self-test shortens it).
    var clearAfter: TimeInterval = 60
    /// The copy whose clear is due, by the change count Copy left.
    private var pending = SecretCopyClear()
    /// The change count Copy left, while its clear is due.
    var copiedCount: Int? { pending.copiedCount }
    /// The quit's and the lock's observers, added at the first Copy.
    private var observers: [NSObjectProtocol] = []
    /// The last Copy asked for this Mac only (`.currentHostOnly`), for the self-test: macOS gives no way to read it back.
    private(set) var preparedForThisMacOnly = false
    #if DEBUG
    /// The types the pasteboard held just before and just after the last Copy's write, read back from the pasteboard,
    /// for the self-test; nil when that Copy made no write through `write(_:)`.
    private(set) var lastCopyWrite: (before: [NSPasteboard.PasteboardType], after: [NSPasteboard.PasteboardType])?
    #endif

    /// Where the quit and the lock are heard: the app's own center, or a stand-in clipboard's in the self-test, which
    /// posts a quit there that nothing else hears.
    private let center: NotificationCenter

    init(pasteboard: NSPasteboard, center: NotificationCenter = .default) {
        self.pasteboard = pasteboard
        self.center = center
    }

    /// Puts `value` on the pasteboard for this Mac only, marked concealed and transient, and clears it after
    /// `clearAfter` seconds unless something else was copied since.
    @discardableResult
    func copy(_ value: SecretBytes) -> Bool {
        guard let text = value.utf8String() else { return false }
        #if DEBUG
        lastCopyWrite = nil
        #endif
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        preparedForThisMacOnly = true
        let wrote = write([Self.markedItem(text)])
        let count = pasteboard.changeCount
        pending.copied(count)
        startObserving()
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + clearAfter) { [weak self] in
            MainActor.assumeIsolated { self?.clearCopy(ifStill: count) }
        }
        return wrote
    }

    /// Clears a copied key at quit, and when the Mac locks or goes to sleep (Secrets' `locked`). The quit's observer runs
    /// on the posting thread, the main one, since the app exits right after it.
    private func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearPendingCopy() }
        })
        observers.append(center.addObserver(forName: SecretsStore.locked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearPendingCopy() }
        })
    }

    /// Copy's one write. A debug build reads back what the pasteboard holds just before and just after it, for the
    /// self-test: the value written before it, or a marker written after it, shows there.
    private func write(_ items: [NSPasteboardItem]) -> Bool {
        #if DEBUG
        let before = pasteboard.types ?? []
        #endif
        let wrote = pasteboard.writeObjects(items)
        #if DEBUG
        lastCopyWrite = (before, pasteboard.types ?? [])
        #endif
        return wrote
    }

    /// `text` and both markers in one pasteboard item, the markers first.
    static func markedItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: concealedType)
        item.setData(Data(), forType: transientType)
        item.setString(text, forType: .string)
        return item
    }

    /// The copy's clear: only when the pasteboard still holds what Copy put there.
    func clearCopy(ifStill count: Int) {
        if pending.due(count, current: pasteboard.changeCount) { pasteboard.clearContents() }
    }

    /// Before its 60 seconds are up: clears a copied key still on the pasteboard, and its timer then does nothing.
    /// Something copied since is kept.
    func clearPendingCopy() {
        if pending.now(current: pasteboard.changeCount) { pasteboard.clearContents() }
    }

    /// A paste into a value field: the change count to compare on Save. The pasteboard's contents are not read.
    func recordPaste() -> Int { pasteboard.changeCount }

    /// On Save after a paste: clears the pasteboard when nothing was copied since the paste. True when it cleared it.
    @discardableResult
    func clearAfterSave(pastedAt count: Int?) -> Bool {
        guard let count, pasteboard.changeCount == count else { return false }
        pasteboard.clearContents()
        return true
    }
}
