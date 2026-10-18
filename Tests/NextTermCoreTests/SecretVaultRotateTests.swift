import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A vault with one key, `ROTATE_KEY`, its mask key and the bytes it wrote. Every value is made up.
private struct RotateFixture {
    static let made = Date(timeIntervalSince1970: 1_790_000_000)
    static let old = "made-up-rotate-old-value-0123456789"
    static let new = "made-up-rotate-new-value-9876543210"
    static let newer = "made-up-rotate-newer-value-5555555555"
    static let day: TimeInterval = 86_400

    let keyring = SoftwareKeyring()
    let maskKey = SymmetricKey(size: .bits256)
    let vault: SecretVault
    var file: Data

    init(writeOnly: Bool = false, origin: SecretVault.Origin = .settings, marked: Bool = true) throws {
        vault = try SecretVault.create(keyring: keyring).vault
        file = try vault.add(name: "ROTATE_KEY", purpose: "triage-agent", purposeBy: .user, origin: origin, writeOnly: writeOnly,
                             value: SecretBytes(utf8: Self.old), link: "https://github.com/settings/personal-access-tokens",
                             linkFrom: .suggested, remindDays: 90, maskKey: marked ? maskKey : nil, now: Self.made)
    }

    var entry: SecretVault.Entry { vault.index.entries[0] }

    func marks(_ value: String) -> [SecretVault.Mark] {
        SecretMask.marks(for: SecretBytes(utf8: value), key: maskKey)
    }

    func rotate(to value: String, after days: Double = 1, link: String?? = nil, remindDays: Int?? = nil) throws -> Data {
        try vault.rotate("ROTATE_KEY", value: SecretBytes(utf8: value), link: link, remindDays: remindDays, maskKey: maskKey,
                         now: Self.made.addingTimeInterval(days * Self.day))
    }
}

/// A key rotation: a new value whose old one stays masked for 30 days, while the old key may still work at its provider.
@Suite struct SecretVaultRotateTests {
    @Test func theValueTheKeyHasNowIsRefused() throws {
        let f = try RotateFixture()
        let before = f.vault.file
        #expect(throws: SecretVault.Failure.sameValue("ROTATE_KEY")) { try f.rotate(to: "  " + RotateFixture.old + "\n") }
        #expect(f.vault.file == before)
        #expect(f.entry.retired == nil)
        #expect(SecretVault.Failure.sameValue("ROTATE_KEY").errorDescription == "That\u{2019}s the key you have now.")
    }

    @Test func aNewValueRetiresTheOldMarksForThirtyDays() throws {
        let f = try RotateFixture()
        let oldMarks = f.entry.marks
        let now = RotateFixture.made.addingTimeInterval(RotateFixture.day)
        _ = try f.rotate(to: RotateFixture.new)
        let entry = f.entry
        #expect(entry.marks == f.marks(RotateFixture.new))
        #expect(entry.retired?.marks == oldMarks)
        #expect(entry.retired?.until == now.addingTimeInterval(30 * RotateFixture.day))
        #expect(SecretVault.retiredDays == 30)
        #expect(entry.valueSet == now && entry.changed == now && entry.created == RotateFixture.made)
        #expect(try f.vault.value(of: "ROTATE_KEY") == SecretBytes(utf8: RotateFixture.new))
    }

    @Test func whatItsForItsPageAndItsReminderStay() throws {
        let f = try RotateFixture()
        let id = f.entry.id
        _ = try f.rotate(to: RotateFixture.new)
        let entry = f.entry
        #expect(entry.id == id && entry.name == "ROTATE_KEY" && entry.purpose == "triage-agent")
        #expect(entry.link == "https://github.com/settings/personal-access-tokens" && entry.linkFrom == .suggested)
        #expect(entry.remindDays == 90 && entry.origin == .settings)
    }

    @Test func aWriteOnlyKeyStaysWriteOnly() throws {
        let f = try RotateFixture(writeOnly: true)
        _ = try f.rotate(to: RotateFixture.new)
        #expect(f.entry.writeOnly)
        #expect(throws: SecretVault.Failure.writeOnly("ROTATE_KEY")) { try f.vault.shownValue(of: "ROTATE_KEY") }
        #expect(try f.vault.value(of: "ROTATE_KEY") == SecretBytes(utf8: RotateFixture.new))
    }

    /// Only one old value is kept masked: the most recent.
    @Test func aSecondRotationKeepsOnlyTheNewerOldValue() throws {
        let f = try RotateFixture()
        _ = try f.rotate(to: RotateFixture.new, after: 1)
        _ = try f.rotate(to: RotateFixture.newer, after: 5)
        let second = RotateFixture.made.addingTimeInterval(5 * RotateFixture.day)
        #expect(f.entry.retired?.marks == f.marks(RotateFixture.new))
        #expect(f.entry.retired?.until == second.addingTimeInterval(30 * RotateFixture.day))
        #expect(f.entry.marks == f.marks(RotateFixture.newer))
    }

    @Test func anOldValueWithNoMarksRetiresNothing() throws {
        let f = try RotateFixture(marked: false)
        #expect(f.entry.marks.isEmpty)
        _ = try f.rotate(to: RotateFixture.new)
        #expect(f.entry.retired == nil)
        #expect(f.entry.marks == f.marks(RotateFixture.new))
    }

    @Test func theRetiredMarksAreInTheFileAndReadBack() throws {
        let f = try RotateFixture()
        let written = try f.rotate(to: RotateFixture.new)
        let again = try SecretVault.unlock(written, keyring: f.keyring, context: nil)
        #expect(again.index.entries[0].retired == f.entry.retired)
        #expect(try SecretVault.index(from: written).entries[0].retired == f.entry.retired)
    }

    @Test func itsOriginIsWhoRotatedIt() throws {
        let f = try RotateFixture(origin: .agent)
        _ = try f.vault.rotate("ROTATE_KEY", value: SecretBytes(utf8: RotateFixture.new), origin: .settings, maskKey: f.maskKey,
                               now: RotateFixture.made)
        #expect(f.entry.origin == .settings)
        let kept = try RotateFixture(origin: .import)
        _ = try kept.rotate(to: RotateFixture.new)
        #expect(kept.entry.origin == .import)
    }
}

/// What Rotate… saves with the new value, in the same unlock: a page for a key that had none, and a reminder.
@Suite struct SecretVaultRotateFactsTests {
    @Test func aPageAndAReminderAreSavedWithTheNewValue() throws {
        let f = try RotateFixture()
        _ = try f.rotate(to: RotateFixture.new, link: .some("https://github.com/settings/tokens"), remindDays: .some(30))
        #expect(f.entry.link == "https://github.com/settings/tokens" && f.entry.linkFrom == .user)
        #expect(f.entry.remindDays == 30)
        let g = try RotateFixture()
        _ = try g.rotate(to: RotateFixture.new, link: .some(nil), remindDays: .some(nil))
        #expect(g.entry.link == nil && g.entry.linkFrom == nil && g.entry.remindDays == nil)
    }

    @Test func aPageHoldingTheNewValueIsRefusedAndNothingChanges() throws {
        let f = try RotateFixture()
        let before = f.vault.file
        let link = "https://example.com/" + RotateFixture.new
        #expect(throws: SecretVault.Failure.badLink(.holdsAKey)) { try f.rotate(to: RotateFixture.new, link: .some(link)) }
        #expect(throws: SecretVault.Failure.badReminder) { try f.rotate(to: RotateFixture.new, remindDays: .some(0)) }
        #expect(f.vault.file == before && f.entry.retired == nil)
        #expect(try f.vault.value(of: "ROTATE_KEY") == SecretBytes(utf8: RotateFixture.old))
    }

    @Test func aKeyThatIsntThereAndAValueTheVaultRefuses() throws {
        let f = try RotateFixture()
        #expect(throws: SecretVault.Failure.noSuchKey("OTHER_KEY")) {
            try f.vault.rotate("OTHER_KEY", value: SecretBytes(utf8: RotateFixture.new), maskKey: f.maskKey)
        }
        #expect(throws: SecretVault.Failure.badValue("ROTATE_KEY")) { try f.rotate(to: "two\nlines of a made-up value") }
    }

    /// 31 days on, the old value's marks go at the vault's next save.
    @Test func theOldMarksGoAtTheFirstSaveAfterThirtyDays() throws {
        let f = try RotateFixture()
        _ = try f.rotate(to: RotateFixture.new, after: 0)
        _ = try f.vault.edit("ROTATE_KEY", purpose: "day 29", now: RotateFixture.made.addingTimeInterval(29 * RotateFixture.day))
        #expect(f.entry.retired != nil)
        _ = try f.vault.edit("ROTATE_KEY", purpose: "day 31", now: RotateFixture.made.addingTimeInterval(31 * RotateFixture.day))
        #expect(f.entry.retired == nil)
    }
}

/// Masking after a key rotation: the new value at once, and the old one until its retired marks' date.
@Suite struct SecretMaskRetiredTests {
    private static func text(_ value: String) -> String { "printed \(value) here" }

    @Test func theOldValueIsMaskedTheDayAfterAndNotOnDay31() throws {
        let f = try RotateFixture()
        _ = try f.rotate(to: RotateFixture.new, after: 0)
        let index = f.vault.index
        let dayAfter = SecretMask(key: f.maskKey, index: index, now: RotateFixture.made.addingTimeInterval(RotateFixture.day))
        #expect(dayAfter.mask(Self.text(RotateFixture.old)) == Self.text("•••"))
        #expect(dayAfter.mask(Self.text(RotateFixture.new)) == Self.text("•••"))
        let day31 = SecretMask(key: f.maskKey, index: index, now: RotateFixture.made.addingTimeInterval(31 * RotateFixture.day))
        #expect(day31.mask(Self.text(RotateFixture.old)) == Self.text(RotateFixture.old))
        #expect(day31.mask(Self.text(RotateFixture.new)) == Self.text("•••"))
    }

    /// Rotate…'s as-you-type check finds the key's current value by its marks, never the retired ones.
    @Test func onlyTheCurrentValueIsTheKeyYouHaveNow() throws {
        let f = try RotateFixture()
        let before = SecretMask(key: f.maskKey, index: f.vault.index)
        #expect(before.isHeld(SecretBytes(utf8: RotateFixture.old), by: f.entry))
        _ = try f.rotate(to: RotateFixture.new, after: 0)
        let after = SecretMask(key: f.maskKey, index: f.vault.index, now: RotateFixture.made)
        #expect(after.isHeld(SecretBytes(utf8: RotateFixture.new), by: f.entry))
        #expect(!after.isHeld(SecretBytes(utf8: RotateFixture.old), by: f.entry))
    }
}
