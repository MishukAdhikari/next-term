import AppKit
import NextTermCore

/// The clipboard for Secrets, on an injected pasteboard: the app passes `.general`, the self-test a
/// private named one, so the user's clipboard is never read or cleared by a check.
///
/// - **Copy** prepares the pasteboard for this Mac only (`.currentHostOnly`), then writes the value and the concealed
///   and transient markers in one item, in one write, so clipboard managers and Universal Clipboard are asked to leave
///   it and none sees the value without them. After 60 seconds, when nothing else was copied since, Next Term clears it.
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
    /// The change count Copy left, while its clear is due.
    private(set) var copiedCount: Int?
    /// The last Copy asked for this Mac only (`.currentHostOnly`), for the self-test: macOS gives no way to read it back.
    private(set) var preparedForThisMacOnly = false
    #if DEBUG
    /// The last Copy's writes to the pasteboard, each the types it put there at once, for the self-test.
    private(set) var lastCopyWrites: [[NSPasteboard.PasteboardType]] = []
    #endif

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Puts `value` on the pasteboard for this Mac only, marked concealed and transient, and clears it after
    /// `clearAfter` seconds unless something else was copied since.
    @discardableResult
    func copy(_ value: SecretBytes) -> Bool {
        guard let text = value.utf8String() else { return false }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        preparedForThisMacOnly = true
        let item = Self.markedItem(text)
        #if DEBUG
        lastCopyWrites = [item.types]
        #endif
        let wrote = pasteboard.writeObjects([item])
        let count = pasteboard.changeCount
        copiedCount = count
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
            MainActor.assumeIsolated { self?.clearCopy(ifStill: count) }
        }
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
        guard copiedCount == count else { return }
        copiedCount = nil
        if pasteboard.changeCount == count { pasteboard.clearContents() }
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
