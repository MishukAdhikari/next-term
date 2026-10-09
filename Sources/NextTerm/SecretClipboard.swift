import AppKit
import NextTermCore

/// The clipboard for Secrets (KTD24), on an injected pasteboard (KTD21): the app passes `.general`, the self-test a
/// private named one, so the user's clipboard is never read or cleared by a check.
///
/// - **Copy** prepares the pasteboard for this Mac only (`.currentHostOnly`), then writes the value with the
///   concealed and transient markers, so clipboard managers and Universal Clipboard are asked to leave it. After 60
///   seconds, when nothing else was copied since, Next Term clears it.
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

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Puts `value` on the pasteboard for this Mac only, marked concealed and transient, and clears it after
    /// `clearAfter` seconds unless something else was copied since.
    @discardableResult
    func copy(_ value: SecretBytes) -> Bool {
        guard let text = value.utf8String() else { return false }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let wrote = pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)
        let count = pasteboard.changeCount
        copiedCount = count
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
            MainActor.assumeIsolated { self?.clearCopy(ifStill: count) }
        }
        return wrote
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
