import AppKit
import NextTermCore

/// The master key's windows: setting it (with the recovery key shown once and three of its groups typed back),
/// asking for it before a step that widens what reaches this Mac, changing it, and replacing a forgotten one with the
/// recovery key. Each ends with Touch ID or the Mac password. The key is typed only here, in secure fields: no MCP
/// tool, local or remote, reaches these windows or the record.
@MainActor
enum MasterKeyGate {
    static var store = MasterKeyStore()

    /// Whether a master key was set.
    static var isSet: Bool { store.load() != nil }

    /// Asks for the master key, then Touch ID, before `reason` ("turn on Remote access"); sets the key first when
    /// none was. `done(true)` only when both passed.
    /// `presence` false: the caller asks for Touch ID itself next (pairing, Edit…), so it isn't asked twice.
    #if DEBUG
    /// The self-test's stand-in for the master key's windows: given the reason, the answer.
    static var standIn: ((String) -> Bool)?
    /// The reasons asked with since the self-test last cleared them.
    static var reasons: [String] = []
    #endif

    static func require(_ reason: String, over window: NSWindow?, presence: Bool = true, done: @escaping (Bool) -> Void) {
        #if DEBUG
        if SelfTest.isRequested, let standIn {
            reasons.append(reason)
            let answer = standIn(reason)
            DispatchQueue.main.async { done(answer) }
            return
        }
        #endif
        let finish: (Bool) -> Void = { passed in
            guard passed else { return done(false) }
            presence ? confirmPresence(reason, done: done) : done(true)
        }
        guard var record = store.load() else {
            setUp(over: window, done: finish) // the key was just typed: Touch ID is the second step
            return
        }
        if MasterKey.lockedOut(record), RemoteAccess.shared.isOn { RemoteAccess.shared.turnOff() }
        let field = secureField(placeholder: "Master key")
        let alert = NSAlert()
        alert.messageText = "Enter your master key to \(reason)."
        alert.informativeText = waitNote(record) ?? "Remote access changes on this Mac need the master key you set for it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Forgot It…")
        alert.window.initialFirstResponder = field
        present(alert, over: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                let typed = field.stringValue
                field.stringValue = ""
                switch MasterKey.attempt(typed, record: &record, onMac: true) {
                case .right:
                    try? store.save(record)
                    finish(true)
                case .wrong, .wait, .lockedOut:
                    try? store.save(record)
                    if MasterKey.lockedOut(record), RemoteAccess.shared.isOn { RemoteAccess.shared.turnOff() }
                    require(reason, over: window, presence: presence, done: done) // again, with the wrong try's note
                }
            case .alertThirdButtonReturn:
                recover(over: window, done: finish)
            default:
                done(false)
            }
        }
    }

    /// The note above the field after wrong tries, or nil.
    static func waitNote(_ record: MasterKeyRecord) -> String? {
        if MasterKey.lockedOut(record) {
            return "Too many wrong tries: Remote access is off until the right master key is typed here."
        }
        let wait = Int(MasterKey.waitLeft(record).rounded(.up))
        if wait > 0 { return "Wrong master key. Try again in \(wait) seconds." }
        guard record.wrongTries > 0 else { return nil }
        let left = max(0, MasterKey.freeTries - record.wrongTries)
        return left > 0 ? "Wrong master key. \(left) more tries before each one waits." : "Wrong master key."
    }

    // MARK: setting

    /// Sets the master key: the key twice, then the recovery key shown once, then three of its groups typed back.
    static func setUp(over window: NSWindow?, done: @escaping (Bool) -> Void) {
        askNewKey(title: "Set a master key for Remote access.",
                  note: "You’ll type it to turn Remote access on, to give a connection more than reading, and to change "
                      + "these settings. Next Term keeps only a check of it, never the key itself.",
                  over: window) { key in
            guard let key else { return done(false) }
            let recovery = MasterKey.makeRecoveryKey()
            showRecovery(recovery, over: window) { confirmed in
                guard confirmed else { return done(false) }
                do {
                    try store.save(MasterKey.set(key, recovery: recovery))
                    done(true)
                } catch {
                    fail("The master key couldn’t be saved, so nothing changed.", over: window)
                    done(false)
                }
            }
        }
    }

    /// Changes the master key: the current one, then the new one twice. Every connection signs in again.
    static func change(over window: NSWindow?, done: @escaping (Bool) -> Void = { _ in }) {
        guard var record = store.load() else { return setUp(over: window, done: done) }
        let field = secureField(placeholder: "Current master key")
        let alert = NSAlert()
        alert.messageText = "Change your master key."
        alert.informativeText = waitNote(record) ?? "Type the current one first. Every remote connection signs in again after it changes."
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, over: window) { response in
            guard response == .alertFirstButtonReturn else { return done(false) }
            let current = field.stringValue
            field.stringValue = ""
            guard MasterKey.attempt(current, record: &record, onMac: true) == .right else {
                try? store.save(record)
                return change(over: window, done: done)
            }
            try? store.save(record)
            askNewKey(title: "Choose a new master key.", note: "It replaces the current one.", over: window) { newKey in
                guard let newKey else { return done(false) }
                var checked = record
                switch MasterKey.change(current: current, to: newKey, record: &checked) {
                case .success(let next):
                    confirmPresence("change the master key") { approved in
                        guard approved, (try? store.save(next)) != nil else { return done(false) }
                        RemoteAccess.shared.turnOff(revokeAll: true)
                        done(true)
                    }
                case .failure(.sameAsBefore):
                    fail("That is the master key you have now.", over: window)
                    done(false)
                case .failure:
                    done(false)
                }
            }
        }
    }

    /// Replaces a forgotten master key with the recovery key, and gives a new recovery key in place of the used one.
    static func recover(over window: NSWindow?, done: @escaping (Bool) -> Void) {
        guard var record = store.load() else { return done(false) }
        let field = NSTextField()
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = "Type your recovery key."
        alert.informativeText = waitNote(record) ?? "The one Next Term showed when you set the master key. You’ll choose a new master key, and get a new recovery key."
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, over: window) { response in
            guard response == .alertFirstButtonReturn else { return done(false) }
            let typed = field.stringValue
            field.stringValue = ""
            guard record.recovery.matches(MasterKey.normalizedRecovery(typed)) else {
                var counted = record
                _ = MasterKey.recover(with: typed, newKey: "", newRecovery: "", record: &counted)
                try? store.save(counted)
                return recover(over: window, done: done)
            }
            askNewKey(title: "Choose a new master key.", note: "It replaces the one you forgot.", over: window) { newKey in
                guard let newKey else { return done(false) }
                let recovery = MasterKey.makeRecoveryKey()
                showRecovery(recovery, over: window) { confirmed in
                    guard confirmed,
                          case .success(let next) = MasterKey.recover(with: typed, newKey: newKey, newRecovery: recovery, record: &record),
                          (try? store.save(next)) != nil else { return done(false) }
                    RemoteAccess.shared.turnOff(revokeAll: true)
                    done(true)
                }
            }
        }
    }

    // MARK: pieces

    /// The new key, typed twice and checked, or nil when cancelled.
    private static func askNewKey(title: String, note: String, over window: NSWindow?, done: @escaping (String?) -> Void) {
        let first = secureField(placeholder: "Master key (\(MasterKey.minimumLength) characters or more)")
        let second = secureField(placeholder: "The same again")
        let fields = NSStackView(views: [first, second])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = note
        alert.accessoryView = fields
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = first
        present(alert, over: window) { response in
            guard response == .alertFirstButtonReturn else { return done(nil) }
            let key = first.stringValue, again = second.stringValue
            first.stringValue = ""
            second.stringValue = ""
            let problem: String?
            if key != again {
                problem = "The two didn’t match."
            } else {
                switch MasterKey.weakness(of: key) {
                case .tooShort?: problem = "Use \(MasterKey.minimumLength) characters or more: a few words you’ll remember works well."
                case .allOneCharacter?: problem = "Use more than one character over and over."
                case .sameAsRecoveryKey?: problem = "Choose something other than the recovery key."
                case nil: problem = nil
                }
            }
            guard let problem else { return done(key) }
            askNewKey(title: title, note: problem, over: window, done: done)
        }
    }

    /// Shows the recovery key once, then asks for three of its groups.
    private static func showRecovery(_ recovery: String, over window: NSWindow?, done: @escaping (Bool) -> Void) {
        let shown = NSTextField(labelWithString: recovery)
        shown.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        shown.isSelectable = true
        shown.frame = NSRect(x: 0, y: 0, width: 380, height: 22)
        let alert = NSAlert()
        alert.messageText = "Save your recovery key."
        alert.informativeText = "If you forget the master key, this is the only way to choose a new one without resetting "
            + "Remote access. Save it in your password manager or write it down. Next Term shows it only now."
        alert.accessoryView = shown
        alert.addButton(withTitle: "I Saved It")
        alert.addButton(withTitle: "Cancel")
        present(alert, over: window) { response in
            guard response == .alertFirstButtonReturn else { return done(false) }
            confirmRecovery(recovery, over: window, done: done)
        }
    }

    /// Groups 2, 5 and 7 of the recovery key, typed back.
    private static func confirmRecovery(_ recovery: String, over window: NSWindow?, done: @escaping (Bool) -> Void) {
        let groups = recovery.split(separator: "-").map(String.init)
        let asked = [1, 4, 6].filter { $0 < groups.count }
        let fields = asked.map { index -> NSTextField in
            let field = NSTextField()
            field.placeholderString = "Group \(index + 1)"
            return field
        }
        let row = NSStackView(views: fields)
        row.distribution = .fillEqually
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let alert = NSAlert()
        alert.messageText = "Type groups 2, 5 and 7 of your recovery key."
        alert.informativeText = "This checks that you saved it."
        alert.accessoryView = row
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Show It Again")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields.first
        present(alert, over: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                let right = zip(asked, fields).allSatisfy { index, field in
                    MasterKey.normalizedRecovery(field.stringValue) == groups[index]
                }
                right ? done(true) : confirmRecovery(recovery, over: window, done: done)
            case .alertSecondButtonReturn:
                showRecovery(recovery, over: window, done: done)
            default:
                done(false)
            }
        }
    }

    private static func confirmPresence(_ reason: String, done: @escaping (Bool) -> Void) {
        Task { @MainActor in
            do {
                let token = try await UserPresence.shared.confirm(reason: reason, accessControl: nil)
                UserPresence.shared.finish(token)
                done(true)
            } catch {
                done(false)
            }
        }
    }

    private static func secureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        return field
    }

    private static func fail(_ text: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        present(alert, over: window) { _ in }
    }

    private static func present(_ alert: NSAlert, over window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}
