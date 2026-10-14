import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// An entry as 0.11.6 wrote and reads it: none of the members added since. JSONDecoder skips members a type lacks, so
/// this is also how 0.11.6 reads a newer vault.
private struct OldEntry: Codable, Equatable {
    let id: String
    let name: String
    let purpose: String
    let purposeBy: SecretVault.PurposeBy
    let origin: SecretVault.Origin
    let writeOnly: Bool
    let created: Date
    let changed: Date
    let box: Data
    let marks: [SecretVault.Mark]
}

private struct OldIndex: Codable, Equatable {
    let format: Int
    let keyring: VaultKeyringKind
    let keyBlob: Data?
    let publicKey: Data
    let wrapped: SecretVault.Wrapped
    let recovery: SecretVault.Recovery?
    let entries: [OldEntry]
}

/// A vault with one key, `SOURCE_KEY`, and the bytes it wrote. Its value is made up.
private struct FactsFixture {
    static let made = Date(timeIntervalSince1970: 1_790_000_000)
    let keyring = SoftwareKeyring()
    let vault: SecretVault
    var file: Data

    init(link: String? = nil, linkFrom: SecretVault.LinkFrom? = nil, remindDays: Int? = nil) throws {
        vault = try SecretVault.create(keyring: keyring).vault
        file = try vault.add(name: "SOURCE_KEY", purpose: "rag-api", purposeBy: .user, origin: .settings, writeOnly: false,
                             value: SecretBytes(utf8: "made-up-source-value-0123456789"), link: link, linkFrom: linkFrom,
                             remindDays: remindDays, maskKey: SymmetricKey(size: .bits256), now: Self.made)
    }

    func unlock(_ data: Data) throws -> SecretVault {
        try SecretVault.unlock(data, keyring: keyring, context: nil)
    }

    /// The body's bytes as stored.
    static func body(of file: Data) throws -> Data {
        try JSONDecoder().decode(SecretVault.File.self, from: file).body
    }

    /// The first entry's members, as JSON.
    static func firstEntry(of file: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: body(of: file)) as? [String: Any]
        let entries = try #require(object?["entries"] as? [[String: Any]])
        return try #require(entries.first)
    }

    /// The body of `file` with its first entry changed by `edit`, written back with a MAC made with the vault key
    /// (`resealed`) or with the old MAC.
    func edited(_ file: Data, resealed: Bool = true, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        let outer = try JSONDecoder().decode(SecretVault.File.self, from: file)
        var body = try #require(try JSONSerialization.jsonObject(with: outer.body) as? [String: Any])
        var entries = body["entries"] as? [[String: Any]] ?? []
        edit(&entries[0])
        body["entries"] = entries
        let bytes = try JSONSerialization.data(withJSONObject: body)
        if resealed { return try SecretVault.encodeFile(body: bytes, key: vault.unlockedKey()) }
        return try JSONEncoder().encode(SecretVault.File(format: outer.format, body: bytes, mac: outer.mac))
    }

    /// `edited` with the entry's own marks retired until `until`.
    func retired(_ file: Data, until: Date, marks count: Int? = nil) throws -> Data {
        try edited(file) { entry in
            var marks = entry["marks"] as? [[String: Any]] ?? []
            if let count, let first = marks.first { marks = Array(repeating: first, count: count) }
            let formatter = ISO8601DateFormatter()
            entry["retired"] = ["marks": marks, "until": formatter.string(from: until)] as [String: Any]
        }
    }
}

private let newMembers = ["link", "linkFrom", "valueSet", "remindDays", "retired"]

/// A key's link, where it came from, when its value was set, its reminder and its retired marks: optional members of
/// the entry, so the vault stays format 1 and a vault from before them reads and writes as it did.
@Suite struct SecretVaultFormatTests {
    /// The fixture's body as 0.11.6 would have written it: re-encoded without the members added since.
    private static func oldBody(_ f: FactsFixture) throws -> Data {
        let old = try SecretVault.decoder.decode(OldIndex.self, from: FactsFixture.body(of: f.file))
        return try SecretVault.encoder.encode(old)
    }

    @Test func aVaultFromBeforeTheNewMembersRoundTripsByteForByte() throws {
        let f = try FactsFixture()
        let body = try Self.oldBody(f)
        let index = try SecretVault.decoder.decode(SecretVault.Index.self, from: body)
        let entry = try #require(index.entries.first)
        #expect(entry.link == nil && entry.linkFrom == nil && entry.valueSet == nil)
        #expect(entry.remindDays == nil && entry.retired == nil)
        #expect(try SecretVault.encoder.encode(index) == body)
        // Its MAC verifies, its key opens, and a purpose edit adds none of the new members.
        let file = try SecretVault.encodeFile(body: body, key: f.vault.unlockedKey())
        let opened = try f.unlock(file)
        #expect(opened.index.entries[0].lastSet == FactsFixture.made)
        #expect(try opened.value(of: "SOURCE_KEY").utf8String() == "made-up-source-value-0123456789")
        let edited = try opened.edit("SOURCE_KEY", purpose: "rag-api, staging")
        let members = try FactsFixture.firstEntry(of: edited)
        for member in newMembers { #expect(members[member] == nil, "\(member)") }
    }

    @Test func everyNewMemberRoundTrips() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .suggested, remindDays: 90)
        let until = FactsFixture.made.addingTimeInterval(30 * 86_400)
        let file = try f.retired(f.file, until: until)
        let opened = try f.unlock(file)
        let entry = try #require(opened.index.entries.first)
        #expect(entry.link == "https://dashboard.example.com/apikeys")
        #expect(entry.linkFrom == .suggested)
        #expect(entry.valueSet == FactsFixture.made)
        #expect(entry.remindDays == 90)
        #expect(entry.retired?.until == until)
        #expect(entry.retired?.marks == entry.marks)
        let saved = try opened.edit("SOURCE_KEY", purpose: "rag-api, staging", now: FactsFixture.made)
        let again = try #require(try SecretVault.index(from: saved).entries.first)
        #expect(again.link == entry.link && again.linkFrom == entry.linkFrom && again.valueSet == entry.valueSet)
        #expect(again.remindDays == entry.remindDays && again.retired == entry.retired)
    }

    /// 0.11.6 opens a newer vault: its decoder skips what it doesn't know, and the MAC is over the bytes as stored.
    @Test func anOlderReaderSkipsTheNewMembers() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .user, remindDays: 365)
        let file = try f.retired(f.file, until: FactsFixture.made.addingTimeInterval(86_400))
        let new = try SecretVault.index(from: file)
        let old = try SecretVault.decoder.decode(OldIndex.self, from: FactsFixture.body(of: file))
        let oldEntry = try #require(old.entries.first)
        let newEntry = try #require(new.entries.first)
        #expect(oldEntry.id == newEntry.id && oldEntry.name == newEntry.name && oldEntry.box == newEntry.box)
        #expect(oldEntry.marks == newEntry.marks && oldEntry.changed == newEntry.changed)
    }

    /// A kind of link source a later release adds reads as none here, and the vault still opens.
    @Test func anUnknownLinkSourceReadsAsNone() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .imported)
        for unknown in ["catalog", 5, ["kind": "user"]] as [Any] {
            let file = try f.edited(f.file) { $0["linkFrom"] = unknown }
            let opened = try f.unlock(file)
            #expect(opened.index.entries[0].linkFrom == nil)
            #expect(opened.index.entries[0].link == "https://dashboard.example.com/apikeys")
        }
    }
}

@Suite struct SecretVaultValueSetTests {
    @Test func addSetsTheDateAndARenameOrAPurposeLeavesIt() throws {
        let f = try FactsFixture()
        #expect(f.vault.index.entries[0].valueSet == FactsFixture.made)
        let later = FactsFixture.made.addingTimeInterval(86_400)
        _ = try f.vault.edit("SOURCE_KEY", newName: "SOURCE_KEY_2", purpose: "renamed", now: later)
        let entry = try #require(f.vault.index.entry(named: "SOURCE_KEY_2"))
        #expect(entry.valueSet == FactsFixture.made)
        #expect(entry.changed == later)
        #expect(entry.lastSet == FactsFixture.made)
    }

    @Test func replaceMovesTheDate() throws {
        let f = try FactsFixture()
        let later = FactsFixture.made.addingTimeInterval(86_400 + 0.75)
        _ = try f.vault.replace("SOURCE_KEY", value: SecretBytes(utf8: "made-up-source-value-new-0123"), writeOnly: false,
                                now: later)
        let entry = try #require(f.vault.index.entry(named: "SOURCE_KEY"))
        #expect(entry.valueSet == FactsFixture.made.addingTimeInterval(86_400))
        #expect(entry.created == FactsFixture.made)
    }

    @Test func makingAKeyWriteOnlyLeavesTheDate() throws {
        let f = try FactsFixture()
        _ = try f.vault.makeWriteOnly("SOURCE_KEY", now: FactsFixture.made.addingTimeInterval(60))
        #expect(f.vault.index.entries[0].valueSet == FactsFixture.made)
    }

    /// Edit… with only a new link, a cleared one or a new reminder: the value isn't sealed again and the Rotated column
    /// still counts from when it was set.
    @Test func anEditOfOnlyTheLinkOrTheReminderLeavesTheDateAndTheSeal() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .suggested)
        let box: Data = f.vault.index.entries[0].box
        let later = FactsFixture.made.addingTimeInterval(86_400)
        _ = try f.vault.edit("SOURCE_KEY", link: "https://console.example.com/keys", now: later)
        var entry = try #require(f.vault.index.entry(named: "SOURCE_KEY"))
        #expect(entry.link == "https://console.example.com/keys" && entry.linkFrom == .user)
        #expect(entry.valueSet == FactsFixture.made && entry.changed == later && entry.box == box)
        _ = try f.vault.edit("SOURCE_KEY", link: .some(nil), now: later.addingTimeInterval(60))
        _ = try f.vault.edit("SOURCE_KEY", remindDays: 90, now: later.addingTimeInterval(120))
        entry = try #require(f.vault.index.entry(named: "SOURCE_KEY"))
        #expect(entry.link == nil && entry.remindDays == 90)
        #expect(entry.valueSet == FactsFixture.made && entry.box == box)
        #expect(!SecretAge.wasGivenNewValue(entry))
    }
}

@Suite struct SecretVaultLinkTests {
    @Test func addKeepsTheCheckedLinkAndWhereItCameFrom() throws {
        let typed = try FactsFixture(link: "  Dashboard.Example.com/apikeys ")
        #expect(typed.vault.index.entries[0].link == "https://dashboard.example.com/apikeys")
        #expect(typed.vault.index.entries[0].linkFrom == .user)
        let suggested = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .suggested)
        #expect(suggested.vault.index.entries[0].linkFrom == .suggested)
        // No link, or an empty one: neither member is set.
        for link in [nil, "", "  "] as [String?] {
            let none = try FactsFixture(link: link, linkFrom: .suggested)
            #expect(none.vault.index.entries[0].link == nil && none.vault.index.entries[0].linkFrom == nil)
        }
    }

    @Test func addRefusesABadLinkAndSavesNothing() throws {
        let f = try FactsFixture()
        let add = { (name: String, link: String, value: String) throws -> Data in
            try f.vault.add(name: name, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                            value: SecretBytes(utf8: value), link: link)
        }
        #expect(throws: SecretVault.Failure.badLink(.scheme)) {
            try add("PLAIN_KEY", "http://dashboard.example.com", "made-up-plain-value-0123")
        }
        // The value being added can't ride in its own link.
        #expect(throws: SecretVault.Failure.badLink(.holdsAKey)) {
            try add("OWN_KEY", "https://x.example.com/?state=made-up-own-value-0123", "made-up-own-value-0123")
        }
        #expect(f.vault.index.names == ["SOURCE_KEY"])
        #expect(f.vault.file == f.file)
    }

    @Test func editSetsClearsOrLeavesTheLink() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .suggested)
        _ = try f.vault.edit("SOURCE_KEY", purpose: "only the purpose")
        #expect(f.vault.index.entries[0].link == "https://dashboard.example.com/apikeys")
        #expect(f.vault.index.entries[0].linkFrom == .suggested)
        _ = try f.vault.edit("SOURCE_KEY", link: "https://console.example.com/keys")
        #expect(f.vault.index.entries[0].link == "https://console.example.com/keys")
        #expect(f.vault.index.entries[0].linkFrom == .user)
        _ = try f.vault.edit("SOURCE_KEY", link: .some(nil))
        #expect(f.vault.index.entries[0].link == nil && f.vault.index.entries[0].linkFrom == nil)
        _ = try f.vault.edit("SOURCE_KEY", link: "https://console.example.com/keys", linkFrom: .imported)
        _ = try f.vault.edit("SOURCE_KEY", link: "")
        #expect(f.vault.index.entries[0].link == nil && f.vault.index.entries[0].linkFrom == nil)
        let before = f.vault.file
        #expect(throws: SecretVault.Failure.badLink(.userOrPassword)) {
            try f.vault.edit("SOURCE_KEY", link: "https://u:p@x.example.com")
        }
        #expect(f.vault.file == before)
    }

    /// The Edit sheet sends its field's text each time: the same link again keeps where it came from, unless a
    /// source is given; a changed link is the user's.
    @Test func savingTheSameLinkAgainKeepsWhereItCameFrom() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys", linkFrom: .suggested)
        _ = try f.vault.edit("SOURCE_KEY", purpose: "from the sheet", link: "https://dashboard.example.com/apikeys")
        #expect(f.vault.index.entries[0].linkFrom == .suggested)
        // As typed, before it is tidied, it is still the same link.
        _ = try f.vault.edit("SOURCE_KEY", link: " Dashboard.Example.com/apikeys ")
        #expect(f.vault.index.entries[0].link == "https://dashboard.example.com/apikeys")
        #expect(f.vault.index.entries[0].linkFrom == .suggested)
        _ = try f.vault.edit("SOURCE_KEY", link: "https://dashboard.example.com/apikeys", linkFrom: .imported)
        #expect(f.vault.index.entries[0].linkFrom == .imported)
        _ = try f.vault.edit("SOURCE_KEY", link: "https://dashboard.example.com/apikeys/new")
        #expect(f.vault.index.entries[0].linkFrom == .user)
    }

    @Test func theReminderIsFrom1To3650Days() throws {
        let f = try FactsFixture(remindDays: 90)
        #expect(f.vault.index.entries[0].remindDays == 90)
        _ = try f.vault.edit("SOURCE_KEY", remindDays: 45)
        #expect(f.vault.index.entries[0].remindDays == 45)
        _ = try f.vault.edit("SOURCE_KEY", purpose: "left as it is")
        #expect(f.vault.index.entries[0].remindDays == 45)
        _ = try f.vault.edit("SOURCE_KEY", remindDays: .some(nil))
        #expect(f.vault.index.entries[0].remindDays == nil)
        for days in [0, -1, 3651] {
            #expect(throws: SecretVault.Failure.badReminder, "\(days)") { try f.vault.edit("SOURCE_KEY", remindDays: days) }
        }
        #expect(throws: SecretVault.Failure.badReminder) { try FactsFixture(remindDays: 0) }
    }

    /// The index's MAC covers the link: one changed by another process fails the next unlock, and the bytes Next Term
    /// vouched for no longer match.
    @Test func aLinkChangedOutsideNextTermIsCaught() throws {
        let f = try FactsFixture(link: "https://dashboard.example.com/apikeys")
        let vouch = SecretLink.Vouch(file: f.file)
        let planted = try f.edited(f.file, resealed: false) { $0["link"] = "https://dashboard.example.org/apikeys" }
        #expect(!vouch.covers(planted))
        #expect(try SecretVault.index(from: planted).entries[0].link == "https://dashboard.example.org/apikeys")
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(planted) }
        #expect(vouch.covers(f.file))
    }
}

/// What the read checks of the new members: their structure only. A link rule or a reminder age that a later release
/// changes must not make a vault it saved read as changed outside Next Term here.
@Suite struct SecretVaultFactsShapeTests {
    @Test func aMalformedMemberReadsAsChanged() throws {
        let f = try FactsFixture()
        let long = "https://x.example.com/" + String(repeating: "a", count: SecretLink.maxLength)
        let changes: [(String, (inout [String: Any]) -> Void)] = [
            ("long link", { $0["link"] = long }),
            ("control character", { $0["link"] = "https://x.example.com/a\u{7}b" }),
            ("line break", { $0["link"] = "https://x.example.com/a\nb" }),
            ("no reminder", { $0["remindDays"] = 0 }),
            ("too long a reminder", { $0["remindDays"] = 3651 }),
        ]
        for (label, change) in changes {
            let file = try f.edited(f.file, change)
            #expect(throws: SecretVault.Failure.tampered, "\(label)") { _ = try f.unlock(file) }
            #expect(throws: SecretVault.Failure.tampered, "\(label)") { _ = try SecretVault.index(from: file) }
        }
    }

    @Test func aStoredLinkHasAtMost2048Bytes() throws {
        let f = try FactsFixture()
        let start = "https://x.example.com/"
        let longest = start + String(repeating: "a", count: SecretLink.maxLength - start.utf8.count)
        let fits = try f.edited(f.file) { $0["link"] = longest }
        #expect(try f.unlock(fits).index.entries[0].link == longest)
        let over = try f.edited(f.file) { $0["link"] = longest + "a" }
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(over) }
        // Bytes, not characters: 2,047 characters with one of two bytes is over.
        let wide = String(longest.dropLast()) + "\u{E9}"
        let overByOne = try f.edited(f.file) { $0["link"] = wide }
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(overByOne) }
    }

    /// Every save is checked as the read checks it, so no write path can save a file this build would then read as
    /// changed outside Next Term (and offer Start Over); it is refused and nothing is saved.
    @Test func aSaveTheReadWouldRefuseIsRefused() throws {
        let f = try FactsFixture()
        var index = f.vault.index
        let marks = index.entries[0].marks
        let first = try #require(marks.first)
        let until = FactsFixture.made.addingTimeInterval(86_400)
        index.entries[0].retired = SecretVault.Retired(marks: marks, until: until)
        try SecretVault.checkReadable(index)
        let most = Array(repeating: first, count: SecretVault.maxRetiredMarks)
        index.entries[0].retired = SecretVault.Retired(marks: most, until: until)
        try SecretVault.checkReadable(index)
        index.entries[0].retired = SecretVault.Retired(marks: most + [first], until: until)
        #expect(throws: SecretVault.Failure.unreadable) { try SecretVault.checkReadable(index) }
        #expect(SecretVault.Failure.unreadable.errorDescription?.hasSuffix("so nothing was saved.") == true)
    }

    @Test func aLinkTheRulesRefuseStillReads() throws {
        let f = try FactsFixture()
        let file = try f.edited(f.file) { $0["link"] = "http://evil.example" }
        let opened = try f.unlock(file)
        let link = try #require(opened.index.entries[0].link)
        #expect(SecretLink.check(link, mask: { (_: String) -> Bool in false }, value: nil) == .failure(.scheme))
        #expect(SecretLink.cantOpen == "This link can\u{2019}t be opened.")
    }

    @Test func aReminderAgeOffTheMenuStillReads() throws {
        let f = try FactsFixture()
        let file = try f.edited(f.file) { $0["remindDays"] = 45 }
        #expect(try f.unlock(file).index.entries[0].remindDays == 45)
    }

    @Test func retiredMarksAreChecked() throws {
        let f = try FactsFixture()
        let until = FactsFixture.made.addingTimeInterval(86_400)
        let many = try f.retired(f.file, until: until, marks: SecretVault.maxRetiredMarks + 1)
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(many) }
        let most = try f.retired(f.file, until: until, marks: SecretVault.maxRetiredMarks)
        #expect(try f.unlock(most).index.entries[0].retired?.marks.count == SecretVault.maxRetiredMarks)
        let implausible = try f.edited(f.file) { entry in
            let mark: [String: Any] = ["length": 40, "head": 1, "tag": Data([1, 2, 3]).base64EncodedString()]
            entry["retired"] = ["marks": [mark], "until": "2026-09-22T00:00:00Z"] as [String: Any]
        }
        #expect(throws: SecretVault.Failure.tampered) { _ = try f.unlock(implausible) }
    }
}

/// Retired marks keep an old value masked for a while after it is replaced; past their date they go at the next save.
@Suite struct SecretVaultRetiredTests {
    @Test func retiredMarksPastTheirDateGoAtTheNextSave() throws {
        let f = try FactsFixture()
        let now = FactsFixture.made.addingTimeInterval(10 * 86_400)
        let past = try f.unlock(f.retired(f.file, until: now.addingTimeInterval(-86_400)))
        let saved = try past.edit("SOURCE_KEY", purpose: "a later save", now: now)
        #expect(past.index.entries[0].retired == nil)
        #expect(try FactsFixture.firstEntry(of: saved)["retired"] == nil)
        let ahead = try f.unlock(f.retired(f.file, until: now.addingTimeInterval(86_400)))
        _ = try ahead.edit("SOURCE_KEY", purpose: "a later save", now: now)
        #expect(ahead.index.entries[0].retired?.until == now.addingTimeInterval(86_400))
    }

    /// Marks made again under a new mask.key: the retired ones were made under the old one and can't be made again,
    /// since the old value is gone, so they go.
    @Test func newMarksDropTheRetiredOnes() throws {
        let f = try FactsFixture()
        let ahead = try f.unlock(f.retired(f.file, until: Date().addingTimeInterval(86_400)))
        #expect(ahead.index.entries[0].retired != nil)
        _ = try ahead.remark(maskKey: SymmetricKey(size: .bits256))
        #expect(ahead.index.entries[0].retired == nil)
        #expect(!ahead.index.entries[0].marks.isEmpty)
    }
}
