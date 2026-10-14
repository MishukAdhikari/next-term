import Foundation
import LocalAuthentication
import Security

/// A presence check before Secrets uses or changes a key: Touch ID or the Mac password in the app, a stand-in in the
/// self-test. The token it returns goes to the keyring (an evaluated `LAContext`), and `finish` lets it go.
@MainActor
protocol PresenceCheck: AnyObject {
    /// Asks the user. `accessControl` is the Secure Enclave key's, for the one sheet that covers the key's use; nil
    /// asks with the device owner policy (the keychain keyring, and the first key, which makes the vault). Throws
    /// `UserPresence.Failure`.
    func confirm(reason: String, accessControl: SecAccessControl?) async throws -> AnyObject
    func finish(_ token: AnyObject)
}

/// Touch ID or the Mac password, through LocalAuthentication, for Secrets alone. The Mac password is the
/// fallback macOS offers; there is no app PIN.
///
/// - One evaluation runs at a time: a second caller waits its turn.
/// - With an access control (the Secure Enclave keyring) it evaluates it for `.useKeyKeyExchange`, and the context is
///   handed to the key, so one sheet covers the operation. Without one it evaluates `.deviceOwnerAuthentication`.
/// - The sheet reads "“Next Term” is trying to", then the reason. A reason names keys and the program, never a value.
@MainActor
final class UserPresence: PresenceCheck {
    static let shared = UserPresence()

    enum Failure: Error, Equatable, LocalizedError {
        /// The user cancelled, or macOS did (another app, the screen locking).
        case cancelled
        /// This Mac can't ask: no password set, or LocalAuthentication failed.
        case unavailable

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Not approved."
            case .unavailable: return "This Mac can’t ask for Touch ID or your password now, so nothing changed."
            }
        }
    }

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    /// The self-test's: makes each check's context, a stand-in that never shows a sheet.
    var standInContext: (() -> LAContext)?
    #endif

    /// The access control the Secure Enclave key is made with and evaluated against: built the same way both times.
    nonisolated static func secureEnclaveAccessControl() -> SecAccessControl? {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil)
    }

    /// A cancelled caller's sheet closes: its context is invalidated, and the check throws `cancelled` (Reveal's, when
    /// Settings closes while it asks).
    func confirm(reason: String, accessControl: SecAccessControl?) async throws -> AnyObject {
        await takeTurn()
        defer { endTurn() }
        if Task.isCancelled { throw Failure.cancelled }
        let context = newContext()
        let box = UncheckedBox(context)
        do {
            try await withTaskCancellationHandler {
                if let accessControl {
                    _ = try await context.evaluateAccessControl(accessControl, operation: .useKeyKeyExchange, localizedReason: reason)
                } else {
                    _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                }
            } onCancel: {
                box.value.invalidate()
            }
            if Task.isCancelled { throw Failure.cancelled } // approved as its caller gave up
            return context
        } catch {
            context.invalidate()
            throw Task.isCancelled ? Failure.cancelled : Self.failure(error)
        }
    }

    func finish(_ token: AnyObject) {
        (token as? LAContext)?.invalidate()
    }

    private func newContext() -> LAContext {
        #if DEBUG
        if let standInContext { return standInContext() }
        #endif
        return LAContext()
    }

    /// User cancel, app cancel, system cancel and not interactive all read "Not approved."; the rest can't ask.
    nonisolated static func failure(_ error: Error) -> Failure {
        guard let code = (error as? LAError)?.code else { return .unavailable }
        switch code {
        case .userCancel, .appCancel, .systemCancel, .notInteractive, .userFallback, .authenticationFailed: return .cancelled
        default: return .unavailable
        }
    }

    private func takeTurn() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume() // busy stays true: the turn passes on
        }
    }
}

/// What the Touch ID or password sheet says after "“Next Term” is trying to". Names and the program, never a
/// value.
enum SecretReason {
    /// "use OPENAI_API_KEY for npm in api": the program is the command's first word, the folder its name.
    static func use(_ names: [String], program: String, folder: String) -> String {
        "use \(keys(names)) for \(program) in \((folder as NSString).lastPathComponent)"
    }

    static func save(_ name: String) -> String { "save \(name)" }
    static func show(_ name: String) -> String { "show \(name)" }
    static func copy(_ name: String) -> String { "copy \(name)" }
    static func delete(_ name: String) -> String { "delete \(name)" }
    static func makeWriteOnly(_ name: String) -> String { "make \(name) write-only" }
    static func changePurpose(_ name: String) -> String { "change what \(name) is for" }
    static func rename(_ name: String, to newName: String) -> String { "rename \(name) to \(newName)" }
    static func changeLink(_ name: String) -> String { "change \(name)’s page" }
    static func changeReminder(_ name: String) -> String { "change when to remind you to rotate \(name)" }
    /// More than one of what it's for, its page and its reminder.
    static func changeDetails(_ name: String) -> String { "change \(name)’s details" }
    /// Opening a key's page after vault.json changed since Next Term last wrote or checked it.
    static func checkLink(_ name: String) -> String { "check \(name)’s page" }
    static func replace(_ name: String) -> String { "replace \(name)" }
    /// A key rotation: Rotate…'s Save.
    static func rotate(_ name: String) -> String { "rotate \(name)" }
    static func replaceWithAgentsKey(_ name: String) -> String { "replace \(name) with the agent’s key" }
    static func moveOut(_ count: Int) -> String { "move \(count) \(count == 1 ? "key" : "keys") out of your MCP configs" }
    static func putBack(_ count: Int) -> String { "put \(count) \(count == 1 ? "key" : "keys") back into your MCP configs" }

    /// "GITHUB_TOKEN", "A and B", or "5 keys" for three or more.
    static func keys(_ names: [String]) -> String {
        switch names.count {
        case 0: return "no keys"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) keys"
        }
    }
}
